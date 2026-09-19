//
//  GPSLabLocationFactory.m
//  GPSLab
//
//  Synthetic CLLocation construction. No real data is read or written.
//

#import "GPSLabLocationFactory.h"

#import "GPSLabGeodesy.h"

// Stationary accuracy bands (meters).
static const double kGPSLabStaticHorizontalAccuracyMin = 5.0;
static const double kGPSLabStaticHorizontalAccuracyMax = 20.0;
static const double kGPSLabStaticVerticalAccuracyMin = 8.0;
static const double kGPSLabStaticVerticalAccuracyMax = 25.0;

// Route accuracy bands (meters) are a little tighter, as a moving fix usually is.
static const double kGPSLabRouteHorizontalAccuracyMin = 3.0;
static const double kGPSLabRouteHorizontalAccuracyMax = 12.0;
static const double kGPSLabRouteVerticalAccuracyMin = 6.0;
static const double kGPSLabRouteVerticalAccuracyMax = 18.0;

static double GPSLabRandomUnit(void) {
    return (double)arc4random() / (double)UINT32_MAX;
}

static double GPSLabRandomInRange(double minValue, double maxValue) {
    return minValue + ((maxValue - minValue) * GPSLabRandomUnit());
}

@implementation GPSLabLocationFactory

+ (CLLocation *)staticLocationWithCoordinate:(CLLocationCoordinate2D)coordinate
                                    altitude:(double)altitude
                                     heading:(double)heading {
    double course = GPSLabNormalizeHeading(heading);
    return [[CLLocation alloc] initWithCoordinate:coordinate
                                         altitude:altitude
                               horizontalAccuracy:GPSLabRandomInRange(kGPSLabStaticHorizontalAccuracyMin,
                                                                      kGPSLabStaticHorizontalAccuracyMax)
                                 verticalAccuracy:GPSLabRandomInRange(kGPSLabStaticVerticalAccuracyMin,
                                                                      kGPSLabStaticVerticalAccuracyMax)
                                           course:course
                                            speed:0.0
                                        timestamp:[NSDate date]];
}

+ (CLLocation *)routeLocationWithCoordinate:(CLLocationCoordinate2D)coordinate
                                   altitude:(double)altitude
                                    heading:(double)heading
                          speedMetersPerSec:(double)speedMetersPerSec {
    double course = GPSLabNormalizeHeading(heading);
    if (course < 0.0) {
        course = -1.0;
    }
    double speed = speedMetersPerSec > 0.0 ? speedMetersPerSec : 0.0;
    return [[CLLocation alloc] initWithCoordinate:coordinate
                                         altitude:altitude
                               horizontalAccuracy:GPSLabRandomInRange(kGPSLabRouteHorizontalAccuracyMin,
                                                                      kGPSLabRouteHorizontalAccuracyMax)
                                 verticalAccuracy:GPSLabRandomInRange(kGPSLabRouteVerticalAccuracyMin,
                                                                      kGPSLabRouteVerticalAccuracyMax)
                                           course:course
                                            speed:speed
                                        timestamp:[NSDate date]];
}

@end
