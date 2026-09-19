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
#import "GPSLabOverlayViewController.h"

@interface GPSLabOverlayPresenter ()
@property (nonatomic, strong, nullable) UIWindow *overlayWindow;
@property (nonatomic, strong, nullable) GPSLabOverlayViewController *overlayViewController;
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
        window.rootViewController = [[GPSLabOverlayViewController alloc] init];
        window.hidden = NO;
        self.overlayWindow = window;
        self.overlayViewController = (GPSLabOverlayViewController *)window.rootViewController;
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
    self.overlayViewController = nil;
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

@end
