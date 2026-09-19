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

@interface GPSLabGestureActivator : NSObject

+ (instancetype)sharedActivator;

/** Installs the recognizer on the key window. Safe to call repeatedly. */
- (void)installOnWindow:(UIWindow *)window;

/** Removes the recognizer (used on teardown). */
- (void)uninstall;

@end

NS_ASSUME_NONNULL_END
