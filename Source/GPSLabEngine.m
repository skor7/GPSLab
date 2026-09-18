//
//  GPSLabEngine.m
//  GPSLab
//
//  Clean-room synthetic location engine.
//

#import "GPSLabEngine.h"

#import <math.h>
#import <os/lock.h>

// Bounded random walk.
static const double kGPSLabMaxWalkRadiusMeters = 8.0;
static const double kGPSLabMaxStepMeters = 1.5;

// Very small-angle geodesic approximation constants.
static const double kGPSLabMetersPerDegreeLatitude = 111320.0;
static const double kGPSLabMinCosLatitude = 0.01; // keeps longitude math finite at the poles
static const double kGPSLabEarthRadiusMeters = 6371008.8;

// Accuracy bands (meters).
static const double kGPSLabHorizontalAccuracyMin = 5.0;
static const double kGPSLabHorizontalAccuracyMax = 20.0;
static const double kGPSLabVerticalAccuracyMin = 8.0;
static const double kGPSLabVerticalAccuracyMax = 25.0;

// All mutable engine state lives in static storage and is protected by a single lock.
static os_unfair_lock gGPSLabStateLock = OS_UNFAIR_LOCK_INIT;
static double gGPSLabBaseLatitude = 0.0;
static double gGPSLabBaseLongitude = 0.0;
static double gGPSLabBaseAltitude = 0.0;
static double gGPSLabOffsetNorthMeters = 0.0;
static double gGPSLabOffsetEastMeters = 0.0;

// Helpers (definitions at the bottom of this file).
static double GPSLabRandomUnit(void);
static double GPSLabRandomInRange(double minValue, double maxValue);
static CLLocationCoordinate2D GPSLabCoordinateFromOffsets(double baseLatitude,
                                                          double baseLongitude,
                                                          double northMeters,
                                                          double eastMeters);
static double GPSLabDistanceMeters(CLLocationCoordinate2D from, CLLocationCoordinate2D to);

@implementation GPSLabEngine

+ (instancetype)sharedEngine {
    static GPSLabEngine *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[GPSLabEngine alloc] init];
    });
    return instance;
}

#pragma mark - Anchor configuration

+ (void)setBaseLatitude:(double)latitude
              longitude:(double)longitude
               altitude:(double)altitude {
    os_unfair_lock_lock(&gGPSLabStateLock);
    gGPSLabBaseLatitude = latitude;
    gGPSLabBaseLongitude = longitude;
    gGPSLabBaseAltitude = altitude;
    gGPSLabOffsetNorthMeters = 0.0;
    gGPSLabOffsetEastMeters = 0.0;
    os_unfair_lock_unlock(&gGPSLabStateLock);
}

+ (CLLocationCoordinate2D)baseCoordinate {
    os_unfair_lock_lock(&gGPSLabStateLock);
    CLLocationCoordinate2D coordinate = CLLocationCoordinate2DMake(gGPSLabBaseLatitude,
                                                                   gGPSLabBaseLongitude);
    os_unfair_lock_unlock(&gGPSLabStateLock);
    return coordinate;
}

#pragma mark - Location generation

- (CLLocation *)currentLocation {
    return [self locationAdvancingWalk:NO];
}

- (CLLocation *)nextLocation {
    return [self locationAdvancingWalk:YES];
}

