//
//  GPSLabProfileApplicationTests.m
//  GPSLab
//
//  Foundation integration tests for GPSLabProfileApplicationCoordinator using an
//  injected fixture backend (no host manager). Proves the real adapter
//  transitions: lock/enable gating, strict preflight, static/route apply order
//  with altitude/heading/drift, module activation/clearing, snapshot rollback,
//  and side-effect-free stale completions.
//
//  Build/run (macOS):
//    clang -fobjc-arc -fmodules -framework Foundation -framework CoreLocation \
//      -ISource tests/GPSLabProfileApplicationTests.m \
//      Source/GPSLabProfileApplicationCoordinator.m Source/GPSLabProfile.m \
//      Source/GPSLabProfileCore.c Source/GPSLabSimulationRegistry.m \
//      Source/GPSLabSimulationModule.m Source/GPSLabWiFiSimulationModule.m \
//      Source/GPSLabBluetoothSimulationModule.m -o /tmp/gpslab-application-tests
//    /tmp/gpslab-application-tests
//

#import <Foundation/Foundation.h>

#import "GPSLabProfileApplicationCoordinator.h"
#import "GPSLabSimulationRegistry.h"

static int gFailures = 0;
static int gChecks = 0;

#define CHECK(condition, message)                                  \
    do {                                                           \
        gChecks++;                                                 \
        if (!(condition)) {                                        \
            gFailures++;                                           \
            fprintf(stderr, "FAIL: %s\n", [(message) UTF8String]); \
        }                                                          \
    } while (0)

#pragma mark - Fixture backend

@interface FixtureBackend : NSObject <GPSLabProfileApplicationBackend>
@property (nonatomic, assign) BOOL engineEnabled;
@property (nonatomic, assign) BOOL licenseUnlocked;
@property (nonatomic, strong) NSMutableArray<NSString *> *calls;
@property (nonatomic, copy, nullable) void (^pendingRouteCompletion)(NSError * _Nullable error);
@property (nonatomic, assign) double lastLatitude;
@property (nonatomic, assign) double lastAltitude;
@property (nonatomic, assign) double lastHeading;
@property (nonatomic, assign) BOOL lastDriftEnabled;
@property (nonatomic, assign) double lastDriftRadius;
@property (nonatomic, strong) id snapshot;
@end

@implementation FixtureBackend

- (instancetype)init {
    self = [super init];
    if (self) {
        _calls = [NSMutableArray array];
        _engineEnabled = YES;
        _licenseUnlocked = YES;
    }
    return self;
}

- (BOOL)isEngineEnabled { return self.engineEnabled; }
- (BOOL)isLicenseUnlocked { return self.licenseUnlocked; }

- (void)applyStaticCoordinate:(CLLocationCoordinate2D)coordinate
                     altitude:(double)altitude
                      heading:(double)heading {
    [self.calls addObject:@"applyStatic"];
    self.lastLatitude = coordinate.latitude;
    self.lastAltitude = altitude;
    self.lastHeading = heading;
}

- (void)applyAltitude:(double)altitude heading:(double)heading {
    [self.calls addObject:@"applyAltitude"];
    self.lastAltitude = altitude;
    self.lastHeading = heading;
}

- (void)setDriftEnabled:(BOOL)enabled radiusMeters:(double)radius {
    [self.calls addObject:@"setDrift"];
    self.lastDriftEnabled = enabled;
    self.lastDriftRadius = radius;
}

- (void)stopRoute {
    [self.calls addObject:@"stopRoute"];
}

- (void)startRouteFrom:(CLLocationCoordinate2D)start
                    to:(CLLocationCoordinate2D)end
                  mode:(GPSLabRouteMode)mode
        customSpeedKmh:(double)customSpeedKmh
            completion:(nullable void (^)(NSError * _Nullable error))completion {
    (void)start;
    (void)end;
    (void)mode;
    (void)customSpeedKmh;
    [self.calls addObject:@"startRoute"];
    self.pendingRouteCompletion = completion;
}

