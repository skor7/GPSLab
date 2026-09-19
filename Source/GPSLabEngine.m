//
//  GPSLabEngine.m
//  GPSLab
//
//  Clean-room synthetic location engine. Thread-safe; all mutable state is guarded
//  by a single unfair lock.
//

#import "GPSLabEngine.h"

#import <math.h>
#import <os/lock.h>

#import "Diagnostics.h"
#import "GPSLabDriftModel.h"
#import "GPSLabGeodesy.h"
#import "GPSLabLocationFactory.h"
#import "GPSLabStore.h"
#import "CoreLocationHooks.h"
#import "LocationStream.h"

NSNotificationName const GPSLabEngineStateDidChangeNotification = @"com.gpslab.engine.state";
NSNotificationName const GPSLabLocationDidUpdateNotification = @"com.gpslab.engine.location";

// Default drift step length. The walk advances at most this far per synthetic fix.
static const double kGPSLabMaxStepMeters = 1.5;

@implementation GPSLabEngine {
    os_unfair_lock _lock;
    GPSLabConfiguration *_configuration;
    GPSLabDriftModel *_drift;
    GPSLabRouteSimulator *_routeSimulator;
    BOOL _lastKnownKeepLast;
    BOOL _entitlementAllowsSynthesis;
}

+ (instancetype)sharedEngine {
    static GPSLabEngine *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[GPSLabEngine alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _configuration = [GPSLabConfiguration defaultConfiguration];
        _drift = [[GPSLabDriftModel alloc] init];
        _routeSimulator = [[GPSLabRouteSimulator alloc] init];
    }
    return self;
}

#pragma mark - Configuration

- (GPSLabConfiguration *)configuration {
    os_unfair_lock_lock(&_lock);
    GPSLabConfiguration *copy = [_configuration copy];
    os_unfair_lock_unlock(&_lock);
    return copy;
}

- (void)applyConfiguration:(GPSLabConfiguration *)configuration {
    if (configuration == nil) {
        return;
    }
    GPSLabConfiguration *sanitized = [configuration copy];
    [sanitized sanitize];

    os_unfair_lock_lock(&_lock);
    BOOL anchorMoved = (_configuration.latitude != sanitized.latitude) ||
        (_configuration.longitude != sanitized.longitude);
    _configuration = sanitized;
    if (anchorMoved) {
        [_drift reset];
    }
    os_unfair_lock_unlock(&_lock);

    [[NSNotificationCenter defaultCenter] postNotificationName:GPSLabEngineStateDidChangeNotification
                                                        object:self];
}

- (void)loadPersistedConfiguration {
    GPSLabConfiguration *stored = [[GPSLabStore sharedStore] loadConfiguration];
    _lastKnownKeepLast = stored.keepLastCoordinate;
    [self applyConfiguration:stored];
}

- (void)persistConfiguration {
    GPSLabConfiguration *configuration = [self configuration];

    // Detect a true -> false transition: when the user turns keep-last off, the
    // previously persisted coordinate must be erased, not just left stale.
    os_unfair_lock_lock(&_lock);
    BOOL clearedFromOnToOff = (_lastKnownKeepLast && !configuration.keepLastCoordinate);
    _lastKnownKeepLast = configuration.keepLastCoordinate;
    os_unfair_lock_unlock(&_lock);

    [[GPSLabStore sharedStore] saveConfiguration:configuration];
    if (clearedFromOnToOff) {
        [[GPSLabStore sharedStore] clearPersistedCoordinate];
    }
}

#pragma mark - Enable / disable

- (BOOL)isEnabled {
    os_unfair_lock_lock(&_lock);
    BOOL enabled = _configuration.enabled && _entitlementAllowsSynthesis;
    os_unfair_lock_unlock(&_lock);
    return enabled;
}

- (void)setEnabled:(BOOL)enabled {
    os_unfair_lock_lock(&_lock);
    _configuration.enabled = enabled;
    os_unfair_lock_unlock(&_lock);
}