- (CLLocation *)locationAdvancingWalk:(BOOL)advance {
    double north = 0.0;
    double east = 0.0;
    double baseLatitude = 0.0;
    double baseLongitude = 0.0;
    double baseAltitude = 0.0;

    os_unfair_lock_lock(&gGPSLabStateLock);

    if (advance) {
        double candidateNorth = gGPSLabOffsetNorthMeters +
            GPSLabRandomInRange(-kGPSLabMaxStepMeters, kGPSLabMaxStepMeters);
        double candidateEast = gGPSLabOffsetEastMeters +
            GPSLabRandomInRange(-kGPSLabMaxStepMeters, kGPSLabMaxStepMeters);

        double radius = hypot(candidateNorth, candidateEast);
        if (radius > kGPSLabMaxWalkRadiusMeters && radius > 0.0) {
            double scale = kGPSLabMaxWalkRadiusMeters / radius;
            candidateNorth *= scale;
            candidateEast *= scale;
        }

        gGPSLabOffsetNorthMeters = candidateNorth;
        gGPSLabOffsetEastMeters = candidateEast;
    }

    north = gGPSLabOffsetNorthMeters;
    east = gGPSLabOffsetEastMeters;
    baseLatitude = gGPSLabBaseLatitude;
    baseLongitude = gGPSLabBaseLongitude;
    baseAltitude = gGPSLabBaseAltitude;

    os_unfair_lock_unlock(&gGPSLabStateLock);

    CLLocationCoordinate2D anchor = CLLocationCoordinate2DMake(baseLatitude, baseLongitude);
    CLLocationCoordinate2D coordinate = GPSLabCoordinateFromOffsets(baseLatitude,
                                                                   baseLongitude,
                                                                   north,
                                                                   east);

    // Belt-and-braces geodesic clamp: the local tangent-plane offset is already
    // bounded, but never emit a point farther than the walk radius from the anchor.
    if (GPSLabDistanceMeters(anchor, coordinate) > kGPSLabMaxWalkRadiusMeters) {
        double radius = hypot(north, east);
        if (radius > 0.0) {
            double scale = kGPSLabMaxWalkRadiusMeters / radius;
            coordinate = GPSLabCoordinateFromOffsets(baseLatitude,
                                                     baseLongitude,
                                                     north * scale,
                                                     east * scale);
        }
    }

    return [self locationWithCoordinate:coordinate altitude:baseAltitude];
}

- (CLLocation *)locationWithCoordinate:(CLLocationCoordinate2D)coordinate
                              altitude:(double)altitude {
    // A stationary receiver: speed is zero and course is invalid (-1).
    return [[CLLocation alloc] initWithCoordinate:coordinate
                                         altitude:altitude
                               horizontalAccuracy:GPSLabRandomInRange(kGPSLabHorizontalAccuracyMin,
                                                                      kGPSLabHorizontalAccuracyMax)
                                 verticalAccuracy:GPSLabRandomInRange(kGPSLabVerticalAccuracyMin,
                                                                      kGPSLabVerticalAccuracyMax)
                                           course:-1.0
                                            speed:0.0
                                        timestamp:[NSDate date]];
}

@end

#pragma mark - Helpers

static double GPSLabRandomUnit(void) {
    return (double)arc4random() / (double)UINT32_MAX;
}

static double GPSLabRandomInRange(double minValue, double maxValue) {
    return minValue + ((maxValue - minValue) * GPSLabRandomUnit());
}

static CLLocationCoordinate2D GPSLabCoordinateFromOffsets(double baseLatitude,
                                                          double baseLongitude,
                                                          double northMeters,
                                                          double eastMeters) {
    double latitude = baseLatitude + (northMeters / kGPSLabMetersPerDegreeLatitude);
    if (latitude > 90.0) {
        latitude = 90.0;
    } else if (latitude < -90.0) {
        latitude = -90.0;
    }

    double cosLatitude = cos(latitude * M_PI / 180.0);
    if (fabs(cosLatitude) < kGPSLabMinCosLatitude) {
        cosLatitude = (cosLatitude < 0.0) ? -kGPSLabMinCosLatitude : kGPSLabMinCosLatitude;
    }

    double longitude = baseLongitude +
        (eastMeters / (kGPSLabMetersPerDegreeLatitude * cosLatitude));
    longitude = fmod(longitude + 540.0, 360.0) - 180.0;

    return CLLocationCoordinate2DMake(latitude, longitude);
}

static double GPSLabDistanceMeters(CLLocationCoordinate2D from, CLLocationCoordinate2D to) {
    double lat1 = from.latitude * M_PI / 180.0;
    double lat2 = to.latitude * M_PI / 180.0;
    double deltaLat = lat2 - lat1;
    double deltaLon = (to.longitude - from.longitude) * M_PI / 180.0;

    double sinHalfLat = sin(deltaLat / 2.0);
    double sinHalfLon = sin(deltaLon / 2.0);
    double h = (sinHalfLat * sinHalfLat) +
        (cos(lat1) * cos(lat2) * sinHalfLon * sinHalfLon);
    if (h > 1.0) {
        h = 1.0;
    }

    return 2.0 * kGPSLabEarthRadiusMeters * asin(sqrt(h));
}