- (nullable id)captureSnapshot {
    [self.calls addObject:@"captureSnapshot"];
    self.snapshot = [NSObject new];
    return self.snapshot;
}

- (void)restoreSnapshot:(nullable id)snapshot {
    [self.calls addObject:@"restoreSnapshot"];
    (void)snapshot;
}

- (NSUInteger)countOfCall:(NSString *)call {
    NSUInteger count = 0;
    for (NSString *entry in self.calls) {
        if ([entry isEqualToString:call]) {
            count++;
        }
    }
    return count;
}

@end

#pragma mark - Helpers

static GPSLabProfileWiFiConfig *WiFiConfig(void) {
    return [[GPSLabProfileWiFiConfig alloc] initWithProfileName:@"Home net" ssid:@"GPSLab-Test" signal:80];
}

static GPSLabProfile *StaticProfile(NSString *identifier, BOOL withWiFi) {
    return [[GPSLabProfile alloc] initWithIdentifier:identifier
                                                name:@"Home"
                                        locationMode:GPSLabProfileLocationStatic
                                           latitude:24.7136
                                          longitude:46.6753
                                           altitude:612.0
                                            heading:90.0
                                       driftEnabled:YES
                                  driftRadiusMeters:30.0
                                              route:nil
                                               wifi:(withWiFi ? WiFiConfig() : nil)
                                          bluetooth:nil
                                           schedule:nil];
}

static GPSLabProfile *RouteProfile(NSString *identifier) {
    GPSLabProfileRoute *route = [[GPSLabProfileRoute alloc] initWithStartLatitude:24.7136
                                                                    startLongitude:46.6753
                                                                      endLatitude:24.7749
                                                                    endLongitude:46.7386
                                                                          altitude:700.0
                                                                           heading:45.0
                                                                              mode:GPSLabRouteModeDriving
                                                                    customSpeedKmh:50.0];
    return [[GPSLabProfile alloc] initWithIdentifier:identifier
                                                name:@"Work"
                                        locationMode:GPSLabProfileLocationRoute
                                           latitude:24.7136
                                          longitude:46.6753
                                           altitude:700.0
                                            heading:45.0
                                       driftEnabled:NO
                                  driftRadiusMeters:30.0
                                              route:route
                                               wifi:nil
                                          bluetooth:nil
                                           schedule:nil];
}

static GPSLabProfileApplicationResult *ApplySync(GPSLabProfileApplicationCoordinator *coordinator,
                                                 GPSLabProfile *profile) {
    __block GPSLabProfileApplicationResult *captured = nil;
    [coordinator applyProfile:profile completion:^(GPSLabProfileApplicationResult *result) {
        captured = result;
    }];
    return captured;
}

static GPSLabProfileApplicationResult *StageSync(GPSLabProfileApplicationCoordinator *coordinator,
                                                 GPSLabProfile *profile) {
    __block GPSLabProfileApplicationResult *captured = nil;
    [coordinator stageProfile:profile completion:^(GPSLabProfileApplicationResult *result) {
        captured = result;
    }];
    return captured;
}

#pragma mark - Tests

static void test_lock_and_enable_gating(void) {
    FixtureBackend *backend = [[FixtureBackend alloc] init];
    GPSLabProfileApplicationCoordinator *coordinator =
        [[GPSLabProfileApplicationCoordinator alloc] initWithBackend:backend];

    backend.licenseUnlocked = NO;
    GPSLabProfileApplicationResult *locked = ApplySync(coordinator, StaticProfile(@"s1", NO));
    CHECK(locked != nil && !locked.applied, @"locked license does not apply");
    CHECK([locked.messageKey isEqualToString:@"profiles.error.locked"], @"locked message key");
    CHECK(backend.calls.count == 0, @"locked license performs no backend work");

    backend.licenseUnlocked = YES;
    backend.engineEnabled = NO;
    GPSLabProfileApplicationResult *off = ApplySync(coordinator, StaticProfile(@"s1", NO));
    CHECK(off != nil && !off.applied, @"disabled engine does not apply");
    CHECK([off.messageKey isEqualToString:@"profiles.error.engineOff"], @"engine-off message key");
    CHECK(backend.calls.count == 0, @"disabled engine performs no backend work (never re-enables)");
}