- (BOOL)isEntitlementAllowsSynthesis {
    os_unfair_lock_lock(&_lock);
    BOOL allows = _entitlementAllowsSynthesis;
    os_unfair_lock_unlock(&_lock);
    return allows;
}

// Applies the entitlement gate. Granting resumes synthetic delivery only when the
// user's persisted preference is enabled; revoking tears every synthetic stream down
// and hands the requested managers back to real CoreLocation, without closing the
// host app or touching host data.
- (void)setEntitlementAllowsSynthesis:(BOOL)allows {
    os_unfair_lock_lock(&_lock);
    BOOL wasAllowed = _entitlementAllowsSynthesis;
    _entitlementAllowsSynthesis = allows;
    BOOL wanted = _configuration.enabled;
    os_unfair_lock_unlock(&_lock);

    if (wasAllowed == allows) {
        return;
    }

    [[NSNotificationCenter defaultCenter] postNotificationName:GPSLabEngineStateDidChangeNotification
                                                        object:self];

    if (allows) {
        if (wanted) {
            [self performEnableTransition];
        }
    } else {
        [self performDisableTransition];
    }
}

- (void)setEnabledAndNotify:(BOOL)enabled {
    os_unfair_lock_lock(&_lock);
    BOOL changed = (_configuration.enabled != enabled);
    _configuration.enabled = enabled;
    BOOL allows = _entitlementAllowsSynthesis;
    os_unfair_lock_unlock(&_lock);

    if (!changed) {
        return;
    }
    GPSLabDiagEngineEnabled(enabled);

    [[NSNotificationCenter defaultCenter] postNotificationName:GPSLabEngineStateDidChangeNotification
                                                        object:self];

    if (enabled && allows) {
        [self performEnableTransition];
    } else {
        // Locked or explicitly disabled: ensure no synthetic delivery, keep intent, and
        // hand requested streams back to real CoreLocation.
        [self performDisableTransition];
    }
    [self persistConfiguration];
}

// Suspend synthetic delivery but remember what each manager requested, then hand each
// requested stream back to real CoreLocation (exactly the kinds the host asked for).
- (void)performDisableTransition {
    [[GPSLabLocationStream sharedStream] suspendAllSyntheticPreservingIntent];
    for (CLLocationManager *manager in [[GPSLabLocationStream sharedStream] standardRequestedManagers]) {
        [GPSLabCoreLocationHooks forwardSelector:@selector(startUpdatingLocation) onManager:manager];
    }
    for (CLLocationManager *manager in [[GPSLabLocationStream sharedStream] significantRequestedManagers]) {
        [GPSLabCoreLocationHooks forwardSelector:@selector(startMonitoringSignificantLocationChanges)
                                       onManager:manager];
    }
    [self stopRoute];
}

// Stop the original streams for managers we had delegated, then resume synthetic.
// Stopping both kinds for those managers is safe (a stop of a non-started stream is a
// no-op); it prevents a real + synthetic stream from running together.
- (void)performEnableTransition {
    NSArray<CLLocationManager *> *requested = [[GPSLabLocationStream sharedStream] requestedManagers];
    for (CLLocationManager *manager in requested) {
        [GPSLabCoreLocationHooks forwardSelector:@selector(stopUpdatingLocation) onManager:manager];
        [GPSLabCoreLocationHooks forwardSelector:@selector(stopMonitoringSignificantLocationChanges)
                                       onManager:manager];
    }
    [[GPSLabLocationStream sharedStream] resumeAllRequestedSynthetic];
}

#pragma mark - Anchor configuration

- (void)setBaseLatitude:(double)latitude
              longitude:(double)longitude
               altitude:(double)altitude
                heading:(double)heading {
    GPSLabConfiguration *updated = [self configuration];
    if (GPSLabIsValidCoordinate(latitude, longitude)) {
        updated.latitude = latitude;
        updated.longitude = longitude;
        updated.altitude = GPSLabClampDouble(altitude, -500.0, 100000.0);
        updated.heading = GPSLabNormalizeHeading(heading);
    }
    [self applyConfiguration:updated];
    [self persistConfiguration];
}

