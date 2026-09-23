//
//  GPSLabDriftTests.m
//  GPSLab
//
//  Deterministic, non-flaky tests for the bounded drift model. The random source
//  is injected, so every assertion is reproducible. Covers:
//    * bounds over thousands of steps for the whole 0..20 m range;
//    * radius 0 is the exact base (and clears stale state);
//    * smoothing: consecutive points stay correlated (no edge-to-edge jumps);
//    * latitude-aware longitude conversion in the offset->coordinate helper;
//    * reset / current-without-advance semantics.
//
//  Build/run (macOS):
//    clang -fobjc-arc -fmodules -framework Foundation -framework CoreLocation -ISource \
//      tests/GPSLabDriftTests.m Source/GPSLabDriftModel.m Source/GPSLabGeodesy.m \
//      Source/GPSLabTypes.m -o /tmp/gpslab-drift-tests
//    /tmp/gpslab-drift-tests
//

#import <CoreLocation/CoreLocation.h>
#import <Foundation/Foundation.h>

#include <math.h>
#include <stdint.h>

#import "GPSLabDriftModel.h"
#import "GPSLabGeodesy.h"
#import "GPSLabTypes.h"

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

// A deterministic 64-bit LCG mapped into [0, 1). Same seed => same sequence.
static GPSLabDriftRandomUnitProvider MakeProvider(uint64_t seed) {
    __block uint64_t state = seed;
    return ^double(void) {
        state = (state * 6364136223846793005ULL) + 1442695040888963407ULL;
        return (double)((state >> 11) & 0x1FFFFFFFFFFFFFULL) / (double)0x20000000000000ULL;
    };
}

#pragma mark - Bounds

static void test_bounds_over_thousands(void) {
    // Every radius in the supported range, at several latitudes (including high
    // latitude where the longitude conversion is most sensitive).
    const double radii[] = { 0.0, 0.001, 1.0, 5.0, 20.0 };
    const CLLocationCoordinate2D anchors[] = {
        { 0.0, 0.0 },
        { 24.7136, 46.6753 },
        { 60.0, 10.0 },
        { 89.0, 0.0 },
        { -89.0, 179.0 },
    };
    const int anchorCount = (int)(sizeof(anchors) / sizeof(anchors[0]));
    const int radiusCount = (int)(sizeof(radii) / sizeof(radii[0]));

    for (int a = 0; a < anchorCount; a++) {
        for (int r = 0; r < radiusCount; r++) {
            double radius = radii[r];
            GPSLabDriftModel *model = [[GPSLabDriftModel alloc]
                initWithRandomUnitProvider:MakeProvider((uint64_t)(0xABCD + a * 31 + r))];

            double maxDistance = 0.0;
            for (int step = 0; step < 5000; step++) {
                CLLocationCoordinate2D point = [model advanceAroundAnchor:anchors[a]
                                                                   radius:radius
                                                               stepMeters:1.5];
                double distance = GPSLabDistanceMeters(anchors[a], point);
                if (distance > maxDistance) {
                    maxDistance = distance;
                }
                if (radius <= 0.0) {
                    if (distance > 1e-9) {
                        break; // radius 0 must stay exact; handled below
                    }
                } else if (distance > radius + 1e-6) {
                    break;
                }
            }

            if (radius <= 0.0) {
                CLLocationCoordinate2D point = [model advanceAroundAnchor:anchors[a]
                                                                   radius:radius
                                                               stepMeters:1.5];
                CHECK(fabs(point.latitude - anchors[a].latitude) < 1e-12 &&
                      fabs(point.longitude - anchors[a].longitude) < 1e-12,
                      @"radius 0 emits the exact base coordinate");
            } else {
                CHECK(maxDistance <= radius + 1e-6,
                      @"drift never exceeds the radius over thousands of steps");
                CHECK(maxDistance > 0.0, @"a non-zero radius actually moves the point");
            }
        }
    }
}

#pragma mark - Exact base

