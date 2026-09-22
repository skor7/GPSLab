//
//  GPSLabProfile.m
//  GPSLab
//

#import "GPSLabProfile.h"

#import <CoreFoundation/CoreFoundation.h>
#import <math.h>

#import "GPSLabGeodesy.h"

#pragma mark - Key allow-list

static NSString * const kGPSLabProfileKeyIdentifier = @"id";
static NSString * const kGPSLabProfileKeyName = @"name";
static NSString * const kGPSLabProfileKeyLocationMode = @"locationMode";
static NSString * const kGPSLabProfileKeyLatitude = @"latitude";
static NSString * const kGPSLabProfileKeyLongitude = @"longitude";
static NSString * const kGPSLabProfileKeyAltitude = @"altitude";
static NSString * const kGPSLabProfileKeyHeading = @"heading";
static NSString * const kGPSLabProfileKeyDriftEnabled = @"driftEnabled";
static NSString * const kGPSLabProfileKeyDriftRadius = @"driftRadiusMeters";
static NSString * const kGPSLabProfileKeyRoute = @"route";
static NSString * const kGPSLabProfileKeyWiFi = @"wifi";
static NSString * const kGPSLabProfileKeyBluetooth = @"bluetooth";
static NSString * const kGPSLabProfileKeySchedule = @"schedule";
static NSString * const kGPSLabProfileKeyEnabled = @"enabled";

static NSString * const kGPSLabRouteKeyStartLatitude = @"startLatitude";
static NSString * const kGPSLabRouteKeyStartLongitude = @"startLongitude";
static NSString * const kGPSLabRouteKeyEndLatitude = @"endLatitude";
static NSString * const kGPSLabRouteKeyEndLongitude = @"endLongitude";
static NSString * const kGPSLabRouteKeyAltitude = @"altitude";
static NSString * const kGPSLabRouteKeyHeading = @"heading";
static NSString * const kGPSLabRouteKeyMode = @"mode";
static NSString * const kGPSLabRouteKeyCustomSpeed = @"customSpeedKmh";

static NSString * const kGPSLabWiFiKeyProfileName = @"profileName";
static NSString * const kGPSLabWiFiKeySSID = @"ssid";
static NSString * const kGPSLabWiFiKeySignal = @"signal";

static NSString * const kGPSLabBLEKeyProfileName = @"profileName";
static NSString * const kGPSLabBLEKeyDeviceName = @"deviceName";
static NSString * const kGPSLabBLEKeyRSSI = @"rssi";
static NSString * const kGPSLabBLEKeyPattern = @"pattern";

static NSString * const kGPSLabScheduleKeyMode = @"mode";
static NSString * const kGPSLabScheduleKeyStart = @"startEpoch";
static NSString * const kGPSLabScheduleKeyEnd = @"endEpoch";
static NSString * const kGPSLabScheduleKeyTimeZone = @"timeZoneOffsetSeconds";

#pragma mark - Typed readers (reject NSNull / booleans / non-finite)

static BOOL GPSLabReadFiniteNumber(NSDictionary *dictionary, NSString *key, double *outValue) {
    id value = dictionary[key];
    if (![value isKindOfClass:[NSNumber class]]) {
        return NO;
    }
    if (CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) {
        return NO;
    }
    double number = [(NSNumber *)value doubleValue];
    if (!isfinite(number)) {
        return NO;
    }
    *outValue = number;
    return YES;
}

/** Largest magnitude a double can hold without losing integer precision (2^53). */
static const double kGPSLabIntegerSafeBound = 9007199254740992.0;

static BOOL GPSLabIntInRange(long long value, long long minimum, long long maximum) {
    return (value >= minimum && value <= maximum) ? YES : NO;
}

static BOOL GPSLabReadInteger(NSDictionary *dictionary, NSString *key, long long *outValue) {
    double number = 0.0;
    if (!GPSLabReadFiniteNumber(dictionary, key, &number)) {
        return NO;
    }
    if (number != floor(number)) {
        return NO; // fractional values are not integers
    }
    // Reject magnitudes beyond the exact-integer range BEFORE casting: casting a
    // huge double to long long is undefined behaviour.
    if (number < -kGPSLabIntegerSafeBound || number > kGPSLabIntegerSafeBound) {
        return NO;
    }
    *outValue = (long long)number;
    return YES;
}

