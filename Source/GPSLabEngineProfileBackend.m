//
//  GPSLabEngineProfileBackend.m
//  GPSLab
//

#import "GPSLabEngineProfileBackend.h"

#import "GPSLabConfiguration.h"
#import "GPSLabEngine.h"
#import "GPSLabGeodesy.h"
#import "GPSLabLicenseManager.h"
#import "GPSLabTypes.h"

@implementation GPSLabEngineProfileBackend

- (BOOL)isEngineEnabled {
    return [GPSLabEngine sharedEngine].isEnabled;
}

- (BOOL)isLicenseUnlocked {
    return [[GPSLabLicenseManager sharedManager] isUnlocked];
}

- (void)applyStaticCoordinate:(CLLocationCoordinate2D)coordinate
                     altitude:(double)altitude
                      heading:(double)heading {
    if (!GPSLabIsValidCoordinate(coordinate.latitude, coordinate.longitude)) {
        return;
    }
    GPSLabConfiguration *configuration = [[GPSLabEngine sharedEngine] configuration];
    configuration.latitude = coordinate.latitude;
    configuration.longitude = coordinate.longitude;
    configuration.altitude = GPSLabClampDouble(altitude, -500.0, 100000.0);
    configuration.heading = GPSLabNormalizeHeading(heading);
    [[GPSLabEngine sharedEngine] applyConfiguration:configuration];
    [[GPSLabEngine sharedEngine] persistConfiguration];
}

- (void)setDriftEnabled:(BOOL)enabled radiusMeters:(double)radius {
    [[GPSLabEngine sharedEngine] setDriftEnabled:enabled];
    [[GPSLabEngine sharedEngine] setDriftRadiusMeters:radius];
}

- (void)applyAltitude:(double)altitude heading:(double)heading {
    GPSLabConfiguration *configuration = [[GPSLabEngine sharedEngine] configuration];
    configuration.altitude = GPSLabClampDouble(altitude, -500.0, 100000.0);
    configuration.heading = GPSLabNormalizeHeading(heading);
    [[GPSLabEngine sharedEngine] applyConfiguration:configuration];
    [[GPSLabEngine sharedEngine] persistConfiguration];
}

- (nullable id)captureSnapshot {
    return [[GPSLabEngine sharedEngine] configuration];
}

- (void)restoreSnapshot:(nullable id)snapshot {
    if (![snapshot isKindOfClass:[GPSLabConfiguration class]]) {
        return;
    }
    [[GPSLabEngine sharedEngine] applyConfiguration:(GPSLabConfiguration *)snapshot];
    [[GPSLabEngine sharedEngine] persistConfiguration];
}

- (void)stopRoute {
    [[GPSLabEngine sharedEngine] stopRoute];
}

- (void)startRouteFrom:(CLLocationCoordinate2D)start
                    to:(CLLocationCoordinate2D)end
                  mode:(GPSLabRouteMode)mode
        customSpeedKmh:(double)customSpeedKmh
            completion:(nullable void (^)(NSError * _Nullable error))completion {
    [[GPSLabEngine sharedEngine] startRouteFrom:start
                                             to:end
                                           mode:mode
                                 customSpeedKmh:customSpeedKmh
                                     completion:completion];
}

@end
