//
//  GPSLabProfileApplicationCoordinator.m
//  GPSLab
//

#import "GPSLabProfileApplicationCoordinator.h"

#import "GPSLabSimulationRegistry.h"

@implementation GPSLabProfileApplicationResult

+ (instancetype)appliedResult {
    GPSLabProfileApplicationResult *result = [[GPSLabProfileApplicationResult alloc] init];
    result->_applied = YES;
    return result;
}

+ (instancetype)resultWithMessageKey:(NSString *)messageKey {
    GPSLabProfileApplicationResult *result = [[GPSLabProfileApplicationResult alloc] init];
    result->_applied = NO;
    result->_messageKey = [messageKey copy];
    return result;
}

@end

@implementation GPSLabProfileApplicationCoordinator {
    id<GPSLabProfileApplicationBackend> _backend;
    NSUInteger _generation;
    NSUInteger _pendingRouteGeneration; // 0 when no owned route is in flight
    NSString *_appliedProfileIdentifier;
}

+ (instancetype)sharedCoordinator {
    static GPSLabProfileApplicationCoordinator *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Resolve the production backend lazily so this coordinator core stays
        // testable on macOS without linking the engine/license stack.
        Class backendClass = NSClassFromString(@"GPSLabEngineProfileBackend");
        id<GPSLabProfileApplicationBackend> backend = backendClass != Nil
            ? [[backendClass alloc] init]
            : nil;
        instance = [[GPSLabProfileApplicationCoordinator alloc] initWithBackend:backend];
    });
    return instance;
}

- (instancetype)initWithBackend:(id<GPSLabProfileApplicationBackend>)backend {
    self = [super init];
    if (self) {
        _backend = backend;
        _generation = 0;
        _pendingRouteGeneration = 0;
    }
    return self;
}

- (NSString *)appliedProfileIdentifier {
    return _appliedProfileIdentifier;
}

#pragma mark - Public API (serialized on the main queue)

- (void)applyProfile:(GPSLabProfile *)profile
          completion:(nullable void (^)(GPSLabProfileApplicationResult *result))completion {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self applyProfile:profile completion:completion];
        });
        return;
    }

    _generation += 1;
    NSUInteger token = _generation;
    // A new application supersedes any pending route owned by an older request:
    // stop it now so an invalid/rejected new apply can never leave a ghost route.
    if (_backend != nil && _pendingRouteGeneration != 0) {
        _pendingRouteGeneration = 0;
        [_backend stopRoute];
    }

    void (^finish)(GPSLabProfileApplicationResult *) = ^(GPSLabProfileApplicationResult *result) {
        if (completion != nil) {
            completion(result);
        }
    };

    if (_backend == nil || profile == nil) {
        finish([GPSLabProfileApplicationResult resultWithMessageKey:@"profiles.error.invalid"]);
        return;
    }
    // Strict preflight of the whole immutable profile BEFORE any side effect.
    if (![profile isValidForApplication]) {
        finish([GPSLabProfileApplicationResult resultWithMessageKey:@"profiles.error.invalid"]);
        return;
    }
    if (![_backend isLicenseUnlocked]) {
        finish([GPSLabProfileApplicationResult resultWithMessageKey:@"profiles.error.locked"]);
        return;
    }
    if (![_backend isEngineEnabled]) {
        finish([GPSLabProfileApplicationResult resultWithMessageKey:@"profiles.error.engineOff"]);
        return;
    }

    id snapshot = [_backend captureSnapshot];

    if (profile.locationMode == GPSLabProfileLocationStatic) {
        [_backend stopRoute];
        [_backend applyStaticCoordinate:CLLocationCoordinate2DMake(profile.latitude, profile.longitude)
                               altitude:profile.altitude
                                heading:profile.heading];
        [_backend setDriftEnabled:profile.driftEnabled radiusMeters:profile.driftRadiusMeters];
        [self activateModulesForProfile:profile];
        _appliedProfileIdentifier = profile.identifier;
        finish([GPSLabProfileApplicationResult appliedResult]);
        return;
    }

    GPSLabProfileRoute *route = profile.route;
    if (route == nil) {
        finish([GPSLabProfileApplicationResult resultWithMessageKey:@"profiles.error.invalid"]);
        return;
    }

    [_backend stopRoute];
    [_backend applyAltitude:profile.altitude heading:profile.heading];
    [_backend setDriftEnabled:profile.driftEnabled radiusMeters:profile.driftRadiusMeters];

    _pendingRouteGeneration = token;
    GPSLabProfileApplicationCoordinator *__weak weakSelf = self;
    CLLocationCoordinate2D start = CLLocationCoordinate2DMake(route.startLatitude, route.startLongitude);
    CLLocationCoordinate2D end = CLLocationCoordinate2DMake(route.endLatitude, route.endLongitude);
    [_backend startRouteFrom:start
                          to:end
                        mode:route.mode
              customSpeedKmh:route.customSpeedKmh
                  completion:^(NSError * _Nullable error) {
        void (^resume)(void) = ^{
            GPSLabProfileApplicationCoordinator *strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }
            [strongSelf handleRouteCompletionForToken:token
                                              profile:profile
                                             snapshot:snapshot
                                                error:error
                                           completion:finish];
        };
        if ([NSThread isMainThread]) {
            resume();
        } else {
            dispatch_async(dispatch_get_main_queue(), resume);
        }
    }];
}

