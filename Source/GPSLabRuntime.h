//
//  GPSLabRuntime.h
//  GPSLab
//
//  Lifecycle coordinator. Installs the gesture activator after the app is ready,
//  tracks scene/window changes and forwards foreground/background transitions.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface GPSLabRuntime : NSObject

+ (instancetype)sharedRuntime;

/** Starts observing UIApplication/scene notifications. Safe to call repeatedly. */
- (void)install;

/** Stops observing and tears the overlay down. */
- (void)uninstall;

/** Attaches the activator to the current key window (retries while none exists). */
- (void)attachActivatorToKeyWindow;

@end

NS_ASSUME_NONNULL_END
