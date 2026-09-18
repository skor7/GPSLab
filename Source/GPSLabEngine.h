//
//  GPSLabEngine.h
//  GPSLab
//
//  Clean-room synthetic location engine.
//

#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * Thread-safe source of synthetic CLLocation objects.
 *
 * The base (anchor) coordinate is shared process-wide. Every generated location is
 * derived from a bounded random walk around that anchor and never exceeds the
 * documented walk radius in geodesic terms.
 */
@interface GPSLabEngine : NSObject

/** Shared engine instance. */
+ (instancetype)sharedEngine;

#pragma mark - Anchor configuration

/**
 * Sets the anchor coordinate used by all generated locations and resets the walk
 * offset back to the anchor.
 */
+ (void)setBaseLatitude:(double)latitude
              longitude:(double)longitude
               altitude:(double)altitude;

/** Current anchor coordinate. */
+ (CLLocationCoordinate2D)baseCoordinate;

#pragma mark - Location generation

/** Returns the current synthetic location without advancing the random walk. */
- (CLLocation *)currentLocation;

/** Advances the bounded random walk and returns the new synthetic location. */
- (CLLocation *)nextLocation;

@end

NS_ASSUME_NONNULL_END
