//
//  GPSLabProfile.h
//  GPSLab
//
//  Immutable, typed profile models plus a corruption-safe dictionary parser.
//
//  A profile is a user-authored GPSLab scene (a static anchor or a route, plus
//  optional drift and optional Wi-Fi / Bluetooth *test* settings and an optional
//  schedule). Nothing here reads host data, device identifiers or the network.
//
//  Every numeric/enum/coordinate/route value is validated through
//  GPSLabProfileCore; an invalid or malformed entry parses to nil and is skipped
//  by the store rather than crashing or half-applying.
//

#import <Foundation/Foundation.h>

#import "GPSLabProfileCore.h"
#import "GPSLabTypes.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Route

@interface GPSLabProfileRoute : NSObject <NSCopying>

@property (nonatomic, readonly) double startLatitude;
@property (nonatomic, readonly) double startLongitude;
@property (nonatomic, readonly) double endLatitude;
@property (nonatomic, readonly) double endLongitude;
@property (nonatomic, readonly) double altitude;
@property (nonatomic, readonly) double heading;
@property (nonatomic, readonly) GPSLabRouteMode mode;
@property (nonatomic, readonly) double customSpeedKmh;

+ (nullable instancetype)routeFromDictionary:(NSDictionary *)dictionary;

- (instancetype)initWithStartLatitude:(double)startLatitude
                       startLongitude:(double)startLongitude
                         endLatitude:(double)endLatitude
                       endLongitude:(double)endLongitude
                             altitude:(double)altitude
                              heading:(double)heading
                                 mode:(GPSLabRouteMode)mode
                       customSpeedKmh:(double)customSpeedKmh NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (NSDictionary *)dictionaryRepresentation;

@end

#pragma mark - Wi-Fi test config

@interface GPSLabProfileWiFiConfig : NSObject <NSCopying>

@property (nonatomic, readonly, copy) NSString *profileName;
@property (nonatomic, readonly, copy) NSString *ssid;
@property (nonatomic, readonly) NSInteger signal;

+ (nullable instancetype)configFromDictionary:(NSDictionary *)dictionary;

- (instancetype)initWithProfileName:(NSString *)profileName
                               ssid:(NSString *)ssid
                             signal:(NSInteger)signal NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (NSDictionary *)dictionaryRepresentation;

@end

#pragma mark - Bluetooth test config

@interface GPSLabProfileBluetoothConfig : NSObject <NSCopying>

@property (nonatomic, readonly, copy) NSString *profileName;
@property (nonatomic, readonly, copy) NSString *deviceName;
@property (nonatomic, readonly) NSInteger rssi;
@property (nonatomic, readonly, copy) NSString *pattern;

+ (nullable instancetype)configFromDictionary:(NSDictionary *)dictionary;

- (instancetype)initWithProfileName:(NSString *)profileName
                         deviceName:(NSString *)deviceName
                               rssi:(NSInteger)rssi
                            pattern:(NSString *)pattern NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (NSDictionary *)dictionaryRepresentation;

@end

#pragma mark - Schedule

@interface GPSLabProfileSchedule : NSObject <NSCopying>

@property (nonatomic, readonly) GPSLabProfileScheduleMode mode;
/** UTC epoch seconds. */
@property (nonatomic, readonly) long long startEpoch;
@property (nonatomic, readonly) long long endEpoch;
/** Display-only offset (seconds from UTC) captured when the schedule was saved. */
@property (nonatomic, readonly) NSInteger timeZoneOffsetSeconds;

+ (nullable instancetype)scheduleFromDictionary:(NSDictionary *)dictionary;

- (instancetype)initWithMode:(GPSLabProfileScheduleMode)mode
                  startEpoch:(long long)startEpoch
                    endEpoch:(long long)endEpoch
      timeZoneOffsetSeconds:(NSInteger)timeZoneOffsetSeconds NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (NSDictionary *)dictionaryRepresentation;

@end

#pragma mark - Profile

@interface GPSLabProfile : NSObject <NSCopying>

@property (nonatomic, readonly, copy) NSString *identifier;
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly) GPSLabProfileLocationMode locationMode;
@property (nonatomic, readonly) double latitude;
@property (nonatomic, readonly) double longitude;
@property (nonatomic, readonly) double altitude;
@property (nonatomic, readonly) double heading;
@property (nonatomic, readonly) BOOL driftEnabled;
@property (nonatomic, readonly) double driftRadiusMeters;

@property (nonatomic, readonly, nullable) GPSLabProfileRoute *route;
@property (nonatomic, readonly, nullable) GPSLabProfileWiFiConfig *wifi;
@property (nonatomic, readonly, nullable) GPSLabProfileBluetoothConfig *bluetooth;
@property (nonatomic, readonly, nullable) GPSLabProfileSchedule *schedule;

/**
 * Parses one persisted entry. Returns nil for any malformed/invalid value.
 * Canonicalization: a static entry's `route` payload is ignored and dropped
 * (there is no active route); a route entry with a missing/invalid route block
 * is rejected.
 */
+ (nullable instancetype)profileFromDictionary:(NSDictionary *)dictionary;

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
                         schedule:(nullable GPSLabProfileSchedule *)schedule NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/** Full plist-safe representation including the schema version. */
- (NSDictionary *)dictionaryRepresentation;

/**
 * Strict validation of every field (and every nested attachment) before the
 * coordinator performs ANY engine or module side effect. A typed initializer can
 * construct a malformed profile, so this is the authoritative preflight.
 */
- (BOOL)isValidForApplication;

/** A copy with a replaced name (identifier and everything else preserved). */
- (instancetype)profileWithName:(NSString *)name;

/**
 * A copy with the experimental attachments replaced/cleared. Passing nil clears
 * the attachment so a toggled-off module never leaves a stale active config.
 */
- (instancetype)profileWithWiFi:(nullable GPSLabProfileWiFiConfig *)wifi
                      bluetooth:(nullable GPSLabProfileBluetoothConfig *)bluetooth
                       schedule:(nullable GPSLabProfileSchedule *)schedule;

@end

NS_ASSUME_NONNULL_END
