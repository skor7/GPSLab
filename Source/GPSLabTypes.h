//
//  GPSLabTypes.h
//  GPSLab
//
//  Shared value types and small pure helpers used across the dylib.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/** How a simulated route advances. */
typedef NS_ENUM(NSInteger, GPSLabRouteMode) {
    GPSLabRouteModeDriving = 0,
    GPSLabRouteModeWalking,
    GPSLabRouteModeCycling,
    GPSLabRouteModeCustom,
};

/** What the synthetic anchor becomes once a route stops. */
typedef NS_ENUM(NSInteger, GPSLabStopBehavior) {
    GPSLabStopBehaviorStayAtCurrent = 0,
    GPSLabStopBehaviorReturnToStart,
};

/** Lifecycle of the route simulator. */
typedef NS_ENUM(NSInteger, GPSLabRouteState) {
    GPSLabRouteStateIdle = 0,
    GPSLabRouteStatePlaying,
    GPSLabRouteStatePaused,
};

/**
 * User-selectable foreground map style (a persisted UI preference, not part of
 * the profile schema). Missing/invalid persisted values resolve to Satellite.
 */
typedef NS_ENUM(NSInteger, GPSLabMapStyle) {
    GPSLabMapStyleStandard = 0,
    GPSLabMapStyleHybrid,
    GPSLabMapStyleSatellite,
};

/** Clamps a finite double into [minimum, maximum]. NaN maps to minimum. */
FOUNDATION_EXPORT double GPSLabClampDouble(double value, double minimum, double maximum);

/** YES when latitude is a finite value inside [-90, 90]. */
FOUNDATION_EXPORT BOOL GPSLabIsValidLatitude(double latitude);

/** YES when longitude is a finite value inside [-180, 180]. */
FOUNDATION_EXPORT BOOL GPSLabIsValidLongitude(double longitude);

/** YES when latitude/longitude together are finite and in range. */
FOUNDATION_EXPORT BOOL GPSLabIsValidCoordinate(double latitude, double longitude);

/**
 * Drift radius policy, in meters. The radius is the maximum displacement from the
 * selected BASE coordinate: 0 means "exactly the base" (no displacement), and the
 * value is always clamped into [minimum, maximum]. Shared by the configuration,
 * the engine, the profile schema and the UI so the bound is defined once.
 */
FOUNDATION_EXPORT double GPSLabMinDriftRadiusMeters(void);
FOUNDATION_EXPORT double GPSLabMaxDriftRadiusMeters(void);
FOUNDATION_EXPORT double GPSLabDefaultDriftRadiusMeters(void);

/** Clamps a drift radius into the inclusive [min, max] policy range (NaN -> min). */
FOUNDATION_EXPORT double GPSLabClampDriftRadiusMeters(double radius);

/** Default approximate ground speed (km/h) for a route mode. */
FOUNDATION_EXPORT double GPSLabSpeedKmhForRouteMode(GPSLabRouteMode mode, double customSpeedKmh);

/** Stable English name for a route mode. */
FOUNDATION_EXPORT NSString *GPSLabRouteModeName(GPSLabRouteMode mode);

/** Stable English name for a stop behavior. */
FOUNDATION_EXPORT NSString *GPSLabStopBehaviorName(GPSLabStopBehavior behavior);

NS_ASSUME_NONNULL_END
