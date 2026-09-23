//
//  GPSLabDriftModel.h
//  GPSLab
//
//  Bounded correlated random walk around an anchor coordinate.
//  The model never lets the generated point leave `radius` meters (geodesic) of
//  the anchor, and a radius of 0 always yields the anchor itself.
//
//  The random source is injectable so tests can be deterministic and non-flaky;
//  production uses arc4random.
//

#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

NS_ASSUME_NONNULL_BEGIN

/** Returns a random double in [0, 1]. */
typedef double (^GPSLabDriftRandomUnitProvider)(void);

@interface GPSLabDriftModel : NSObject

/** Default initializer. Uses the production arc4random source. */
- (instancetype)init;

/** Designated initializer. A nil provider falls back to arc4random. */
- (instancetype)initWithRandomUnitProvider:(nullable GPSLabDriftRandomUnitProvider)provider
    NS_DESIGNATED_INITIALIZER;

/**
 * Injectable random source. Setting nil restores the production arc4random source.
 * The block is copied. Changing it does not reset the current walk offset.
 */
@property (nonatomic, copy, nullable) GPSLabDriftRandomUnitProvider randomUnitProvider;

/** Resets the internal offset back to the anchor. */
- (void)reset;

/** Returns the current offset as a coordinate without advancing the walk. */
- (CLLocationCoordinate2D)currentAroundAnchor:(CLLocationCoordinate2D)anchor;

/**
 * Advances the correlated walk by one step and returns the new coordinate. The
 * returned point is always within `radius` meters of `anchor`; when radius is 0
 * the walk resets and the anchor is returned unchanged.
 */
- (CLLocationCoordinate2D)advanceAroundAnchor:(CLLocationCoordinate2D)anchor
                                       radius:(double)radius
                                   stepMeters:(double)stepMeters;

@end

NS_ASSUME_NONNULL_END
