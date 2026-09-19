//
//  GPSLabGestureActivator.h
//  GPSLab
//
//  A three-finger continuous press (about 0.8s) activates the overlay.
//  The recognizer never consumes host touches (`cancelsTouchesInView = NO`), and
//  the movement threshold is conservative to avoid accidental activation.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Centralized activation constants. Exactly this many fingers, held continuously for
// this long, within this movement tolerance; a short cooldown prevents retriggering.
// scripts/validate.sh pins these values.
FOUNDATION_EXPORT const NSTimeInterval kGPSLabActivationPressDuration;   // 0.9 s
FOUNDATION_EXPORT const CGFloat kGPSLabActivationMovementTolerance;      // 10 pt
FOUNDATION_EXPORT const NSTimeInterval kGPSLabActivationCooldown;        // 1.0 s
FOUNDATION_EXPORT const NSUInteger kGPSLabActivationRequiredTouches;     // 3

@interface GPSLabGestureActivator : NSObject

+ (instancetype)sharedActivator;

/** Installs the recognizer on the key window. Safe to call repeatedly. */
- (void)installOnWindow:(UIWindow *)window;

/** Removes the recognizer (used on teardown). */
- (void)uninstall;

@end

NS_ASSUME_NONNULL_END