- (void)cancelPendingApplication {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self cancelPendingApplication]; });
        return;
    }
    [self invalidateOwnershipStoppingOwnedPendingRoute];
}

- (void)invalidateAppliedProfile {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self invalidateAppliedProfile]; });
        return;
    }
    [self invalidateOwnershipStoppingOwnedPendingRoute];
}

/** Invalidates ownership and stops ONLY the coordinator-owned pending route. */
- (void)invalidateOwnershipStoppingOwnedPendingRoute {
    _generation += 1;
    if (_pendingRouteGeneration != 0) {
        _pendingRouteGeneration = 0;
        [_backend stopRoute];
    }
    _appliedProfileIdentifier = nil;
}

#pragma mark - Route completion

- (void)handleRouteCompletionForToken:(NSUInteger)token
                              profile:(GPSLabProfile *)profile
                             snapshot:(nullable id)snapshot
                                error:(nullable NSError *)error
                           completion:(void (^)(GPSLabProfileApplicationResult *))finish {
    // A stale completion is side-effect FREE: a newer application already tore
    // the old route down, and a cancellation stopped the route it owned.
    if (token != _generation) {
        finish([GPSLabProfileApplicationResult resultWithMessageKey:@"profiles.error.cancelled"]);
        return;
    }
    _pendingRouteGeneration = 0;

    // Re-check the gate at completion time: a license lock or manual disable
    // between request and completion must never leave a synthetic route running.
    if (![_backend isEngineEnabled] || ![_backend isLicenseUnlocked]) {
        finish([GPSLabProfileApplicationResult resultWithMessageKey:@"profiles.error.cancelled"]);
        return;
    }
    if (error != nil) {
        // Roll back only our own, still-current change.
        [_backend restoreSnapshot:snapshot];
        finish([GPSLabProfileApplicationResult resultWithMessageKey:@"profiles.error.routeFailed"]);
        return;
    }
    [self activateModulesForProfile:profile];
    _appliedProfileIdentifier = profile.identifier;
    finish([GPSLabProfileApplicationResult appliedResult]);
}

#pragma mark - Modules

- (void)activateModulesForProfile:(GPSLabProfile *)profile {
    // Config-only: activate the saved test metadata, or clear it when the profile
    // carries no attachment so a stale config is never left active.
    [GPSLabSimulationRegistry activateWiFiConfig:profile.wifi];
    [GPSLabSimulationRegistry activateBluetoothConfig:profile.bluetooth];
}

@end
