//
//  GPSLabEngineTests.m
//  GPSLab
//
//  Real Foundation/CoreLocation tests for the synthetic engine's master
//  ON/OFF behaviour, driven through the existing public API with the entitlement
//  gate granted directly (no license/network needed). Covers:
//    * OFF is passthrough: no synthetic fix is produced and disable is idempotent;
//    * ON produces a fix at the configured anchor/altitude/heading;
//    * OFF -> ON preserves the configured settings;
//    * signed altitude is preserved and the documented range is honoured;
//    * revoking the entitlement turns synthesis off fail-closed.
//
//  Build/run (macOS):
//    clang -fobjc-arc -fmodules -framework Foundation -framework CoreLocation -ISource \
//      tests/GPSLabEngineTests.m Source/GPSLabEngine.m Source/GPSLabConfiguration.m \
//      Source/GPSLabRouteSimulator.m Source/GPSLabDriftModel.m Source/GPSLabLocationFactory.m \
//      Source/GPSLabGeodesy.m Source/GPSLabTypes.m Source/GPSLabStore.m \
//      Source/CoreLocationHooks.m Source/LocationStream.m Source/Diagnostics.m \
//      -o /tmp/gpslab-engine-tests
//    /tmp/gpslab-engine-tests
//

#import <CoreLocation/CoreLocation.h>
#import <Foundation/Foundation.h>

#include <math.h>
#include <stdint.h>

#import "GPSLabConfiguration.h"
#import "GPSLabEngine.h"
#import "GPSLabGeodesy.h"

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

static BOOL nearly(double a, double b) {
    return fabs(a - b) < 1e-6;
}

// Deterministic 64-bit LCG -> [0, 1); the same seed reproduces the same walk.
typedef double (^GPSLabTestRandomUnitProvider)(void);

static GPSLabTestRandomUnitProvider MakeProvider(uint64_t seed) {
    __block uint64_t state = seed;
    return ^double(void) {
        state = (state * 6364136223846793005ULL) + 1442695040888963407ULL;
        return (double)((state >> 11) & 0x1FFFFFFFFFFFFFULL) / (double)0x20000000000000ULL;
    };
}