- (CLLocationCoordinate2D)baseCoordinate {
    os_unfair_lock_lock(&_lock);
    CLLocationCoordinate2D coordinate = CLLocationCoordinate2DMake(_configuration.latitude,
                                                                   _configuration.longitude);
    os_unfair_lock_unlock(&_lock);
    return coordinate;
}

#pragma mark - Drift

- (BOOL)isDriftEnabled {
    os_unfair_lock_lock(&_lock);
    BOOL enabled = _configuration.driftEnabled;
    os_unfair_lock_unlock(&_lock);
    return enabled;
}

- (void)setDriftEnabled:(BOOL)enabled {
    os_unfair_lock_lock(&_lock);
    _configuration.driftEnabled = enabled;
    if (!enabled) {
        [_drift reset];
    }
    os_unfair_lock_unlock(&_lock);
    [self persistConfiguration];
}

- (double)driftRadiusMeters {
    os_unfair_lock_lock(&_lock);
    double radius = _configuration.driftRadiusMeters;
    os_unfair_lock_unlock(&_lock);
    return radius;
}

- (void)setDriftRadiusMeters:(double)radius {
    os_unfair_lock_lock(&_lock);
    _configuration.driftRadiusMeters = GPSLabClampDouble(radius, 1.0, 500.0);
    [_drift reset];
    os_unfair_lock_unlock(&_lock);
    [self persistConfiguration];
}

- (void)setKeepLastCoordinate:(BOOL)keepLast {
    GPSLabConfiguration *configuration = [self configuration];
    configuration.keepLastCoordinate = keepLast;
    if (!keepLast) {
        // Turning it off resets the anchor to safe defaults immediately.
        configuration.latitude = 0.0;
        configuration.longitude = 0.0;
        configuration.altitude = 0.0;
        configuration.heading = -1.0;
    }
    [self applyConfiguration:configuration];
    [self persistConfiguration];
}

#pragma mark - Route simulation

- (GPSLabRouteSimulator *)routeSimulator {
    return _routeSimulator;
}

- (void)startRouteFrom:(CLLocationCoordinate2D)start
                    to:(CLLocationCoordinate2D)end
                  mode:(GPSLabRouteMode)mode
        customSpeedKmh:(double)customSpeedKmh
            completion:(nullable GPSLabRouteCompletion)completion {
    // Fail-closed: a route can never start while the entitlement gate is locked, even
    // if a caller reaches this entrypoint directly.
    if (![self isEnabled]) {
        return;
    }
    GPSLabRouteCompletion completionCopy = completion != nil ? [completion copy] : nil;

    os_unfair_lock_lock(&_lock);
    _configuration.routeMode = mode;
    _configuration.routeCustomSpeedKmh = GPSLabClampDouble(customSpeedKmh, 1.0, 300.0);
    os_unfair_lock_unlock(&_lock);

    GPSLabDiagRouteStarted();
    __weak GPSLabEngine *weakSelf = self;
    [_routeSimulator startRouteFrom:start
                                 to:end
                               mode:mode
                     customSpeedKmh:customSpeedKmh
                         completion:^(NSError * _Nullable error) {
        GPSLabEngine *strongSelf = weakSelf;
        if (strongSelf != nil) {
            [strongSelf persistConfiguration];
        }
        if (error == nil) {
            GPSLabDiagRouteStopped();
        } else {
            GPSLabDiagInternalError(2);
        }
        if (completionCopy != nil) {
            completionCopy(error);
        }
    }];
}

- (void)pauseRoute {
    [_routeSimulator pause];
}

- (void)resumeRoute {
    [_routeSimulator resume];
}

