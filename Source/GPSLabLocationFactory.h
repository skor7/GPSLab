//
//  GPSLabLocationFactory.h
//  GPSLab
//
//  Builds synthetic CLLocation objects with a fresh timestamp and realistic
//  accuracy bands. Stationary fixes report speed 0 and course -1 (or a configured
//  heading); route fixes report the derived course and speed.
//

#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

NS_ASSUME_NONNULL_BEGIN

@interface GPSLabLocationFactory : NSObject

+ (CLLocation *)staticLocationWithCoordinate:(CLLocationCoordinate2D)coordinate
                                    altitude:(double)altitude
                                     heading:(double)heading;

+ (CLLocation *)routeLocationWithCoordinate:(CLLocationCoordinate2D)coordinate
                                   altitude:(double)altitude
                                    heading:(double)heading
                            speedMetersPerSec:(double)speedMetersPerSec;

@end

NS_ASSUME_NONNULL_END
