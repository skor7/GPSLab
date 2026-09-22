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

#import "GPSLabConfiguration.h"
#import "GPSLabEngine.h"

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