static void test_strict_preflight_rejects_malformed(void) {
    FixtureBackend *backend = [[FixtureBackend alloc] init];
    GPSLabProfileApplicationCoordinator *coordinator =
        [[GPSLabProfileApplicationCoordinator alloc] initWithBackend:backend];
    // Route mode with a NULL route block: a typed init can build this.
    GPSLabProfile *malformed = [[GPSLabProfile alloc] initWithIdentifier:@"bad"
                                                                     name:@"Bad"
                                                             locationMode:GPSLabProfileLocationRoute
                                                                latitude:24.0
                                                               longitude:46.0
                                                                altitude:0.0
                                                                 heading:-1.0
                                                            driftEnabled:NO
                                                       driftRadiusMeters:30.0
                                                                   route:nil
                                                                    wifi:nil
                                                               bluetooth:nil
                                                                schedule:nil];
    GPSLabProfileApplicationResult *result = ApplySync(coordinator, malformed);
    CHECK(result != nil && !result.applied, @"malformed typed profile rejected");
    CHECK(backend.calls.count == 0, @"preflight runs before any side effect");
}

static void test_static_apply_applies_alt_heading_drift(void) {
    FixtureBackend *backend = [[FixtureBackend alloc] init];
    GPSLabProfileApplicationCoordinator *coordinator =
        [[GPSLabProfileApplicationCoordinator alloc] initWithBackend:backend];
    GPSLabProfileApplicationResult *result = ApplySync(coordinator, StaticProfile(@"s2", NO));
    CHECK(result.applied, @"static profile applies");
    CHECK([backend.calls[0] isEqualToString:@"captureSnapshot"], @"snapshot captured first");
    CHECK([backend.calls containsObject:@"stopRoute"], @"old route cleared");
    CHECK([backend.calls containsObject:@"applyStatic"], @"anchor applied");
    CHECK([backend.calls containsObject:@"setDrift"], @"drift applied");
    CHECK(fabs(backend.lastAltitude - 612.0) < 1e-9, @"altitude applied");
    CHECK(fabs(backend.lastHeading - 90.0) < 1e-9, @"heading applied");
    CHECK(backend.lastDriftEnabled && fabs(backend.lastDriftRadius - 30.0) < 1e-9, @"drift forwarded");
    CHECK([coordinator.appliedProfileIdentifier isEqualToString:@"s2"], @"ownership recorded");
}

static void test_modules_activate_and_clear(void) {
    FixtureBackend *backend = [[FixtureBackend alloc] init];
    GPSLabProfileApplicationCoordinator *coordinator =
        [[GPSLabProfileApplicationCoordinator alloc] initWithBackend:backend];

    ApplySync(coordinator, StaticProfile(@"wifi-on", YES));
    CHECK([GPSLabSimulationRegistry activeWiFiConfig] != nil, @"wifi metadata activated");

    ApplySync(coordinator, StaticProfile(@"wifi-off", NO));
    CHECK([GPSLabSimulationRegistry activeWiFiConfig] == nil,
          @"absent attachment clears prior wifi metadata");
}

static void test_route_apply_applies_alt_heading_drift(void) {
    FixtureBackend *backend = [[FixtureBackend alloc] init];
    GPSLabProfileApplicationCoordinator *coordinator =
        [[GPSLabProfileApplicationCoordinator alloc] initWithBackend:backend];
    __block GPSLabProfileApplicationResult *captured = nil;
    [coordinator applyProfile:RouteProfile(@"r1") completion:^(GPSLabProfileApplicationResult *result) {
        captured = result;
    }];
    CHECK(captured == nil, @"route apply is asynchronous");
    CHECK([backend.calls containsObject:@"applyAltitude"], @"route altitude/heading applied");
    CHECK([backend.calls containsObject:@"setDrift"], @"route drift applied consistently");
    CHECK([backend.calls containsObject:@"startRoute"], @"route started");
    CHECK(fabs(backend.lastAltitude - 700.0) < 1e-9, @"route altitude forwarded");
    backend.pendingRouteCompletion(nil);
    CHECK(captured != nil && captured.applied, @"route success applies");
    CHECK([coordinator.appliedProfileIdentifier isEqualToString:@"r1"], @"route ownership recorded");
}

