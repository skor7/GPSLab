//
//  GPSLabConfiguration.m
//  GPSLab
//
//  In-memory configuration snapshot with validation.
//

#import "GPSLabConfiguration.h"

#import <math.h>

static NSString * const kGPSLabKeyEnabled = @"enabled";
static NSString * const kGPSLabKeyLatitude = @"latitude";
static NSString * const kGPSLabKeyLongitude = @"longitude";
static NSString * const kGPSLabKeyAltitude = @"altitude";
static NSString * const kGPSLabKeyHeading = @"heading";
static NSString * const kGPSLabKeyDriftEnabled = @"driftEnabled";
static NSString * const kGPSLabKeyDriftRadius = @"driftRadiusMeters";
static NSString * const kGPSLabKeyKeepLast = @"keepLastCoordinate";
static NSString * const kGPSLabKeyRouteMode = @"routeMode";
static NSString * const kGPSLabKeyRouteCustomSpeed = @"routeCustomSpeedKmh";
static NSString * const kGPSLabKeyStopBehavior = @"stopBehavior";

static double GPSLabConfigDouble(NSDictionary *dictionary, NSString *key, double fallback) {
    id value = dictionary[key];
    if ([value isKindOfClass:[NSNumber class]]) {
        double number = [value doubleValue];
        if (isfinite(number)) {
            return number;
        }
    }
    return fallback;
}

static BOOL GPSLabConfigBool(NSDictionary *dictionary, NSString *key, BOOL fallback) {
    id value = dictionary[key];
    if ([value isKindOfClass:[NSNumber class]]) {
        return [value boolValue];
    }
    return fallback;
}

@implementation GPSLabConfiguration

+ (instancetype)defaultConfiguration {
    GPSLabConfiguration *configuration = [[GPSLabConfiguration alloc] init];
    configuration.enabled = YES;
    configuration.latitude = 0.0;
    configuration.longitude = 0.0;
    configuration.altitude = 0.0;
    configuration.heading = -1.0;
    configuration.driftEnabled = YES;
    configuration.driftRadiusMeters = GPSLabDefaultDriftRadiusMeters();
    configuration.keepLastCoordinate = YES;
    configuration.routeMode = GPSLabRouteModeDriving;
    configuration.routeCustomSpeedKmh = 50.0;
    configuration.stopBehavior = GPSLabStopBehaviorStayAtCurrent;
    return configuration;
}

+ (instancetype)configurationFromDictionary:(nullable NSDictionary *)dictionary {
    GPSLabConfiguration *defaults = [self defaultConfiguration];
    if (![dictionary isKindOfClass:[NSDictionary class]]) {
        return defaults;
    }

    GPSLabConfiguration *configuration = [[GPSLabConfiguration alloc] init];
    configuration.enabled = GPSLabConfigBool(dictionary, kGPSLabKeyEnabled, defaults.enabled);
    configuration.driftEnabled = GPSLabConfigBool(dictionary, kGPSLabKeyDriftEnabled, defaults.driftEnabled);
    configuration.driftRadiusMeters = GPSLabConfigDouble(dictionary,
                                                          kGPSLabKeyDriftRadius,
                                                          defaults.driftRadiusMeters);
    configuration.keepLastCoordinate = GPSLabConfigBool(dictionary,
                                                        kGPSLabKeyKeepLast,
                                                        defaults.keepLastCoordinate);

    // When keep-last was disabled, the persisted coordinate/altitude/heading must
    // not be restored. The anchor fall back to safe defaults instead.
    if (!configuration.keepLastCoordinate) {
        configuration.latitude = defaults.latitude;
        configuration.longitude = defaults.longitude;
        configuration.altitude = defaults.altitude;
        configuration.heading = defaults.heading;
    } else {
        configuration.latitude = GPSLabConfigDouble(dictionary, kGPSLabKeyLatitude, defaults.latitude);
        configuration.longitude = GPSLabConfigDouble(dictionary, kGPSLabKeyLongitude, defaults.longitude);
        configuration.altitude = GPSLabConfigDouble(dictionary, kGPSLabKeyAltitude, defaults.altitude);
        configuration.heading = GPSLabConfigDouble(dictionary, kGPSLabKeyHeading, defaults.heading);
    }

    NSInteger mode = (NSInteger)GPSLabConfigDouble(dictionary,
                                                   kGPSLabKeyRouteMode,
                                                   (double)defaults.routeMode);
    if (mode < GPSLabRouteModeDriving || mode > GPSLabRouteModeCustom) {
        mode = defaults.routeMode;
    }
    configuration.routeMode = (GPSLabRouteMode)mode;
    configuration.routeCustomSpeedKmh = GPSLabConfigDouble(dictionary,
                                                           kGPSLabKeyRouteCustomSpeed,
                                                           defaults.routeCustomSpeedKmh);

    NSInteger stopBehavior = (NSInteger)GPSLabConfigDouble(dictionary,
                                                           kGPSLabKeyStopBehavior,
                                                           (double)defaults.stopBehavior);
    if (stopBehavior != GPSLabStopBehaviorStayAtCurrent &&
        stopBehavior != GPSLabStopBehaviorReturnToStart) {
        stopBehavior = defaults.stopBehavior;
    }
    configuration.stopBehavior = (GPSLabStopBehavior)stopBehavior;

    [configuration sanitize];
    return configuration;
}

