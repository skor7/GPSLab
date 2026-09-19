//
//  CoreLocationHooks.h
//  GPSLab
//
//  CoreLocation interception via the Objective-C runtime only.
//
//  The hook layer owns a per-manager bypass flag: while a manager is bypassed, every
//  intercepted selector calls the original CoreLocation implementation and the
//  synthetic engine ignores it. The overlay's own display CLLocationManager uses this
//  so showing the real user location never mixes with synthetic delivery.
//

#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

NS_ASSUME_NONNULL_BEGIN

@interface GPSLabCoreLocationHooks : NSObject

/** Installs every CoreLocation interception once. Returns YES when installed. */
+ (BOOL)installHooks;

/** Whether interception has been installed. */
+ (BOOL)areHooksInstalled;

#pragma mark - Per-manager bypass

/**
 * Marks a manager as bypassed (or clears it). Bypassed managers always receive the
 * original CoreLocation behavior and never synthetic fixes. Safe to call from any
 * thread; the association is process-wide.
 */
+ (void)setBypassed:(BOOL)bypassed forManager:(CLLocationManager *)manager;

/** Whether the manager is currently bypassed. */
+ (BOOL)isBypassedManager:(CLLocationManager *)manager;

#pragma mark - Original-implementation passthrough

/**
 * Invokes the original implementation of the intercepted selector for a manager.
 * Used to hand a manager back to real CoreLocation when the engine is disabled.
 * Returns NO when the selector is not intercepted or no original was captured.
 */
+ (BOOL)forwardSelector:(SEL)selector onManager:(CLLocationManager *)manager;

@end

NS_ASSUME_NONNULL_END