static void test_stale_completion_is_side_effect_free(void) {
    FixtureBackend *backend = [[FixtureBackend alloc] init];
    GPSLabProfileApplicationCoordinator *coordinator =
        [[GPSLabProfileApplicationCoordinator alloc] initWithBackend:backend];
    __block GPSLabProfileApplicationResult *resultA = nil;
    [coordinator applyProfile:RouteProfile(@"A") completion:^(GPSLabProfileApplicationResult *r) {
        resultA = r;
    }];
    void (^completionA)(NSError *) = backend.pendingRouteCompletion;

    __block GPSLabProfileApplicationResult *resultB = nil;
    [coordinator applyProfile:RouteProfile(@"B") completion:^(GPSLabProfileApplicationResult *r) {
        resultB = r;
    }];
    NSUInteger stopsAfterB = [backend countOfCall:@"stopRoute"];
    completionA(nil); // stale completion for A
    CHECK(resultA != nil && !resultA.applied, @"stale A completion is cancelled");
    CHECK([resultA.messageKey isEqualToString:@"profiles.error.cancelled"], @"stale A message");
    CHECK([backend countOfCall:@"stopRoute"] == stopsAfterB,
          @"stale completion performs NO stopRoute (cannot stop B)");
    CHECK(coordinator.appliedProfileIdentifier == nil, @"B still pending, no ownership yet");

    backend.pendingRouteCompletion(nil);
    CHECK(resultB != nil && resultB.applied, @"B still applies");
    CHECK([coordinator.appliedProfileIdentifier isEqualToString:@"B"], @"B owns");
}

static void test_disable_or_lock_between_request_and_completion(void) {
    FixtureBackend *backend = [[FixtureBackend alloc] init];
    GPSLabProfileApplicationCoordinator *coordinator =
        [[GPSLabProfileApplicationCoordinator alloc] initWithBackend:backend];

    __block GPSLabProfileApplicationResult *disabled = nil;
    [coordinator applyProfile:RouteProfile(@"d") completion:^(GPSLabProfileApplicationResult *r) {
        disabled = r;
    }];
    backend.engineEnabled = NO;
    backend.pendingRouteCompletion(nil);
    CHECK(disabled != nil && !disabled.applied, @"disable between request/completion never applies");
    CHECK([disabled.messageKey isEqualToString:@"profiles.error.cancelled"], @"disable message");

    backend.engineEnabled = YES;
    __block GPSLabProfileApplicationResult *locked = nil;
    [coordinator applyProfile:RouteProfile(@"l") completion:^(GPSLabProfileApplicationResult *r) {
        locked = r;
    }];
    backend.licenseUnlocked = NO;
    backend.pendingRouteCompletion(nil);
    CHECK(locked != nil && !locked.applied, @"lock between request/completion never applies");
}

static void test_cancel_stops_only_owned_route(void) {
    FixtureBackend *backend = [[FixtureBackend alloc] init];
    GPSLabProfileApplicationCoordinator *coordinator =
        [[GPSLabProfileApplicationCoordinator alloc] initWithBackend:backend];
    [coordinator applyProfile:RouteProfile(@"c1") completion:nil];
    NSUInteger stopsBefore = [backend countOfCall:@"stopRoute"];
    [coordinator cancelPendingApplication];
    CHECK([backend countOfCall:@"stopRoute"] == stopsBefore + 1,
          @"cancel stops the route it owns");
    CHECK(coordinator.appliedProfileIdentifier == nil, @"cancel clears ownership");

    // A completion after cancel is stale and side-effect free.
    void (^completion)(NSError *) = backend.pendingRouteCompletion;
    NSUInteger stopsAfterCancel = [backend countOfCall:@"stopRoute"];
    completion(nil);
    CHECK([backend countOfCall:@"stopRoute"] == stopsAfterCancel,
          @"post-cancel completion performs no extra stopRoute");
}