static BOOL GPSLabReadBool(NSDictionary *dictionary, NSString *key, BOOL *outValue) {
    id value = dictionary[key];
    if (![value isKindOfClass:[NSNumber class]]) {
        return NO;
    }
    if (CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) {
        *outValue = [(NSNumber *)value boolValue];
        return YES;
    }
    // Strict policy: a JSON boolean, or exactly 0/1. Reject 2, -1, fractions.
    double number = [(NSNumber *)value doubleValue];
    if (!isfinite(number) || number != floor(number) || (number != 0.0 && number != 1.0)) {
        return NO;
    }
    *outValue = (number != 0.0);
    return YES;
}

static BOOL GPSLabStringWithinBytes(NSString *string, size_t maxBytes) {
    NSUInteger bytes = [string lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    return bytes <= maxBytes ? YES : NO;
}

static NSString * _Nullable GPSLabReadString(NSDictionary *dictionary, NSString *key) {
    id value = dictionary[key];
    if (![value isKindOfClass:[NSString class]]) {
        return nil;
    }
    return (NSString *)value;
}

static BOOL GPSLabDriftRadiusValid(double radius) {
    return (isfinite(radius) && radius >= 1.0 && radius <= 500.0) ? YES : NO;
}

#pragma mark - Route

@implementation GPSLabProfileRoute

+ (nullable instancetype)routeFromDictionary:(NSDictionary *)dictionary {
    if (![dictionary isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    double startLatitude = 0.0, startLongitude = 0.0, endLatitude = 0.0, endLongitude = 0.0;
    double altitude = 0.0, heading = -1.0, customSpeed = 50.0;
    long long mode = 0;

    if (!GPSLabReadFiniteNumber(dictionary, kGPSLabRouteKeyStartLatitude, &startLatitude) ||
        !GPSLabReadFiniteNumber(dictionary, kGPSLabRouteKeyStartLongitude, &startLongitude) ||
        !GPSLabReadFiniteNumber(dictionary, kGPSLabRouteKeyEndLatitude, &endLatitude) ||
        !GPSLabReadFiniteNumber(dictionary, kGPSLabRouteKeyEndLongitude, &endLongitude) ||
        !GPSLabReadFiniteNumber(dictionary, kGPSLabRouteKeyAltitude, &altitude) ||
        !GPSLabReadFiniteNumber(dictionary, kGPSLabRouteKeyHeading, &heading) ||
        !GPSLabReadFiniteNumber(dictionary, kGPSLabRouteKeyCustomSpeed, &customSpeed) ||
        !GPSLabReadInteger(dictionary, kGPSLabRouteKeyMode, &mode)) {
        return nil;
    }
    if (!GPSLabProfileCoordinateValid(startLatitude, startLongitude) ||
        !GPSLabProfileCoordinateValid(endLatitude, endLongitude) ||
        !GPSLabProfileAltitudeValid(altitude) ||
        !GPSLabProfileHeadingValid(heading) ||
        !GPSLabIntInRange(mode, 0, 3) ||
        !GPSLabProfileRouteModeValid((int)mode) ||
        !GPSLabProfileCustomSpeedValid(customSpeed)) {
        return nil;
    }

    return [[GPSLabProfileRoute alloc] initWithStartLatitude:startLatitude
                                              startLongitude:startLongitude
                                                endLatitude:endLatitude
                                              endLongitude:endLongitude
                                                    altitude:altitude
                                                     heading:heading
                                                        mode:(GPSLabRouteMode)mode
                                              customSpeedKmh:customSpeed];
}

- (instancetype)initWithStartLatitude:(double)startLatitude
                       startLongitude:(double)startLongitude
                         endLatitude:(double)endLatitude
                       endLongitude:(double)endLongitude
                             altitude:(double)altitude
                              heading:(double)heading
                                 mode:(GPSLabRouteMode)mode
                       customSpeedKmh:(double)customSpeedKmh {
    self = [super init];
    if (self) {
        _startLatitude = startLatitude;
        _startLongitude = startLongitude;
        _endLatitude = endLatitude;
        _endLongitude = endLongitude;
        _altitude = altitude;
        _heading = heading;
        _mode = mode;
        _customSpeedKmh = customSpeedKmh;
    }
    return self;
}

- (NSDictionary *)dictionaryRepresentation {
    return @{
        kGPSLabRouteKeyStartLatitude: @(self.startLatitude),
        kGPSLabRouteKeyStartLongitude: @(self.startLongitude),
        kGPSLabRouteKeyEndLatitude: @(self.endLatitude),
        kGPSLabRouteKeyEndLongitude: @(self.endLongitude),
        kGPSLabRouteKeyAltitude: @(self.altitude),
        kGPSLabRouteKeyHeading: @(self.heading),
        kGPSLabRouteKeyMode: @((NSInteger)self.mode),
        kGPSLabRouteKeyCustomSpeed: @(self.customSpeedKmh),
    };
}

- (id)copyWithZone:(NSZone *)zone {
    (void)zone;
    return self;
}

@end

#pragma mark - Wi-Fi

@implementation GPSLabProfileWiFiConfig

+ (nullable instancetype)configFromDictionary:(NSDictionary *)dictionary {
    if (![dictionary isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    NSString *profileName = GPSLabReadString(dictionary, kGPSLabWiFiKeyProfileName);
    NSString *ssid = GPSLabReadString(dictionary, kGPSLabWiFiKeySSID);
    long long signal = 0;
    if (profileName == nil || ssid == nil ||
        !GPSLabReadInteger(dictionary, kGPSLabWiFiKeySignal, &signal)) {
        return nil;
    }
    if (!GPSLabStringWithinBytes(profileName, GPSLAB_PROFILE_MAX_TEXT_BYTES) ||
        !GPSLabStringWithinBytes(ssid, GPSLAB_PROFILE_MAX_TEXT_BYTES) ||
        !GPSLabIntInRange(signal, GPSLAB_PROFILE_MIN_SIGNAL, GPSLAB_PROFILE_MAX_SIGNAL) ||
        !GPSLabProfileSignalValid((int)signal)) {
        return nil;
    }
    return [[GPSLabProfileWiFiConfig alloc] initWithProfileName:profileName
                                                           ssid:ssid
                                                         signal:(NSInteger)signal];
}

- (instancetype)initWithProfileName:(NSString *)profileName
                               ssid:(NSString *)ssid
                             signal:(NSInteger)signal {
    self = [super init];
    if (self) {
        _profileName = [profileName copy];
        _ssid = [ssid copy];
        _signal = signal;
    }
    return self;
}

- (NSDictionary *)dictionaryRepresentation {
    return @{
        kGPSLabWiFiKeyProfileName: self.profileName,
        kGPSLabWiFiKeySSID: self.ssid,
        kGPSLabWiFiKeySignal: @(self.signal),
    };
}

- (id)copyWithZone:(NSZone *)zone {
    (void)zone;
    return self;
}

@end

#pragma mark - Bluetooth

@implementation GPSLabProfileBluetoothConfig

+ (nullable instancetype)configFromDictionary:(NSDictionary *)dictionary {
    if (![dictionary isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    NSString *profileName = GPSLabReadString(dictionary, kGPSLabBLEKeyProfileName);
    NSString *deviceName = GPSLabReadString(dictionary, kGPSLabBLEKeyDeviceName);
    NSString *pattern = GPSLabReadString(dictionary, kGPSLabBLEKeyPattern);
    long long rssi = 0;
    if (profileName == nil || deviceName == nil || pattern == nil ||
        !GPSLabReadInteger(dictionary, kGPSLabBLEKeyRSSI, &rssi)) {
        return nil;
    }
    if (!GPSLabStringWithinBytes(profileName, GPSLAB_PROFILE_MAX_TEXT_BYTES) ||
        !GPSLabStringWithinBytes(deviceName, GPSLAB_PROFILE_MAX_TEXT_BYTES) ||
        !GPSLabStringWithinBytes(pattern, GPSLAB_PROFILE_MAX_TEXT_BYTES) ||
        !GPSLabIntInRange(rssi, GPSLAB_PROFILE_MIN_RSSI, GPSLAB_PROFILE_MAX_RSSI) ||
        !GPSLabProfileRSSIValid((int)rssi)) {
        return nil;
    }
    return [[GPSLabProfileBluetoothConfig alloc] initWithProfileName:profileName
                                                         deviceName:deviceName
                                                               rssi:(NSInteger)rssi
                                                            pattern:pattern];
}

- (instancetype)initWithProfileName:(NSString *)profileName
                         deviceName:(NSString *)deviceName
                               rssi:(NSInteger)rssi
                            pattern:(NSString *)pattern {
    self = [super init];
    if (self) {
        _profileName = [profileName copy];
        _deviceName = [deviceName copy];
        _rssi = rssi;
        _pattern = [pattern copy];
    }
    return self;
}

- (NSDictionary *)dictionaryRepresentation {
    return @{
        kGPSLabBLEKeyProfileName: self.profileName,
        kGPSLabBLEKeyDeviceName: self.deviceName,
        kGPSLabBLEKeyRSSI: @(self.rssi),
        kGPSLabBLEKeyPattern: self.pattern,
    };
}

- (id)copyWithZone:(NSZone *)zone {
    (void)zone;
    return self;
}

@end

#pragma mark - Schedule

@implementation GPSLabProfileSchedule

+ (nullable instancetype)scheduleFromDictionary:(NSDictionary *)dictionary {
    if (![dictionary isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    long long mode = 0, start = 0, end = 0, offset = 0;
    if (!GPSLabReadInteger(dictionary, kGPSLabScheduleKeyMode, &mode) ||
        !GPSLabReadInteger(dictionary, kGPSLabScheduleKeyStart, &start) ||
        !GPSLabReadInteger(dictionary, kGPSLabScheduleKeyEnd, &end) ||
        !GPSLabReadInteger(dictionary, kGPSLabScheduleKeyTimeZone, &offset)) {
        return nil;
    }
    if (!GPSLabProfileScheduleModeValid((int)mode) || !GPSLabIntInRange(mode, 0, 2)) {
        return nil;
    }
    if ((GPSLabProfileScheduleMode)mode == GPSLabProfileScheduleNone) {
        return nil; // "None" is represented by the absence of the schedule object.
    }
    if (!GPSLabProfileScheduleValid(start, end)) {
        return nil;
    }
    if (offset < -(24 * 60 * 60) || offset > (24 * 60 * 60)) {
        return nil;
    }
    return [[GPSLabProfileSchedule alloc] initWithMode:(GPSLabProfileScheduleMode)mode
                                            startEpoch:start
                                              endEpoch:end
                                timeZoneOffsetSeconds:(NSInteger)offset];
}

- (instancetype)initWithMode:(GPSLabProfileScheduleMode)mode
                  startEpoch:(long long)startEpoch
                    endEpoch:(long long)endEpoch
      timeZoneOffsetSeconds:(NSInteger)timeZoneOffsetSeconds {
    self = [super init];
    if (self) {
        _mode = mode;
        _startEpoch = startEpoch;
        _endEpoch = endEpoch;
        _timeZoneOffsetSeconds = timeZoneOffsetSeconds;
    }
    return self;
}

- (NSDictionary *)dictionaryRepresentation {
    return @{
        kGPSLabScheduleKeyMode: @((NSInteger)self.mode),
        kGPSLabScheduleKeyStart: @(self.startEpoch),
        kGPSLabScheduleKeyEnd: @(self.endEpoch),
        kGPSLabScheduleKeyTimeZone: @(self.timeZoneOffsetSeconds),
    };
}

- (id)copyWithZone:(NSZone *)zone {
    (void)zone;
    return self;
}

@end

#pragma mark - Profile

@interface GPSLabProfile ()
/** Internal read-write view of the optional, backward-compatible switch state. */
@property (nonatomic, readwrite) BOOL hasEnabledPreference;
@property (nonatomic, readwrite) BOOL enabled;
@end

@implementation GPSLabProfile

+ (nullable instancetype)profileFromDictionary:(NSDictionary *)dictionary {
    if (![dictionary isKindOfClass:[NSDictionary class]]) {
        return nil;
    }

    NSString *identifier = GPSLabReadString(dictionary, kGPSLabProfileKeyIdentifier);
    NSString *name = GPSLabReadString(dictionary, kGPSLabProfileKeyName);
    if (identifier == nil || name == nil) {
        return nil;
    }
    if (!GPSLabStringWithinBytes(identifier, GPSLAB_PROFILE_MAX_NAME_BYTES) ||
        ![name isKindOfClass:[NSString class]]) {
        return nil;
    }
    if (!GPSLabProfileIdentifierValid(identifier.UTF8String,
                                      [identifier lengthOfBytesUsingEncoding:NSUTF8StringEncoding])) {
        return nil;
    }
    if (!GPSLabProfileNameValid(name.UTF8String,
                                [name lengthOfBytesUsingEncoding:NSUTF8StringEncoding])) {
        return nil;
    }

    long long locationMode = 0;
    if (!GPSLabReadInteger(dictionary, kGPSLabProfileKeyLocationMode, &locationMode) ||
        !GPSLabIntInRange(locationMode, 0, 1) ||
        !GPSLabProfileLocationModeValid((int)locationMode)) {
        return nil;
    }

    double latitude = 0.0, longitude = 0.0, altitude = 0.0, heading = -1.0, driftRadius = 30.0;
    BOOL driftEnabled = NO;
    if (!GPSLabReadFiniteNumber(dictionary, kGPSLabProfileKeyLatitude, &latitude) ||
        !GPSLabReadFiniteNumber(dictionary, kGPSLabProfileKeyLongitude, &longitude) ||
        !GPSLabReadFiniteNumber(dictionary, kGPSLabProfileKeyAltitude, &altitude) ||
        !GPSLabReadFiniteNumber(dictionary, kGPSLabProfileKeyHeading, &heading) ||
        !GPSLabReadFiniteNumber(dictionary, kGPSLabProfileKeyDriftRadius, &driftRadius) ||
        !GPSLabReadBool(dictionary, kGPSLabProfileKeyDriftEnabled, &driftEnabled)) {
        return nil;
    }
    if (!GPSLabProfileCoordinateValid(latitude, longitude) ||
        !GPSLabProfileAltitudeValid(altitude) ||
        !GPSLabProfileHeadingValid(heading) ||
        !GPSLabDriftRadiusValid(driftRadius)) {
        return nil;
    }

    // Route block: required for route profiles, ignored for static ones.
    id routeValue = dictionary[kGPSLabProfileKeyRoute];
    GPSLabProfileRoute *route = nil;
    if ([routeValue isKindOfClass:[NSDictionary class]]) {
        route = [GPSLabProfileRoute routeFromDictionary:(NSDictionary *)routeValue];
        if (route == nil) {
            return nil; // strict: a present-but-invalid block rejects the profile.
        }
    }
    if ((GPSLabProfileLocationMode)locationMode == GPSLabProfileLocationRoute && route == nil) {
        return nil;
    }
    if ((GPSLabProfileLocationMode)locationMode == GPSLabProfileLocationStatic) {
        route = nil;
    }

    id wifiValue = dictionary[kGPSLabProfileKeyWiFi];
    GPSLabProfileWiFiConfig *wifi = nil;
    if (wifiValue != nil) {
        if (![wifiValue isKindOfClass:[NSDictionary class]]) {
            return nil;
        }
        wifi = [GPSLabProfileWiFiConfig configFromDictionary:(NSDictionary *)wifiValue];
        if (wifi == nil) {
            return nil;
        }
    }

    id bleValue = dictionary[kGPSLabProfileKeyBluetooth];
    GPSLabProfileBluetoothConfig *bluetooth = nil;
    if (bleValue != nil) {
        if (![bleValue isKindOfClass:[NSDictionary class]]) {
            return nil;
        }
        bluetooth = [GPSLabProfileBluetoothConfig configFromDictionary:(NSDictionary *)bleValue];
        if (bluetooth == nil) {
            return nil;
        }
    }

    id scheduleValue = dictionary[kGPSLabProfileKeySchedule];
    GPSLabProfileSchedule *schedule = nil;
    if (scheduleValue != nil) {
        if (![scheduleValue isKindOfClass:[NSDictionary class]]) {
            return nil;
        }
        schedule = [GPSLabProfileSchedule scheduleFromDictionary:(NSDictionary *)scheduleValue];
        if (schedule == nil) {
            return nil;
        }
    }

    // Optional, backward-compatible engine-switch preference. Absent keeps the
    // legacy semantics (no preference recorded); present-but-not-a-bool rejects.
    BOOL hasEnabledPreference = NO;
    BOOL enabled = YES;
    if (dictionary[kGPSLabProfileKeyEnabled] != nil) {
        if (!GPSLabReadBool(dictionary, kGPSLabProfileKeyEnabled, &enabled)) {
            return nil;
        }
        hasEnabledPreference = YES;
    }

    GPSLabProfile *profile =
        [[GPSLabProfile alloc] initWithIdentifier:identifier
                                             name:name
                                     locationMode:(GPSLabProfileLocationMode)locationMode
                                        latitude:latitude
                                       longitude:longitude
                                        altitude:altitude
                                         heading:heading
                                    driftEnabled:driftEnabled
                               driftRadiusMeters:driftRadius
                                           route:route
                                            wifi:wifi
                                       bluetooth:bluetooth
                                        schedule:schedule];
    profile.hasEnabledPreference = hasEnabledPreference;
    profile.enabled = enabled;
    return profile;
}

- (instancetype)initWithIdentifier:(NSString *)identifier
                              name:(NSString *)name
                      locationMode:(GPSLabProfileLocationMode)locationMode
                         latitude:(double)latitude
                        longitude:(double)longitude
                         altitude:(double)altitude
                          heading:(double)heading
                     driftEnabled:(BOOL)driftEnabled
                driftRadiusMeters:(double)driftRadiusMeters
                            route:(nullable GPSLabProfileRoute *)route
                             wifi:(nullable GPSLabProfileWiFiConfig *)wifi
                        bluetooth:(nullable GPSLabProfileBluetoothConfig *)bluetooth
                         schedule:(nullable GPSLabProfileSchedule *)schedule {
    self = [super init];
    if (self) {
        _identifier = [identifier copy];
        _name = [name copy];
        _locationMode = locationMode;
        _latitude = latitude;
        _longitude = longitude;
        _altitude = altitude;
        _heading = heading;
        _driftEnabled = driftEnabled;
        _driftRadiusMeters = driftRadiusMeters;
        _route = route;
        _wifi = wifi;
        _bluetooth = bluetooth;
        _schedule = schedule;
        _hasEnabledPreference = NO;
        _enabled = YES;
    }
    return self;
}

- (NSDictionary *)dictionaryRepresentation {
    NSMutableDictionary *representation = [@{
        kGPSLabProfileKeyIdentifier: self.identifier,
        kGPSLabProfileKeyName: self.name,
        kGPSLabProfileKeyLocationMode: @((NSInteger)self.locationMode),
        kGPSLabProfileKeyLatitude: @(self.latitude),
        kGPSLabProfileKeyLongitude: @(self.longitude),
        kGPSLabProfileKeyAltitude: @(self.altitude),
        kGPSLabProfileKeyHeading: @(self.heading),
        kGPSLabProfileKeyDriftEnabled: @(self.driftEnabled),
        kGPSLabProfileKeyDriftRadius: @(self.driftRadiusMeters),
    } mutableCopy];

    if (self.route != nil) {
        representation[kGPSLabProfileKeyRoute] = [self.route dictionaryRepresentation];
    }
    if (self.wifi != nil) {
        representation[kGPSLabProfileKeyWiFi] = [self.wifi dictionaryRepresentation];
    }
    if (self.bluetooth != nil) {
        representation[kGPSLabProfileKeyBluetooth] = [self.bluetooth dictionaryRepresentation];
    }
    if (self.schedule != nil) {
        representation[kGPSLabProfileKeySchedule] = [self.schedule dictionaryRepresentation];
    }
    // Only persisted when an explicit preference exists, so legacy profiles keep
    // byte-identical output and old readers are unaffected.
    if (self.hasEnabledPreference) {
        representation[kGPSLabProfileKeyEnabled] = @(self.enabled);
    }
    return representation;
}

- (instancetype)profileWithName:(NSString *)name {
    GPSLabProfile *copy = [[GPSLabProfile alloc] initWithIdentifier:self.identifier
                                                               name:name
                                                       locationMode:self.locationMode
                                                          latitude:self.latitude
                                                         longitude:self.longitude
                                                          altitude:self.altitude
                                                           heading:self.heading
                                                      driftEnabled:self.driftEnabled
                                                 driftRadiusMeters:self.driftRadiusMeters
                                                             route:self.route
                                                              wifi:self.wifi
                                                         bluetooth:self.bluetooth
                                                          schedule:self.schedule];
    copy.hasEnabledPreference = self.hasEnabledPreference;
    copy.enabled = self.enabled;
    return copy;
}

- (instancetype)profileWithEnabledPreference:(BOOL)enabled {
    GPSLabProfile *copy = [[GPSLabProfile alloc] initWithIdentifier:self.identifier
                                                               name:self.name
                                                       locationMode:self.locationMode
                                                          latitude:self.latitude
                                                         longitude:self.longitude
                                                          altitude:self.altitude
                                                           heading:self.heading
                                                      driftEnabled:self.driftEnabled
                                                 driftRadiusMeters:self.driftRadiusMeters
                                                             route:self.route
                                                              wifi:self.wifi
                                                         bluetooth:self.bluetooth
                                                          schedule:self.schedule];
    copy.hasEnabledPreference = YES;
    copy.enabled = enabled;
    return copy;
}

- (instancetype)profileWithWiFi:(nullable GPSLabProfileWiFiConfig *)wifi
                      bluetooth:(nullable GPSLabProfileBluetoothConfig *)bluetooth
                       schedule:(nullable GPSLabProfileSchedule *)schedule {
    GPSLabProfile *copy = [[GPSLabProfile alloc] initWithIdentifier:self.identifier
                                                               name:self.name
                                                       locationMode:self.locationMode
                                                          latitude:self.latitude
                                                         longitude:self.longitude
                                                          altitude:self.altitude
                                                           heading:self.heading
                                                      driftEnabled:self.driftEnabled
                                                 driftRadiusMeters:self.driftRadiusMeters
                                                             route:self.route
                                                              wifi:wifi
                                                         bluetooth:bluetooth
                                                          schedule:schedule];
    copy.hasEnabledPreference = self.hasEnabledPreference;
    copy.enabled = self.enabled;
    return copy;
}

- (BOOL)isValidForApplication {
    if (!GPSLabProfileIdentifierValid(self.identifier.UTF8String,
                                      [self.identifier lengthOfBytesUsingEncoding:NSUTF8StringEncoding])) {
        return NO;
    }
    if (!GPSLabProfileNameValid(self.name.UTF8String,
                                [self.name lengthOfBytesUsingEncoding:NSUTF8StringEncoding])) {
        return NO;
    }
    if (!GPSLabProfileLocationModeValid((int)self.locationMode)) {
        return NO;
    }
    if (!GPSLabProfileCoordinateValid(self.latitude, self.longitude) ||
        !GPSLabProfileAltitudeValid(self.altitude) ||
        !GPSLabProfileHeadingValid(self.heading) ||
        !GPSLabDriftRadiusValid(self.driftRadiusMeters)) {
        return NO;
    }

    if (self.locationMode == GPSLabProfileLocationRoute) {
        GPSLabProfileRoute *route = self.route;
        if (route == nil) {
            return NO; // route mode with a NULL route block
        }
        if (!GPSLabProfileCoordinateValid(route.startLatitude, route.startLongitude) ||
            !GPSLabProfileCoordinateValid(route.endLatitude, route.endLongitude) ||
            !GPSLabProfileAltitudeValid(route.altitude) ||
            !GPSLabProfileHeadingValid(route.heading) ||
            !GPSLabProfileRouteModeValid((int)route.mode) ||
            !GPSLabProfileCustomSpeedValid(route.customSpeedKmh)) {
            return NO;
        }
    } else if (self.route != nil) {
        return NO; // a static profile must not carry a route block
    }

    if (self.wifi != nil) {
        if (!GPSLabStringWithinBytes(self.wifi.profileName, GPSLAB_PROFILE_MAX_TEXT_BYTES) ||
            !GPSLabStringWithinBytes(self.wifi.ssid, GPSLAB_PROFILE_MAX_TEXT_BYTES) ||
            !GPSLabProfileSignalValid((int)self.wifi.signal)) {
            return NO;
        }
    }
    if (self.bluetooth != nil) {
        if (!GPSLabStringWithinBytes(self.bluetooth.profileName, GPSLAB_PROFILE_MAX_TEXT_BYTES) ||
            !GPSLabStringWithinBytes(self.bluetooth.deviceName, GPSLAB_PROFILE_MAX_TEXT_BYTES) ||
            !GPSLabStringWithinBytes(self.bluetooth.pattern, GPSLAB_PROFILE_MAX_TEXT_BYTES) ||
            !GPSLabProfileRSSIValid((int)self.bluetooth.rssi)) {
            return NO;
        }
    }
    if (self.schedule != nil) {
        if (!GPSLabProfileScheduleModeValid((int)self.schedule.mode) ||
            self.schedule.mode == GPSLabProfileScheduleNone ||
            !GPSLabProfileScheduleValid(self.schedule.startEpoch, self.schedule.endEpoch)) {
            return NO;
        }
    }
    return YES;
}

- (id)copyWithZone:(NSZone *)zone {
    (void)zone;
    return self;
}

@end
