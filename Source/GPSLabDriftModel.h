//
//  GPSLabDriftModel.h
//  GPSLab
//
//  Bounded correlated random walk around an anchor coordinate.
//  The model never lets the generated point leave `radius` meters (geodesic).
//

#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

NS_ASSUME_NONNULL_BEGIN

@interface GPSLabDriftModel : NSObject

/** Resets the internal offset back to the anchor. */
- (void)reset;

/** Returns the current offset as a coordinate without advancing the walk. */
- (CLLocationCoordinate2D)currentAroundAnchor:(CLLocationCoordinate2D)anchor;

/** Advances the correlated walk by one step and returns the new coordinate. */
- (CLLocationCoordinate2D)advanceAroundAnchor:(CLLocationCoordinate2D)anchor
                                      radius:(double)radius
                                  stepMeters:(double)stepMeters;

@end

NS_ASSUME_NONNULL_END