- (void)stopRoute {
    BOOL wasActive = [_routeSimulator isActive];
    [_routeSimulator stop];

    os_unfair_lock_lock(&_lock);
    GPSLabStopBehavior behavior = _configuration.stopBehavior;
    GPSLabRouteMode mode = _configuration.routeMode;
    double customSpeed = _configuration.routeCustomSpeedKmh;

    CLLocationCoordinate2D target = CLLocationCoordinate2DMake(_configuration.latitude,
                                                               _configuration.longitude);
    if (behavior == GPSLabStopBehaviorStayAtCurrent) {
        CLLocationCoordinate2D current = target;
        if ([_routeSimulator lastCoordinate:&current]) {
            target = current;
        }
    } else {
        CLLocationCoordinate2D routeStart = target;
        if ([_routeSimulator routeStartCoordinate:&routeStart]) {
            target = routeStart;
        }
    }

    _configuration.latitude = target.latitude;
    _configuration.longitude = target.longitude;
    [_drift reset];
    os_unfair_lock_unlock(&_lock);

    (void)mode;
    (void)customSpeed;

    if (wasActive) {
        GPSLabDiagRouteStopped();
    }
    [self persistConfiguration];

    [[NSNotificationCenter defaultCenter] postNotificationName:GPSLabEngineStateDidChangeNotification
                                                        object:self];
}

#pragma mark - Location generation

- (CLLocation *)currentLocation {
    return [self locationAdvancing:NO];
}

- (CLLocation *)nextLocation {
    return [self locationAdvancing:YES];
}

- (CLLocation *)locationAdvancing:(BOOL)advance {
    // Fail-closed: no synthetic location is ever produced while locked.
    if (![self isEnabled]) {
        return nil;
    }
    BOOL onRoute = [_routeSimulator isActive];
    if (onRoute) {
        return [self routeLocationAdvancing:advance];
    }
    return [self stationaryLocationAdvancing:advance];
}

- (CLLocation *)stationaryLocationAdvancing:(BOOL)advance {
    os_unfair_lock_lock(&_lock);
    CLLocationCoordinate2D anchor = CLLocationCoordinate2DMake(_configuration.latitude,
                                                               _configuration.longitude);
    double radius = _configuration.driftRadiusMeters;
    BOOL driftEnabled = _configuration.driftEnabled;
    double altitude = _configuration.altitude;
    double heading = _configuration.heading;

    CLLocationCoordinate2D coordinate;
    if (driftEnabled && advance) {
        coordinate = [_drift advanceAroundAnchor:anchor radius:radius stepMeters:kGPSLabMaxStepMeters];
    } else if (driftEnabled) {
        coordinate = [_drift currentAroundAnchor:anchor];
    } else {
        coordinate = anchor;
    }
    os_unfair_lock_unlock(&_lock);

    // Belt-and-braces geodesic clamp: never emit a point farther than the radius.
    if (driftEnabled && GPSLabDistanceMeters(anchor, coordinate) > radius) {
        coordinate = GPSLabCoordinateFromOffset(anchor, 0.0, 0.0);
    }

    CLLocation *location = [GPSLabLocationFactory staticLocationWithCoordinate:coordinate
                                                                     altitude:altitude
                                                                      heading:heading];
    [self didProduceLocation:location];
    return location;
}

- (CLLocation *)routeLocationAdvancing:(BOOL)advance {
    (void)advance; // Route progress is time-driven; the interval only picks the sample moment.

    CLLocationCoordinate2D coordinate = CLLocationCoordinate2DMake(0.0, 0.0);
    double course = -1.0;
    if (![_routeSimulator currentCoordinate:&coordinate course:&course]) {
        return [self stationaryLocationAdvancing:NO];
    }

    os_unfair_lock_lock(&_lock);
    double altitude = _configuration.altitude;
    os_unfair_lock_unlock(&_lock);

    double speed = [_routeSimulator currentSpeedMetersPerSecond];
    CLLocation *location = [GPSLabLocationFactory routeLocationWithCoordinate:coordinate
                                                                     altitude:altitude
                                                                      heading:course
                                                           speedMetersPerSec:speed];
    [self didProduceLocation:location];
    return location;
}

- (void)didProduceLocation:(CLLocation *)location {
    [[NSNotificationCenter defaultCenter] postNotificationName:GPSLabLocationDidUpdateNotification
                                                        object:self
                                                      userInfo:@{@"location": location}];
}

@end