static void test_invalid_apply_does_not_disturb_prior(void) {
    FixtureBackend *backend = [[FixtureBackend alloc] init];
    GPSLabProfileApplicationCoordinator *coordinator =
        [[GPSLabProfileApplicationCoordinator alloc] initWithBackend:backend];
    [coordinator applyProfile:RouteProfile(@"ghost") completion:nil];
    NSUInteger stopsBefore = [backend countOfCall:@"stopRoute"];

    GPSLabProfile *malformed = [[GPSLabProfile alloc] initWithIdentifier:@"bad"
                                                                     name:@"Bad"
                                                             locationMode:GPSLabProfileLocationRoute
                                                                 latitude:24.0
                                                                longitude:46.0
                                                                 altitude:0.0
                                                                  heading:-1.0
                                                             driftEnabled:NO
                                                        driftRadiusMeters:30.0
                                                                    route:nil
                                                                     wifi:nil
                                                                bluetooth:nil
                                                                 schedule:nil];
    GPSLabProfileApplicationResult *result = ApplySync(coordinator, malformed);
    CHECK(result != nil && !result.applied, @"invalid new apply rejected");
    CHECK([backend countOfCall:@"stopRoute"] == stopsBefore,
          @"invalid apply leaves the prior owned pending route intact (validate-before-disturb)");
}

static void test_valid_replacement_stops_prior_pending_route(void) {
    FixtureBackend *backend = [[FixtureBackend alloc] init];
    GPSLabProfileApplicationCoordinator *coordinator =
        [[GPSLabProfileApplicationCoordinator alloc] initWithBackend:backend];
    [coordinator applyProfile:RouteProfile(@"r1") completion:nil]; // pending, owned
    NSUInteger stopsBefore = [backend countOfCall:@"stopRoute"];

    GPSLabProfileApplicationResult *result = ApplySync(coordinator, StaticProfile(@"s2", NO));
    CHECK(result != nil && result.applied, @"valid replacement applies");
    CHECK([backend countOfCall:@"stopRoute"] > stopsBefore,
          @"a valid replacement stops the prior owned pending route");
    CHECK([coordinator.appliedProfileIdentifier isEqualToString:@"s2"], @"ownership moves to the new profile");
}

