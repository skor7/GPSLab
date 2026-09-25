//
//  GPSLabConfiguration.h
//  GPSLab
//
//  In-memory configuration snapshot. This is the only set of values the runtime
//  is allowed to persist (see GPSLabStore for the persistence allow-list).
//

#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

#import "GPSLabTypes.h"

NS_ASSUME_NONNULL_BEGIN

@interface GPSLabConfiguration : NSObject <NSCopying>

/** Master switch. When NO the hooks forward to the original CoreLocation methods. */
@property (nonatomic, assign) BOOL enabled;

/** Anchor (or "last") synthetic coordinate. */
@property (nonatomic, assign) double latitude;
@property (nonatomic, assign) double longitude;
@property (nonatomic, assign) double altitude;

/** Reported course in [0, 360), or -1 for an invalid/unknown course. */
@property (nonatomic, assign) double heading;

/** Whether the bounded random walk is applied around the anchor. */
@property (nonatomic, assign) BOOL driftEnabled;

/**
 * Maximum displacement from the selected BASE coordinate, in meters. Clamped to
 * [0, 50]; 0 means the exact base coordinate. Defaults to 5.
 */
@property (nonatomic, assign) double driftRadiusMeters;

/** When YES the last synthetic coordinate is persisted so the next launch resumes there. */
@property (nonatomic, assign) BOOL keepLastCoordinate;

/** Route preferences. */
@property (nonatomic, assign) GPSLabRouteMode routeMode;
@property (nonatomic, assign) double routeCustomSpeedKmh;
@property (nonatomic, assign) GPSLabStopBehavior stopBehavior;

+ (instancetype)defaultConfiguration;

/** Builds a validated configuration from an untrusted dictionary (e.g. persisted JSON). */
+ (instancetype)configurationFromDictionary:(nullable NSDictionary *)dictionary;

/** Plist-safe representation (numbers/bools/strings only). */
- (NSDictionary *)dictionaryRepresentation;

/** Clamps all values into safe ranges. Idempotent. */
- (void)sanitize;

@property (nonatomic, readonly) CLLocationCoordinate2D coordinate;
- (void)setCoordinate:(CLLocationCoordinate2D)coordinate;

@end

NS_ASSUME_NONNULL_END
