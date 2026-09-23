//
//  GPSLabEngine.h
//  GPSLab
//
//  Clean-room synthetic location engine.
//
//  The engine is the single source of truth for the synthetic state:
//  the anchor coordinate, the bounded random walk, and the route simulation.
//  Everything is thread-safe. When `enabled` is NO the engine is inert and the
//  hook layer forwards CoreLocation calls to their original implementations.
//

#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

#import "GPSLabConfiguration.h"
#import "GPSLabRouteSimulator.h"
#import "GPSLabTypes.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const GPSLabEngineStateDidChangeNotification;
FOUNDATION_EXPORT NSNotificationName const GPSLabLocationDidUpdateNotification;

@interface GPSLabEngine : NSObject

/** Shared engine instance. */
+ (instancetype)sharedEngine;

#pragma mark - Configuration

/** A copy of the current configuration. Validating and clamping is applied. */
- (GPSLabConfiguration *)configuration;

/** Applies a configuration (sanitized). Resets the drift walk when the anchor moves. */
- (void)applyConfiguration:(GPSLabConfiguration *)configuration;

/** Loads the persisted configuration from GPSLabStore and applies it. */
- (void)loadPersistedConfiguration;

/** Persists the current configuration to GPSLabStore (allow-list only). */
- (void)persistConfiguration;

/** Sets the keep-last toggle, clearing persisted coordinate keys on true -> false. */
- (void)setKeepLastCoordinate:(BOOL)keepLast;

#pragma mark - Enable / disable

@property (nonatomic, assign, getter=isEnabled) BOOL enabled;

/**
 * Entitlement gate. The engine can only synthesize when this is YES; it defaults to
 * NO so a persisted `enabled` value can never bypass licensing. Set only by
 * GPSLabLicenseManager.
 */
@property (nonatomic, assign, getter=isEntitlementAllowsSynthesis) BOOL entitlementAllowsSynthesis;

/** Toggles the master switch, sends diagnostics and posts a state notification. */
- (void)setEnabledAndNotify:(BOOL)enabled;

#pragma mark - Anchor configuration

/**
 * Sets the anchor coordinate used by all generated locations and resets the walk
 * offset back to the anchor.
 */
- (void)setBaseLatitude:(double)latitude
              longitude:(double)longitude
               altitude:(double)altitude
                heading:(double)heading;

/** Current anchor coordinate. */
- (CLLocationCoordinate2D)baseCoordinate;

#pragma mark - Location generation

/** Current synthetic location without advancing the walk or route. */
- (CLLocation *)currentLocation;

/** Advances the random walk (or the route, when one is active) and returns the new location. */
- (CLLocation *)nextLocation;

#pragma mark - Drift

- (BOOL)isDriftEnabled;
- (void)setDriftEnabled:(BOOL)enabled;
- (double)driftRadiusMeters;
- (void)setDriftRadiusMeters:(double)radius;

#pragma mark - Testing seams

/**
 * Injects a deterministic random source into the bounded drift walk so engine
 * tests are reproducible. Passing nil restores the production arc4random source.
 */
- (void)setDriftRandomUnitProvider:(nullable double (^)(void))provider;

#pragma mark - Route simulation

- (GPSLabRouteSimulator *)routeSimulator;

- (void)startRouteFrom:(CLLocationCoordinate2D)start
                    to:(CLLocationCoordinate2D)end
                  mode:(GPSLabRouteMode)mode
        customSpeedKmh:(double)customSpeedKmh
            completion:(nullable GPSLabRouteCompletion)completion;

- (void)pauseRoute;
- (void)resumeRoute;
- (void)stopRoute;

@end

NS_ASSUME_NONNULL_END