static void test_stage_profile_while_engine_off(void) {
    // Static profile staged while OFF: configuration is loaded, engine stays OFF.
    FixtureBackend *backend = [[FixtureBackend alloc] init];
    backend.engineEnabled = NO;
    backend.licenseUnlocked = YES;
    GPSLabProfileApplicationCoordinator *coordinator =
        [[GPSLabProfileApplicationCoordinator alloc] initWithBackend:backend];

    GPSLabProfileApplicationResult *staged = StageSync(coordinator, StaticProfile(@"stage-s", NO));
    CHECK(staged != nil && staged.applied, @"static profile stages while the engine is off");
    CHECK(backend.engineEnabled == NO, @"staging never enables the engine");
    CHECK([backend countOfCall:@"applyStatic"] == 1, @"staged static coordinate applied");
    CHECK([backend countOfCall:@"setDrift"] == 1, @"staged drift applied");
    CHECK(fabs(backend.lastLatitude - 24.7136) < 1e-9 && fabs(backend.lastAltitude - 612.0) < 1e-9,
          @"staged static values recorded");
    CHECK(coordinator.appliedProfileIdentifier == nil,
          @"staging does not claim scheduler ownership");

    // Route profile staged while OFF: the SAVED start coordinate is staged as the
    // anchor with altitude/heading/drift; the route is never started.
    FixtureBackend *routeBackend = [[FixtureBackend alloc] init];
    routeBackend.engineEnabled = NO;
    GPSLabProfileApplicationCoordinator *routeCoordinator =
        [[GPSLabProfileApplicationCoordinator alloc] initWithBackend:routeBackend];
    GPSLabProfileApplicationResult *routeStaged = StageSync(routeCoordinator, RouteProfile(@"stage-r"));
    CHECK(routeStaged != nil && routeStaged.applied, @"route profile stages while off");
    CHECK(routeBackend.engineEnabled == NO, @"route staging never enables the engine");
    CHECK([routeBackend countOfCall:@"startRoute"] == 0, @"route staging never starts the route");
    CHECK([routeBackend countOfCall:@"applyStatic"] == 1, @"route staging restores the saved coordinate");
    CHECK(fabs(routeBackend.lastLatitude - 24.7136) < 1e-9 && fabs(routeBackend.lastAltitude - 700.0) < 1e-9,
          @"route staged anchor/altitude recorded");
    CHECK([routeBackend countOfCall:@"setDrift"] == 1, @"route staging applies drift");
    CHECK([routeBackend countOfCall:@"stopRoute"] >= 1, @"route staging stops any prior route");

    // Locked license refuses staging and performs no backend work.
    FixtureBackend *lockedBackend = [[FixtureBackend alloc] init];
    lockedBackend.engineEnabled = NO;
    lockedBackend.licenseUnlocked = NO;
    GPSLabProfileApplicationCoordinator *lockedCoordinator =
        [[GPSLabProfileApplicationCoordinator alloc] initWithBackend:lockedBackend];
    GPSLabProfileApplicationResult *locked = StageSync(lockedCoordinator, StaticProfile(@"stage-l", NO));
    CHECK(locked != nil && !locked.applied, @"locked license refuses staging");
    CHECK([locked.messageKey isEqualToString:@"profiles.error.locked"], @"staging lock message key");
    CHECK(lockedBackend.calls.count == 0, @"locked staging performs no backend work");
}

static void test_stage_stops_prior_owned_active_route(void) {
    FixtureBackend *backend = [[FixtureBackend alloc] init];
    backend.engineEnabled = YES;
    GPSLabProfileApplicationCoordinator *coordinator =
        [[GPSLabProfileApplicationCoordinator alloc] initWithBackend:backend];
    [coordinator applyProfile:StaticProfile(@"owned", NO) completion:nil];
    CHECK([coordinator.appliedProfileIdentifier isEqualToString:@"owned"], @"prior apply owns a profile");
    NSUInteger stopsBefore = [backend countOfCall:@"stopRoute"];

    GPSLabProfileApplicationResult *staged = StageSync(coordinator, StaticProfile(@"stage", NO));
    CHECK(staged != nil && staged.applied, @"staging applies after a prior apply");
    CHECK([backend countOfCall:@"stopRoute"] > stopsBefore, @"staging stops the prior owned active route");
    CHECK(coordinator.appliedProfileIdentifier == nil, @"staging clears prior ownership");
}

int main(void) {
    @autoreleasepool {
        test_lock_and_enable_gating();
        test_strict_preflight_rejects_malformed();
        test_static_apply_applies_alt_heading_drift();
        test_modules_activate_and_clear();
        test_route_apply_applies_alt_heading_drift();
        test_stale_completion_is_side_effect_free();
        test_disable_or_lock_between_request_and_completion();
        test_cancel_stops_only_owned_route();
        test_invalid_apply_does_not_disturb_prior();
        test_valid_replacement_stops_prior_pending_route();
        test_stage_profile_while_engine_off();
        test_stage_stops_prior_owned_active_route();
    }

    if (gFailures == 0) {
        printf("GPSLabProfileApplicationTests: %d checks passed\n", gChecks);
        return 0;
    }
    fprintf(stderr, "GPSLabProfileApplicationTests: %d/%d checks failed\n", gFailures, gChecks);
    return 1;
}