- (void)sanitize {
    if (!GPSLabIsValidLatitude(self.latitude)) {
        self.latitude = 0.0;
    }
    if (!GPSLabIsValidLongitude(self.longitude)) {
        self.longitude = 0.0;
    }
    self.altitude = GPSLabClampDouble(self.altitude, -500.0, 100000.0);
    self.heading = GPSLabNormalizeHeading(self.heading);
    self.driftRadiusMeters = GPSLabClampDouble(self.driftRadiusMeters, 1.0, 500.0);
    self.routeCustomSpeedKmh = GPSLabClampDouble(self.routeCustomSpeedKmh, 1.0, 300.0);
    if (self.routeMode < GPSLabRouteModeDriving || self.routeMode > GPSLabRouteModeCustom) {
        self.routeMode = GPSLabRouteModeDriving;
    }
    if (self.stopBehavior != GPSLabStopBehaviorStayAtCurrent &&
        self.stopBehavior != GPSLabStopBehaviorReturnToStart) {
        self.stopBehavior = GPSLabStopBehaviorStayAtCurrent;
    }
}

- (NSDictionary *)dictionaryRepresentation {
    NSMutableDictionary *representation = [@{
        kGPSLabKeyEnabled: @(self.enabled),
        kGPSLabKeyDriftEnabled: @(self.driftEnabled),
        kGPSLabKeyDriftRadius: @(self.driftRadiusMeters),
        kGPSLabKeyKeepLast: @(self.keepLastCoordinate),
        kGPSLabKeyRouteMode: @((NSInteger)self.routeMode),
        kGPSLabKeyRouteCustomSpeed: @(self.routeCustomSpeedKmh),
        kGPSLabKeyStopBehavior: @((NSInteger)self.stopBehavior),
    } mutableCopy];

    // The coordinate/altitude/heading block is keep-last data and is only persisted
    // while the user has opted in; otherwise the anchor stays at safe defaults.
    if (self.keepLastCoordinate) {
        representation[kGPSLabKeyLatitude] = @(self.latitude);
        representation[kGPSLabKeyLongitude] = @(self.longitude);
        representation[kGPSLabKeyAltitude] = @(self.altitude);
        representation[kGPSLabKeyHeading] = @(self.heading);
    }

    return representation;
}

- (CLLocationCoordinate2D)coordinate {
    return CLLocationCoordinate2DMake(self.latitude, self.longitude);
}

- (void)setCoordinate:(CLLocationCoordinate2D)coordinate {
    self.latitude = coordinate.latitude;
    self.longitude = coordinate.longitude;
}

- (id)copyWithZone:(NSZone *)zone {
    GPSLabConfiguration *copy = [[GPSLabConfiguration allocWithZone:zone] init];
    copy.enabled = self.enabled;
    copy.latitude = self.latitude;
    copy.longitude = self.longitude;
    copy.altitude = self.altitude;
    copy.heading = self.heading;
    copy.driftEnabled = self.driftEnabled;
    copy.driftRadiusMeters = self.driftRadiusMeters;
    copy.keepLastCoordinate = self.keepLastCoordinate;
    copy.routeMode = self.routeMode;
    copy.routeCustomSpeedKmh = self.routeCustomSpeedKmh;
    copy.stopBehavior = self.stopBehavior;
    return copy;
}

@end
