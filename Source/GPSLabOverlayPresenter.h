//
//  GPSLabOverlayPresenter.h
//  GPSLab
//
//  Installs and removes the floating GPSLab overlay window on top of the host app.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface GPSLabOverlayPresenter : NSObject

+ (instancetype)sharedPresenter;

/** Installs the activator. Safe to call multiple times. Returns YES when installed. */
+ (BOOL)install;

/** Whether the overlay installer is active. */
+ (BOOL)isInstalled;

/** Whether the overlay window is currently on screen. */
@property (nonatomic, readonly, getter=isPresenting) BOOL presenting;

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