int main(void) {
    @autoreleasepool {
        GPSLabEngine *engine = [GPSLabEngine sharedEngine];
        // Test seam: grant the entitlement directly, so no Keychain/network is used.
        engine.entitlementAllowsSynthesis = YES;
        [engine setEnabledAndNotify:NO];

        GPSLabConfiguration *config = [engine configuration];
        config.latitude = 24.7136;
        config.longitude = 46.6753;
        config.altitude = 612.5;
        config.heading = 45.0;
        config.driftEnabled = NO;
        config.keepLastCoordinate = YES;
        [engine applyConfiguration:config];

        // OFF: passthrough (no synthetic fix), idempotent disable.
        CHECK(!engine.isEnabled, @"disabled engine reports disabled");
        CHECK([engine currentLocation] == nil, @"disabled engine is passthrough (no current fix)");
        CHECK([engine nextLocation] == nil, @"disabled engine is passthrough (no next fix)");
        [engine setEnabledAndNotify:NO]; // idempotent
        CHECK(!engine.isEnabled, @"repeated disable keeps the engine off");

        // ON: produces a fix at the configured anchor/altitude/heading.
        [engine setEnabledAndNotify:YES];
        CHECK(engine.isEnabled, @"enabled engine reports enabled");
        CLLocation *on = [engine currentLocation];
        CHECK(on != nil, @"enabled engine produces a fix");
        CHECK(nearly(on.coordinate.latitude, 24.7136) && nearly(on.coordinate.longitude, 46.6753),
              @"enabled fix uses the configured anchor");
        CHECK(nearly(on.altitude, 612.5), @"fractional altitude preserved");
        CHECK(nearly(on.course, 45.0), @"configured heading preserved");

        // OFF -> ON preserves the configuration (settings preservation).
        [engine setEnabledAndNotify:NO];
        [engine setEnabledAndNotify:YES];
        CLLocation *again = [engine currentLocation];
        CHECK(again != nil, @"re-enabled engine produces a fix");
        CHECK(nearly(again.coordinate.latitude, 24.7136) && nearly(again.coordinate.longitude, 46.6753),
              @"OFF->ON preserves the anchor");
        CHECK(nearly(again.altitude, 612.5), @"OFF->ON preserves the altitude");
        CHECK(nearly(again.course, 45.0), @"OFF->ON preserves the heading");

        // Signed altitude is preserved; the documented range is honoured.
        config = [engine configuration];
        config.altitude = -250.25;
        [engine applyConfiguration:config];
        CHECK(nearly([engine currentLocation].altitude, -250.25), @"negative altitude preserved");

        config = [engine configuration];
        config.altitude = 999999.0;
        [engine applyConfiguration:config];
        CHECK(nearly([engine currentLocation].altitude, 100000.0),
              @"altitude above the documented max is clamped by the engine (UI must pre-validate)");

        config = [engine configuration];
        config.altitude = -100000.0;
        [engine applyConfiguration:config];
        CHECK(nearly([engine currentLocation].altitude, -500.0),
              @"altitude below the documented min is clamped by the engine (UI must pre-validate)");

        // === Drift: bounded around the BASE, smooth, altitude/heading preserved,
        // and radius 0 is the exact base. The RNG is injected so this never flakes.
        CLLocationCoordinate2D base = CLLocationCoordinate2DMake(24.7136, 46.6753);
        config = [engine configuration];
        config.latitude = base.latitude;
        config.longitude = base.longitude;
        config.altitude = 612.5;
        config.heading = 45.0;
        config.driftEnabled = YES;
        config.driftRadiusMeters = 5.0;
        [engine applyConfiguration:config];
        [engine setDriftRandomUnitProvider:MakeProvider(0x1234)];

        int produced = 0;
        double maxDrift = 0.0;
        for (int i = 0; i < 4000; i++) {
            CLLocation *location = [engine nextLocation];
            if (location == nil) {
                break;
            }
            produced++;
            double distance = GPSLabDistanceMeters(base, location.coordinate);
            if (distance > maxDrift) {
                maxDrift = distance;
            }
            if (distance > 5.0 + 1e-6) {
                break;
            }
        }
        CHECK(produced == 4000, @"engine produced every requested drift fix");
        CHECK(maxDrift <= 5.0 + 1e-6, @"engine drift never exceeds the configured radius");
        CHECK(maxDrift > 0.0, @"engine drift actually moves off the base");
        CHECK(nearly([engine currentLocation].altitude, 612.5), @"altitude preserved while drifting");
        CHECK(nearly([engine currentLocation].course, 45.0), @"heading preserved while drifting");

        // currentLocation must not advance the walk.
        CLLocationCoordinate2D frozen = [engine currentLocation].coordinate;
        CLLocationCoordinate2D frozenAgain = [engine currentLocation].coordinate;
        CHECK(nearly(frozen.latitude, frozenAgain.latitude) &&
              nearly(frozen.longitude, frozenAgain.longitude),
              @"currentLocation does not advance the walk");

        // Narrowing the radius through applyConfiguration: a stale wider-radius
        // offset must not jump onto the new smaller bound; the walk resets instead.
        config = [engine configuration];
        config.latitude = base.latitude;
        config.longitude = base.longitude;
        config.driftEnabled = YES;
        config.driftRadiusMeters = 20.0;
        [engine applyConfiguration:config];
        double (^midProvider)(void) = ^double(void) { return 0.5; }; // straight north, 0.8625 m/step
        [engine setDriftRandomUnitProvider:midProvider];
        for (int i = 0; i < 10; i++) {
            [engine nextLocation];
        }
        double wideOffset = GPSLabDistanceMeters(base, [engine currentLocation].coordinate);
        CHECK(wideOffset > 1.0, @"a wider radius built up an offset before narrowing");
        config = [engine configuration];
        config.driftRadiusMeters = 5.0;
        [engine applyConfiguration:config];
        CHECK(GPSLabDistanceMeters(base, [engine currentLocation].coordinate) < 1e-6,
              @"narrowing the radius through applyConfiguration resets the walk (no jump)");

        // Radius 0: the exact base, every time, and no stale offset accumulates.
        [engine setDriftRadiusMeters:0.0];
        BOOL exactBase = YES;
        for (int i = 0; i < 20; i++) {
            CLLocation *location = [engine nextLocation];
            if (location == nil ||
                !nearly(location.coordinate.latitude, base.latitude) ||
                !nearly(location.coordinate.longitude, base.longitude)) {
                exactBase = NO;
            }
        }
        CHECK(exactBase, @"radius 0 emits the exact base coordinate");

        // Editing the radius never enables drift, and clamps into [0, 20].
        [engine setDriftEnabled:NO];
        [engine setDriftRadiusMeters:10.0];
        CHECK(!engine.isDriftEnabled, @"editing the radius never enables the engine");
        CHECK(nearly(engine.driftRadiusMeters, 10.0), @"in-range radius is preserved");
        [engine setDriftRadiusMeters:100.0];
        CHECK(nearly(engine.driftRadiusMeters, 20.0), @"radius clamps at 20 m");
        [engine setDriftRadiusMeters:-4.0];
        CHECK(nearly(engine.driftRadiusMeters, 0.0), @"radius floors at 0 m");
        [engine setDriftRadiusMeters:20.0];
        [engine setDriftEnabled:YES];

        // Route behaviour is preserved: while a route is active the engine emits
        // route positions, never drift around the (far away) base anchor.
        config = [engine configuration];
        config.latitude = 1.0;
        config.longitude = 1.0;
        config.driftEnabled = YES;
        config.driftRadiusMeters = 20.0;
        [engine applyConfiguration:config];

        CLLocationCoordinate2D routeStart = CLLocationCoordinate2DMake(24.7136, 46.6753);
        CLLocationCoordinate2D routeEnd = CLLocationCoordinate2DMake(24.7749, 46.7386);
        [engine startRouteFrom:routeStart
                            to:routeEnd
                          mode:GPSLabRouteModeCustom
                customSpeedKmh:50.0
                    completion:nil];
        CLLocation *routeFix = [engine nextLocation];
        CHECK(routeFix != nil, @"an active route still emits a fix");
        CHECK(routeFix != nil && GPSLabDistanceMeters(routeStart, routeFix.coordinate) < 5.0,
              @"route fixes come from the route, not from drift around the base");
        [engine stopRoute];

        // Revoking the entitlement turns synthesis off fail-closed.
        engine.entitlementAllowsSynthesis = NO;
        CHECK(!engine.isEnabled, @"revoked entitlement disables synthesis");
        CHECK([engine currentLocation] == nil, @"revoked entitlement is passthrough");
    }

    if (gFailures == 0) {
        printf("GPSLabEngineTests: %d checks passed\n", gChecks);
        return 0;
    }
    fprintf(stderr, "GPSLabEngineTests: %d/%d checks failed\n", gFailures, gChecks);
    return 1;
}
