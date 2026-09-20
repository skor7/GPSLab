//
//  GPSLabModalCoordinator.h
//  GPSLab
//
//  Single central presentation/close helper for every GPSLab sheet and alert.
//  It serializes transitions on the main queue, presents only from the topmost
//  GPSLab-owned controller, waits for an active search to finish dismissing
//  before presenting, and ignores duplicate taps so no orphaned modal can be
//  queued. The host view controller hierarchy is never touched.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface GPSLabModalCoordinator : NSObject

+ (instancetype)sharedCoordinator;

/** Topmost GPSLab-owned controller (root when no modal is presented). */
- (nullable UIViewController *)topmostGPSLabViewController;

/** YES when any GPSLab modal (sheet or alert) is currently presented. */
@property (nonatomic, readonly) BOOL isPresentingModal;

/** Wraps `root` in the standard GPSLab sheet navigation controller and presents it. */
- (void)presentSheetRoot:(UIViewController *)root
              completion:(nullable void (^)(void))completion;

/** Presents an alert/action sheet on the current topmost GPSLab controller. */
- (void)presentAlert:(UIAlertController *)alert
          completion:(nullable void (^)(void))completion;

/** Dismisses the topmost modal (no-op when only the root remains). */
- (void)dismissTopmostAnimated:(BOOL)animated completion:(nullable void (^)(void))completion;

/** Dismisses every presented modal, innermost first. */
- (void)dismissAllAnimated:(BOOL)animated completion:(nullable void (^)(void))completion;

/**
 * Called by the canvas from `didDismissSearchController`. Runs a presentation
 * that was deferred because search was active. Safe to call when nothing is
 * pending.
 */
- (void)resolvePendingPresentation;

/** Called by the presenter when the overlay window is opened; starts a session. */
- (void)noteSessionOpened;

/** Called by the presenter when the overlay window is torn down. */
- (void)noteSessionClosed;

/** Called when the GPSLab root is swapped in place; invalidates stale queued work. */
- (void)invalidateForRootReplacement;

@end

NS_ASSUME_NONNULL_END