static void test_radius_zero_is_exact_base(void) {
    CLLocationCoordinate2D anchor = CLLocationCoordinate2DMake(24.7136, 46.6753);
    GPSLabDriftModel *model = [[GPSLabDriftModel alloc]
        initWithRandomUnitProvider:MakeProvider(0x1234)];

    // Build up an offset, then collapse to radius 0; the stale offset must clear.
    for (int step = 0; step < 50; step++) {
        [model advanceAroundAnchor:anchor radius:20.0 stepMeters:1.5];
    }
    CLLocationCoordinate2D collapsed = [model advanceAroundAnchor:anchor radius:0.0 stepMeters:1.5];
    CHECK(fabs(collapsed.latitude - anchor.latitude) < 1e-12 &&
          fabs(collapsed.longitude - anchor.longitude) < 1e-12,
          @"radius 0 collapses a previously moving walk to the exact base");

    // Widening the radius again must not resurrect the old offset.
    CLLocationCoordinate2D widened = [model advanceAroundAnchor:anchor
                                                         radius:20.0
                                                     stepMeters:1.5];
    CHECK(GPSLabDistanceMeters(anchor, widened) <= 1.5 + 1e-6,
          @"after radius 0, the next step starts fresh from the base (no accumulation)");
}

#pragma mark - Smoothing

static void test_smoothing_no_edge_to_edge(void) {
    CLLocationCoordinate2D anchor = CLLocationCoordinate2DMake(24.7136, 46.6753);
    const double step = 1.5;
    GPSLabDriftModel *model = [[GPSLabDriftModel alloc]
        initWithRandomUnitProvider:MakeProvider(0xDEADBEEF)];

    CLLocationCoordinate2D previous = anchor;
    double maxConsecutive = 0.0;
    double maxFromBase = 0.0;
    for (int i = 0; i < 5000; i++) {
        CLLocationCoordinate2D point = [model advanceAroundAnchor:anchor radius:20.0 stepMeters:step];
        double consecutive = GPSLabDistanceMeters(previous, point);
        if (consecutive > maxConsecutive) {
            maxConsecutive = consecutive;
        }
        double fromBase = GPSLabDistanceMeters(anchor, point);
        if (fromBase > maxFromBase) {
            maxFromBase = fromBase;
        }
        previous = point;
    }

    // A clamped step can travel at most 2x the step length away from the previous
    // point (move + pull-back), which is what keeps the walk smooth.
    CHECK(maxConsecutive <= (2.0 * step) + 1e-6,
          @"consecutive drift points stay correlated (finite step, no teleport)");
    // Never jump across the diameter (edge to edge).
    CHECK(maxConsecutive < 20.0,
          @"the walk never jumps edge-to-edge across the drift radius");
    CHECK(maxFromBase <= 20.0 + 1e-6, @"the walk stays inside the radius while smoothing");
}

#pragma mark - Latitude-aware longitude

static void test_latitude_aware_longitude(void) {
    // 1000 m east at the equator covers more longitude than at 60N (cos 60 = 0.5).
    CLLocationCoordinate2D equator = GPSLabCoordinateFromOffset(CLLocationCoordinate2DMake(0.0, 0.0),
                                                                0.0, 1000.0);
    CLLocationCoordinate2D high = GPSLabCoordinateFromOffset(CLLocationCoordinate2DMake(60.0, 0.0),
                                                             0.0, 1000.0);
    double equatorDelta = fabs(equator.longitude - 0.0);
    double highDelta = fabs(high.longitude - 0.0);

    CHECK(highDelta > equatorDelta, @"longitude conversion widens with latitude");
    CHECK(fabs(highDelta / equatorDelta - 2.0) < 0.02,
          @"1000 m east covers ~2x the longitude at 60N (cos-latitude conversion)");

    // The drift model preserves a fixed base->point geodesic distance at high latitude.
    CLLocationCoordinate2D anchor = CLLocationCoordinate2DMake(60.0, 10.0);
    GPSLabDriftModel *model = [[GPSLabDriftModel alloc]
        initWithRandomUnitProvider:MakeProvider(0x99)];
    double maxFromBase = 0.0;
    for (int i = 0; i < 3000; i++) {
        CLLocationCoordinate2D point = [model advanceAroundAnchor:anchor radius:5.0 stepMeters:1.5];
        maxFromBase = fmax(maxFromBase, GPSLabDistanceMeters(anchor, point));
    }
    CHECK(maxFromBase <= 5.0 + 1e-6, @"lat-aware conversion keeps a 5 m bound at 60N");
}

