//
//  LocationStream.h
//  GPSLab
//
//  Per-manager synthetic location streams.
//

#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * Owns one independent synthetic stream per CLLocationManager.
 *
 * - Standard updates: one immediate delivery, then one per second.
 * - Significant-change updates: one immediate delivery, then one every 30 seconds.
 * - Single-shot (requestLocation): exactly one delivery.
 *
 * Standard and significant streams for the same manager are independent: stopping
 * one never stops the other.
 */
@interface GPSLabLocationStream : NSObject

+ (instancetype)sharedStream;

- (void)startStandardUpdatesForManager:(CLLocationManager *)manager;
- (void)stopStandardUpdatesForManager:(CLLocationManager *)manager;

- (void)startSignificantUpdatesForManager:(CLLocationManager *)manager;
- (void)stopSignificantUpdatesForManager:(CLLocationManager *)manager;

- (void)deliverSingleUpdateForManager:(CLLocationManager *)manager;

/** Notifies the delegate that authorization was granted (never touches the system). */
- (void)notifyAuthorizationGrantedForManager:(CLLocationManager *)manager;

/** Cancels all timers and forgets the manager (safe to call from -dealloc). */
- (void)unregisterManager:(CLLocationManager *)manager;

@end

NS_ASSUME_NONNULL_END
