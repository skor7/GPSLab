//
//  GPSLabRuntime.m
//  GPSLab
//
//  Lifecycle coordinator. Defensive by design: nil windows, nil delegates and
//  disappearing scenes are all treated as normal conditions, never crashes.
//

#import "GPSLabRuntime.h"

#import <UIKit/UIKit.h>

#import "Diagnostics.h"
#import "GPSLabEngine.h"
#import "GPSLabGestureActivator.h"
#import "GPSLabOverlayPresenter.h"
#import "LocationStream.h"

static const NSTimeInterval kGPSLabActivatorRetryInterval = 1.0;
static const NSTimeInterval kGPSLabActivatorRetryDuration = 30.0;

// Forward declaration: defined near the bottom of this file.
static UIWindow *GPSLabRuntimeKeyWindow(void) __attribute__((warn_unused_result));

@interface GPSLabRuntime ()
@property (nonatomic, assign, getter=isInstalled) BOOL installed;
@property (nonatomic, strong, nullable) NSTimer *attachTimer;
@property (nonatomic, assign) NSTimeInterval attachAttemptStart;
@property (nonatomic, weak, nullable) UIWindow *attachedWindow;
@end

@implementation GPSLabRuntime

+ (instancetype)sharedRuntime {
    static GPSLabRuntime *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[GPSLabRuntime alloc] init];
    });
    return instance;
}

- (void)install {
    if (self.isInstalled) {
        return;
    }
    self.installed = YES;

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self
               selector:@selector(applicationDidBecomeActive:)
                   name:UIApplicationDidBecomeActiveNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(applicationDidEnterBackground:)
                   name:UIApplicationDidEnterBackgroundNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(applicationWillEnterForeground:)
                   name:UIApplicationWillEnterForegroundNotification
                 object:nil];

    if (@available(iOS 13.0, *)) {
        [center addObserver:self
                   selector:@selector(sceneDidActivate:)
                       name:UISceneDidActivateNotification
                     object:nil];
        [center addObserver:self
                   selector:@selector(sceneWillConnect:)
                       name:UISceneWillConnectNotification
                     object:nil];
        [center addObserver:self
                   selector:@selector(sceneDidDisconnect:)
                       name:UISceneDidDisconnectNotification
                     object:nil];
    }

    [center addObserver:self
               selector:@selector(windowDidBecomeVisible:)
                   name:UIWindowDidBecomeVisibleNotification
                 object:nil];

    [self attachActivatorToKeyWindow];
}

- (void)uninstall {
    if (!self.isInstalled) {
        return;
    }
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [[GPSLabGestureActivator sharedActivator] uninstall];
    [[GPSLabOverlayPresenter sharedPresenter] dismissOverlay];
    [self stopAttachTimer];
    self.attachedWindow = nil;
    self.installed = NO;
}

#pragma mark - Activator attachment

- (void)attachActivatorToKeyWindow {
    UIWindow *keyWindow = GPSLabRuntimeKeyWindow();
    if (keyWindow != nil) {
        [[GPSLabGestureActivator sharedActivator] installOnWindow:keyWindow];
        self.attachedWindow = keyWindow;
        [self stopAttachTimer];
        return;
    }

    if (self.attachTimer != nil) {
        return;
    }
    self.attachAttemptStart = [NSDate timeIntervalSinceReferenceDate];
    GPSLabRuntime *__weak weakSelf = self;
    self.attachTimer = [NSTimer scheduledTimerWithTimeInterval:kGPSLabActivatorRetryInterval
                                                       repeats:YES
                                                         block:^(NSTimer *timer) {
        GPSLabRuntime *strongSelf = weakSelf;
        if (strongSelf == nil) {
            [timer invalidate];
            return;
        }
        UIWindow *window = GPSLabRuntimeKeyWindow();
        if (window != nil) {
            [[GPSLabGestureActivator sharedActivator] installOnWindow:window];
            strongSelf.attachedWindow = window;
            [strongSelf stopAttachTimer];
            return;
        }
        NSTimeInterval elapsed = [NSDate timeIntervalSinceReferenceDate] - strongSelf.attachAttemptStart;
        if (elapsed > kGPSLabActivatorRetryDuration) {
            [strongSelf stopAttachTimer];
            GPSLabDiagInternalError(11);
        }
    }];
}

- (void)stopAttachTimer {
    if (self.attachTimer != nil) {
        [self.attachTimer invalidate];
        self.attachTimer = nil;
    }
}

#pragma mark - Notifications

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    [self attachActivatorToKeyWindow];
}

- (void)applicationDidEnterBackground:(NSNotification *)notification {
    [[GPSLabOverlayPresenter sharedPresenter] handleDidEnterBackground];
    // Suspend synthetic timers but keep the recorded intent so foreground can resume.
    // No original streams are started while backgrounded; the engine state is unchanged.
    [[GPSLabLocationStream sharedStream] suspendAllSyntheticPreservingIntent];
}

- (void)applicationWillEnterForeground:(NSNotification *)notification {
    [[GPSLabOverlayPresenter sharedPresenter] handleWillEnterForeground];
    // Resume synthetic delivery for whatever the host asked for, but only while the
    // synthetic engine is enabled.
    if ([[GPSLabEngine sharedEngine] isEnabled]) {
        [[GPSLabLocationStream sharedStream] resumeAllRequestedSynthetic];
    }
    [self attachActivatorToKeyWindow];
}

- (void)sceneDidActivate:(NSNotification *)notification {
    [self attachActivatorToKeyWindow];
    [[GPSLabOverlayPresenter sharedPresenter] handleSceneChange];
}

- (void)sceneWillConnect:(NSNotification *)notification {
    [self attachActivatorToKeyWindow];
}

- (void)sceneDidDisconnect:(NSNotification *)notification {
    [[GPSLabOverlayPresenter sharedPresenter] handleSceneChange];
    [self attachActivatorToKeyWindow];
}

- (void)windowDidBecomeVisible:(NSNotification *)notification {
    [self attachActivatorToKeyWindow];
}

#pragma mark - Helpers

static UIWindow *GPSLabRuntimeKeyWindow(void) {
    UIApplication *application = [UIApplication sharedApplication];
    if (application == nil) {
        return nil;
    }

    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in application.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) {
                continue;
            }
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            if (windowScene.activationState != UISceneActivationStateForegroundActive) {
                continue;
            }
            for (UIWindow *window in windowScene.windows) {
                if (window.isKeyWindow) {
                    return window;
                }
            }
        }
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    for (UIWindow *window in application.windows) {
        if (window.isKeyWindow) {
            return window;
        }
    }
#pragma clang diagnostic pop
    return nil;
}

@end
