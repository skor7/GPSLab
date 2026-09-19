//
//  GPSLabOverlayPresenter.m
//  GPSLab
//
//  Floating overlay window management. The presenter is deliberately conservative:
//  it never touches app windows, never overrides UIApplication window properties and
//  only hosts its own window on the active UIWindowScene.
//

#import "GPSLabOverlayPresenter.h"

#import <UIKit/UIKit.h>

#import "Diagnostics.h"
#import "GPSLabLicenseManager.h"
#import "GPSLabOverlayViewController.h"
#import "GPSLabPrimaryInterface.h"
#import "GPSLabSubscriptionViewController.h"

@interface GPSLabOverlayPresenter ()
@property (nonatomic, strong, nullable) UIWindow *overlayWindow;
@property (nonatomic, strong, nullable) UIViewController *primaryViewController;
@property (nonatomic, assign, getter=isPresenting) BOOL presenting;
@end
@implementation GPSLabOverlayPresenter

+ (instancetype)sharedPresenter {
    static GPSLabOverlayPresenter *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[GPSLabOverlayPresenter alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        // Swap the window's root in place when the entitlement unlocks/locks while the
        // overlay is open. The window and its scene are never re-created here.
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(licenseStateDidChange:)
                                                     name:GPSLabLicenseStateDidChangeNotification
                                                   object:nil];
    }
    return self;
}

+ (BOOL)install {
    (void)[self sharedPresenter];
    return YES;
}

+ (BOOL)isInstalled {
    return [self sharedPresenter] != nil;
}

#pragma mark - Scene helpers

static UIWindowScene *GPSLabActiveWindowScene(void) {
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
            if (windowScene.activationState == UISceneActivationStateForegroundActive) {
                return windowScene;
            }
        }
        for (UIScene *scene in application.connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]] &&
                scene.activationState != UISceneActivationStateUnattached) {
                return (UIWindowScene *)scene;
            }
        }
    }
    return nil;
}

static UIWindow *GPSLabKeyWindow(void) {
    UIApplication *application = [UIApplication sharedApplication];
    if (application == nil) {
        return nil;
    }

    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in application.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) {
                continue;
            }
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
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

#pragma mark - Presentation

- (void)presentOverlay {
    UIWindowScene *scene = GPSLabActiveWindowScene();
    if (scene == nil) {
        GPSLabDiagInternalError(10);
        return;
    }

    // A UIWindow cannot migrate between scenes. If an existing window belongs to a
    // different scene, tear it down first and rebuild on the active scene.
    if (self.overlayWindow != nil && self.overlayWindow.windowScene != scene) {
        [self dismissOverlay];
    }

    if (self.overlayWindow == nil) {
        UIWindow *window = [[UIWindow alloc] initWithWindowScene:scene];
        window.windowLevel = UIWindowLevelAlert + 1.0;
        window.backgroundColor = UIColor.clearColor;
        // Single selection point: the primary interface is the map-first overlay today
        // and can become a subscription screen in a later phase without touching the
        // runtime, hook layer or this presenter.
        window.rootViewController = [GPSLabPrimaryInterface makePrimaryViewController];
        window.hidden = NO;
        self.overlayWindow = window;
        self.primaryViewController = window.rootViewController;
    }

    self.overlayWindow.hidden = NO;
    self.presenting = YES;
    GPSLabDiagOverlayOpened();
}

- (void)dismissOverlay {
    if (self.overlayWindow == nil) {
        self.presenting = NO;
        return;
    }
    self.overlayWindow.hidden = YES;
    self.overlayWindow.rootViewController = nil;
    self.overlayWindow = nil;
    self.primaryViewController = nil;
    self.presenting = NO;
    GPSLabDiagOverlayClosed();
}

- (void)handleSceneChange {
    if (!self.presenting) {
        return;
    }

    UIWindowScene *scene = GPSLabActiveWindowScene();
    if (scene == nil) {
        return;
    }

    if (self.overlayWindow != nil && self.overlayWindow.windowScene != scene) {
        // Re-create the window on the new scene; UIWindow cannot migrate scenes.
        [self dismissOverlay];
        [self presentOverlay];
        return;
    }

    // Keep the overlay above the (possibly new) key window.
    UIWindow *keyWindow = GPSLabKeyWindow();
    if (keyWindow != nil && self.overlayWindow != nil &&
        self.overlayWindow.windowLevel <= keyWindow.windowLevel) {
        self.overlayWindow.windowLevel = keyWindow.windowLevel + 1.0;
    }
}

- (void)handleDidEnterBackground {
    // The window stays alive but the UI is hidden by the system; nothing to do.
}

- (void)handleWillEnterForeground {
    [self handleSceneChange];
}

#pragma mark - Entitlement transitions

- (void)licenseStateDidChange:(NSNotification *)notification {
    (void)notification;
    if (!self.presenting || self.overlayWindow == nil) {
        return;
    }
    BOOL unlocked = [[GPSLabLicenseManager sharedManager] isUnlocked];
    BOOL showingSubscription =
        [self.overlayWindow.rootViewController isKindOfClass:[GPSLabSubscriptionViewController class]];
    BOOL showingCanvas = [self.overlayWindow.rootViewController isKindOfClass:[GPSLabOverlayViewController class]];

    if (unlocked && showingSubscription) {
        self.overlayWindow.rootViewController = [[GPSLabOverlayViewController alloc] init];
        self.primaryViewController = self.overlayWindow.rootViewController;
    } else if (!unlocked && showingCanvas) {
        self.overlayWindow.rootViewController = [[GPSLabSubscriptionViewController alloc] init];
        self.primaryViewController = self.overlayWindow.rootViewController;
    }
}

@end
