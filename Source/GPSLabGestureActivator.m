//
//  GPSLabGestureActivator.m
//  GPSLab
//
//  Activation gesture: EXACTLY three fingers, pressed simultaneously and held
//  continuously for about 0.9 s. Clean-room: public UIGestureRecognizer APIs only.
//
//  Explicit acceptance criteria enforced here:
//   * a three-finger tap must NOT open the overlay (a long-press recognizer only
//     fires after the full minimum press duration);
//   * lifting any finger before the duration cancels the gesture
//     (UILongPressGestureRecognizer transitions to Failed/Cancelled);
//   * clear movement beyond a conservative threshold cancels the gesture
//     (`allowableMovement`, default below);
//   * a ~1 s cooldown after opening prevents retriggering;
//   * `cancelsTouchesInView = NO` so host touches are never swallowed;
//   * simultaneous recognition is granted so host recognizers keep working;
//   * leftover fingers from the activating press cannot immediately re-fire,
//     because the recognizer requires a brand-new gesture session and the
//     cooldown plus the presenting check both gate it.
//

#import "GPSLabGestureActivator.h"

#import <UIKit/UIKit.h>

#import "GPSLabOverlayPresenter.h"

// Press-and-hold duration (~0.9 s).
static const NSTimeInterval kGPSLabActivationPressDuration = 0.9;
// Conservative movement tolerance in points before the gesture cancels.
static const CGFloat kGPSLabActivationMovementTolerance = 10.0;
// Cooldown after the overlay opens, before another activation can fire.
static const NSTimeInterval kGPSLabActivationCooldown = 1.0;

@interface GPSLabGestureActivator () <UIGestureRecognizerDelegate>
@property (nonatomic, weak, nullable) UIWindow *installedWindow;
@property (nonatomic, strong, nullable) UILongPressGestureRecognizer *recognizer;
@property (nonatomic, assign) NSTimeInterval lastActivationTime;
@property (nonatomic, assign) NSUInteger activatingTouchesAtBegin;
@end

@implementation GPSLabGestureActivator

+ (instancetype)sharedActivator {
    static GPSLabGestureActivator *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[GPSLabGestureActivator alloc] init];
    });
    return instance;
}

- (void)installOnWindow:(UIWindow *)window {
    if (window == nil) {
        return;
    }
    if (self.installedWindow == window && self.recognizer != nil) {
        return;
    }
    [self uninstall];

    UILongPressGestureRecognizer *recognizer =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self
                                                     action:@selector(handleLongPress:)];
    // Exactly three fingers; extra fingers make the recognizer fail its begin check.
    recognizer.numberOfTouchesRequired = 3;
    recognizer.minimumPressDuration = kGPSLabActivationPressDuration;
    recognizer.allowableMovement = kGPSLabActivationMovementTolerance;
    recognizer.cancelsTouchesInView = NO;
    recognizer.delaysTouchesBegan = NO;
    recognizer.delaysTouchesEnded = NO;
    recognizer.delegate = self;

    [window addGestureRecognizer:recognizer];

    self.recognizer = recognizer;
    self.installedWindow = window;
}

- (void)uninstall {
    if (self.recognizer != nil) {
        [self.recognizer.view removeGestureRecognizer:self.recognizer];
        self.recognizer = nil;
    }
    self.installedWindow = nil;
    self.activatingTouchesAtBegin = 0;
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)recognizer {
    // Only a fully-formed press may activate; Began is reached only after the
    // minimum press duration with the movement tolerance respected.
    if (recognizer.state == UIGestureRecognizerStateBegan) {
        if (recognizer.numberOfTouches != 3) {
            // Defensive: never activate for a non-3-finger press.
            return;
        }
        [self tryActivate];
        return;
    }

    // Any Ended/Cancelled/Failed transition (finger lifted early, moved too far,
    // or a competing gesture won) leaves no pending activation behind.
    if (recognizer.state == UIGestureRecognizerStateCancelled ||
        recognizer.state == UIGestureRecognizerStateFailed ||
        recognizer.state == UIGestureRecognizerStateEnded) {
        self.activatingTouchesAtBegin = 0;
    }
}

- (void)tryActivate {
    GPSLabOverlayPresenter *presenter = [GPSLabOverlayPresenter sharedPresenter];
    if (presenter.isPresenting) {
        return;
    }

    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (self.lastActivationTime > 0.0 &&
        (now - self.lastActivationTime) < kGPSLabActivationCooldown) {
        // Cooldown: prevents leftover fingers / quick repeats from re-opening.
        return;
    }

    self.lastActivationTime = now;

    // Update on the main queue even though the recognizer is main-thread bound.
    dispatch_async(dispatch_get_main_queue(), ^{
        GPSLabOverlayPresenter *mainPresenter = [GPSLabOverlayPresenter sharedPresenter];
        if (mainPresenter.isPresenting) {
            return;
        }
        [mainPresenter presentOverlay];
    });
}

#pragma mark - UIGestureRecognizerDelegate

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
        shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    // Let the host app keep every gesture it already recognizes.
    return YES;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    // Never begin while the overlay is already open: leftover fingers from the
    // activating press cannot start a new activation session.
    if ([GPSLabOverlayPresenter sharedPresenter].isPresenting) {
        return NO;
    }
    if (gestureRecognizer.numberOfTouches != 3) {
        return NO;
    }
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
shouldReceiveTouch:(UITouch *)touch {
    // The recognizer observes but never consumes host touches.
    return YES;
}

@end