#pragma mark - Reset / current

static void test_reset_and_current(void) {
    CLLocationCoordinate2D anchor = CLLocationCoordinate2DMake(24.7136, 46.6753);
    GPSLabDriftModel *model = [[GPSLabDriftModel alloc]
        initWithRandomUnitProvider:MakeProvider(0x77)];

    for (int i = 0; i < 25; i++) {
        [model advanceAroundAnchor:anchor radius:10.0 stepMeters:1.5];
    }
    CLLocationCoordinate2D current = [model currentAroundAnchor:anchor];
    CHECK(GPSLabDistanceMeters(anchor, current) > 0.0, @"current reports the walked offset");
    CHECK(GPSLabDistanceMeters(anchor, current) <= 10.0 + 1e-6, @"current is bounded");

    [model reset];
    CLLocationCoordinate2D afterReset = [model currentAroundAnchor:anchor];
    CHECK(fabs(afterReset.latitude - anchor.latitude) < 1e-12 &&
          fabs(afterReset.longitude - anchor.longitude) < 1e-12,
          @"reset returns the walk to the anchor");
}

#pragma mark - Determinism / policy

static void test_deterministic_and_policy(void) {
    CLLocationCoordinate2D anchor = CLLocationCoordinate2DMake(24.7136, 46.6753);
    GPSLabDriftModel *a = [[GPSLabDriftModel alloc] initWithRandomUnitProvider:MakeProvider(0x5A5A)];
    GPSLabDriftModel *b = [[GPSLabDriftModel alloc] initWithRandomUnitProvider:MakeProvider(0x5A5A)];
    for (int i = 0; i < 100; i++) {
        CLLocationCoordinate2D pa = [a advanceAroundAnchor:anchor radius:8.0 stepMeters:1.5];
        CLLocationCoordinate2D pb = [b advanceAroundAnchor:anchor radius:8.0 stepMeters:1.5];
        CHECK(fabs(pa.latitude - pb.latitude) < 1e-12 && fabs(pa.longitude - pb.longitude) < 1e-12,
              @"the injected RNG makes the walk fully reproducible");
    }

    CHECK(GPSLabMinDriftRadiusMeters() == 0.0, @"drift minimum is 0 m");
    CHECK(GPSLabMaxDriftRadiusMeters() == 20.0, @"drift maximum is 20 m");
    CHECK(fabs(GPSLabDefaultDriftRadiusMeters() - 5.0) < 1e-12, @"drift default is 5 m");
    CHECK(GPSLabClampDriftRadiusMeters(-3.0) == 0.0, @"negative radius clamps to 0");
    CHECK(GPSLabClampDriftRadiusMeters(100.0) == 20.0, @"oversized radius clamps to 20");
    CHECK(fabs(GPSLabClampDriftRadiusMeters(7.5) - 7.5) < 1e-12, @"in-range radius is preserved");

    // A NaN radius clamps to the 0 minimum: the exact base, never a crash.
    CLLocationCoordinate2D nanPoint = [a advanceAroundAnchor:anchor radius:NAN stepMeters:1.5];
    CHECK(fabs(nanPoint.latitude - anchor.latitude) < 1e-12 &&
          fabs(nanPoint.longitude - anchor.longitude) < 1e-12,
          @"a NaN radius degrades to the exact base");
}

int main(void) {
    @autoreleasepool {
        test_bounds_over_thousands();
        test_radius_zero_is_exact_base();
        test_smoothing_no_edge_to_edge();
        test_latitude_aware_longitude();
        test_reset_and_current();
        test_deterministic_and_policy();
    }

    if (gFailures == 0) {
        printf("GPSLabDriftTests: %d checks passed\n", gChecks);
        return 0;
    }
    fprintf(stderr, "GPSLabDriftTests: %d/%d checks failed\n", gFailures, gChecks);
    return 1;
}
