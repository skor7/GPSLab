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
#import "GPSLabLocalization.h"
#import "GPSLabModalCoordinator.h"
#import "GPSLabOverlayViewController.h"
#import "GPSLabPrimaryInterface.h"
#import "GPSLabSubscriptionViewController.h"

// Defined below in the scene helpers; used by the key-window lease above it.
static UIWindow *GPSLabKeyWindow(void);

@interface GPSLabOverlayPresenter ()
@property (nonatomic, strong, nullable) UIWindow *overlayWindow;
@property (nonatomic, strong, nullable) UIViewController *primaryViewController;
@property (nonatomic, assign, getter=isPresenting) BOOL presenting;
// Scoped key-window lease: the host window captured when GPSLab first took key.
@property (nonatomic, weak, nullable) UIWindow *previousKeyWindow;
@property (nonatomic, assign, getter=isKeyLeaseActive) BOOL keyLeaseActive;
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
        // Re-apply the GPSLab-only text direction when the UI language changes.
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(languageDidChange:)
                                                     name:GPSLabLanguageDidChangeNotification
                                                   object:nil];
        // Re-acquire the key lease when a window scene becomes active again (the
        // willEnterForeground notification can arrive while the scene is still
        // inactive). Scoped to the overlay's own scene; never steals other scenes.
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(sceneDidActivate:)
                                                     name:UISceneDidActivateNotification
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

#pragma mark - Accessors

- (UIWindow *)hostWindow {
    return self.overlayWindow;
}

- (UIViewController *)rootViewController {
    return self.primaryViewController;
}

#pragma mark - Scoped key-window lease

- (void)acquireKeyLease {
    UIWindow *overlay = self.overlayWindow;
    // Never unhide or re-key a hidden/orphaned overlay, and never take key while
    // the overlay's scene is not the foreground-active one.
    if (overlay == nil || overlay.isHidden || overlay.windowScene == nil) {
        return;
    }
    if (overlay.windowScene.activationState != UISceneActivationStateForegroundActive) {
        return;
    }
    if (overlay.isKeyWindow) {
        self.keyLeaseActive = YES;
        return;
    }

    // Capture the previous key window only when it shares the overlay's scene;
    // a window from another scene must never be re-keyed.
    UIWindow *current = GPSLabKeyWindow();
    if (current != nil && current != overlay && current.windowScene == overlay.windowScene) {
        self.previousKeyWindow = current;
    }

    [overlay makeKeyWindow];
    self.keyLeaseActive = overlay.isKeyWindow;
}

- (void)releaseKeyLease {
    UIWindow *overlay = self.overlayWindow;
    UIWindow *previous = self.previousKeyWindow;
    self.previousKeyWindow = nil;
    self.keyLeaseActive = NO;

    // Only restore when GPSLab still holds key; if another window became key we
    // must not steal it back.
    if (overlay == nil || previous == nil || !overlay.isKeyWindow) {
        return;
    }
    if (previous.windowScene != overlay.windowScene) {
        return;
    }
    if (previous.isHidden) {
        return;
    }
    // Only a normal-level host window is a valid restore target.
    if (previous.windowLevel != UIWindowLevelNormal) {
        return;
    }
    [previous makeKeyWindow];
}

- (void)applyLanguageAttributes {
    UIWindow *window = self.overlayWindow;
    if (window == nil) {
        return;
    }
    [GPSLabLocalization applyLanguageAttributesToView:window];
}

- (void)languageDidChange:(NSNotification *)notification {
    (void)notification;
    [self applyLanguageAttributes];
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
    [[GPSLabModalCoordinator sharedCoordinator] noteSessionOpened];
    [self applyLanguageAttributes];
    [self acquireKeyLease];
    GPSLabDiagOverlayOpened();
}

- (void)dismissOverlay {
    if (self.overlayWindow == nil) {
        [[GPSLabModalCoordinator sharedCoordinator] noteSessionClosed];
        [self releaseKeyLease];
        self.presenting = NO;
        return;
    }
    [[GPSLabModalCoordinator sharedCoordinator] noteSessionClosed];
    [self releaseKeyLease];
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
    // The window stays alive but the UI is hidden by the system; drop the key
    // lease so the host is not left behind a non-interactive GPSLab window.
    [self releaseKeyLease];
}

- (void)handleWillEnterForeground {
    [self handleSceneChange];
    // Only succeeds when the overlay's scene is already foreground-active; the
    // windowSceneDidActivate observer covers the case where it is not yet.
    [self acquireKeyLease];
}

- (void)sceneDidActivate:(NSNotification *)notification {
    UIScene *scene = [notification.object isKindOfClass:[UIScene class]]
        ? (UIScene *)notification.object
        : nil;
    if (scene == nil || !self.presenting) {
        return;
    }
    UIWindow *overlay = self.overlayWindow;
    if (overlay == nil || overlay.windowScene != scene) {
        return;
    }
    [self acquireKeyLease];
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
    } else {
        return;
    }
    // The root swap may have torn down the search/keyboard session; invalidate
    // stale queued modal work, release the lease and re-apply the scoped text
    // direction to the new subtree.
    [[GPSLabModalCoordinator sharedCoordinator] invalidateForRootReplacement];
    [self releaseKeyLease];
    [self applyLanguageAttributes];
}

@end
