//
//  GPSLabOverlayPresenter.h
//  GPSLab
//
//  Installs and removes the floating GPSLab overlay window on top of the host app.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface GPSLabOverlayPresenter : NSObject

+ (instancetype)sharedPresenter;

/** Installs the activator. Safe to call multiple times. Returns YES when installed. */
+ (BOOL)install;

/** Whether the overlay installer is active. */
+ (BOOL)isInstalled;

/** Whether the overlay window is currently on screen. */
@property (nonatomic, readonly, getter=isPresenting) BOOL presenting;

/** The GPSLab-owned host window (nil when the overlay is not presented). */
@property (nonatomic, readonly, nullable) UIWindow *hostWindow;

/** The GPSLab-owned root view controller hosted by the overlay window. */
@property (nonatomic, readonly, nullable) UIViewController *rootViewController;

/** Whether the scoped key-window lease is currently held. */
@property (nonatomic, readonly, getter=isKeyLeaseActive) BOOL keyLeaseActive;

/**
 * Acquires the key-window lease so keyboard input is owned by the GPSLab window.
 * Captures the previous key window (same scene) for a conservative restore.
 * Idempotent; safe to call while already key.
 */
- (void)acquireKeyLease;

/**
 * Releases the lease only when GPSLab still holds the key window and the
 * captured target is a visible normal-level window on the same active scene.
 * Never overrides a key window that another window acquired. Safe to call
 * repeatedly or when no lease is held.
 */
- (void)releaseKeyLease;

/** Applies the current catalog language direction to the GPSLab window subtree. */
- (void)applyLanguageAttributes;

/** Presents the overlay for the active scene (creates the window if needed). */
- (void)presentOverlay;

/** Hides and tears down the overlay window; the host app is fully interactive again. */
- (void)dismissOverlay;

/** Re-attaches the overlay to the key window/scene after a scene or window change. */
- (void)handleSceneChange;

/** Called when the app moves to the background. */
- (void)handleDidEnterBackground;

/** Called when the app returns to the foreground. */
- (void)handleWillEnterForeground;

@end

NS_ASSUME_NONNULL_END
