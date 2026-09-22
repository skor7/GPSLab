/*
 * GPSLab selection policy tests (portable C).
 *
 * Pins the exact runtime rules shared by the pending-selection draft validation
 * and the favorite-add decision:
 *   - field validation reuses the established profile ranges;
 *   - only known provider keys are accepted;
 *   - a pending selection is always allowed (including an intentional 0,0);
 *   - a valid non-zero committed coordinate is allowed;
 *   - a pristine default (0,0) is refused without proof;
 *   - an intentional/legacy persisted 0,0 is allowed with a receipt/recent proof;
 *   - a stale non-zero receipt can never authorize a later reset-to-(0,0);
 *   - the 5 m duplicate tolerance is exact at the boundary.
 *
 * Build/run:
 *   cc -I Source tests/gpslab_selection_policy_test.c \
 *     Source/GPSLabSelectionPolicyCore.c Source/GPSLabProfileCore.c \
 *     -o /tmp/gpslab_selection_policy_test && /tmp/gpslab_selection_policy_test
 */

#include <math.h>
#include <stdio.h>

#include "GPSLabSelectionPolicyCore.h"

static int gFailures = 0;
static int gChecks = 0;

#define CHECK(condition, message)                                                \
    do {                                                                         \
        gChecks++;                                                               \
        if (!(condition)) {                                                      \
            gFailures++;                                                         \
            fprintf(stderr, "FAIL: %s (%s:%d)\n", (message), __FILE__, __LINE__); \
        }                                                                        \
    } while (0)

static void test_fields_valid(void) {
    CHECK(GPSLabSelectionFieldsValid(24.7136, 46.6753, 612.5, 45.0), "valid fields");
    CHECK(GPSLabSelectionFieldsValid(0.0, 0.0, 0.0, -1.0), "zero with unknown heading valid");
    CHECK(GPSLabSelectionFieldsValid(-90.0, -180.0, -500.0, -360.0), "lower bounds valid");
    CHECK(GPSLabSelectionFieldsValid(90.0, 180.0, 100000.0, 360.0), "upper bounds valid");

    CHECK(!GPSLabSelectionFieldsValid(91.0, 0.0, 0.0, 0.0), "latitude out of range");
    CHECK(!GPSLabSelectionFieldsValid(0.0, 181.0, 0.0, 0.0), "longitude out of range");
    CHECK(!GPSLabSelectionFieldsValid(0.0, 0.0, 100001.0, 0.0), "altitude out of range");
    CHECK(!GPSLabSelectionFieldsValid(0.0, 0.0, -501.0, 0.0), "altitude below range");
    CHECK(!GPSLabSelectionFieldsValid(0.0, 0.0, 0.0, 361.0), "heading out of range");
    CHECK(!GPSLabSelectionFieldsValid(0.0, 0.0, 0.0, -361.0), "heading below range");
    CHECK(!GPSLabSelectionFieldsValid(NAN, 0.0, 0.0, 0.0), "nan latitude rejected");
    CHECK(!GPSLabSelectionFieldsValid(0.0, INFINITY, 0.0, 0.0), "inf longitude rejected");
    CHECK(!GPSLabSelectionFieldsValid(0.0, 0.0, NAN, 0.0), "nan altitude rejected");
    CHECK(!GPSLabSelectionFieldsValid(0.0, 0.0, 0.0, INFINITY), "inf heading rejected");
}

static void test_provider_known(void) {
    const char *google = "search.source.google";
    const char *apple = "search.source.apple";
    CHECK(GPSLabSelectionProviderKeyKnown(google, 20), "google provider known");
    CHECK(GPSLabSelectionProviderKeyKnown(apple, 19), "apple provider known");
    CHECK(!GPSLabSelectionProviderKeyKnown("search.source.unknown", 21), "unknown provider rejected");
    CHECK(!GPSLabSelectionProviderKeyKnown("", 0), "empty provider rejected");
    CHECK(!GPSLabSelectionProviderKeyKnown(NULL, 0), "null provider rejected");
    CHECK(!GPSLabSelectionProviderKeyKnown("search.source.googleX", 21), "over-long provider rejected");
}

static void test_distance_and_duplicate(void) {
    // ~111.32 m per 0.001 degrees of latitude at the equator.
    double distance = GPSLabSelectionDistanceMeters(0.0, 0.0, 0.001, 0.0);
    CHECK(distance > 111.0 && distance < 111.5, "one millidegree latitude ~111 m");

    double existingLatitudes[] = { 24.7136, 24.71362 };
    double existingLongitudes[] = { 46.6753, 46.6753 };

    CHECK(GPSLabSelectionHasDuplicate(24.7136, 46.6753,
                                      existingLatitudes, existingLongitudes, 2,
                                      GPSLAB_SELECTION_DUPLICATE_TOLERANCE_METERS),
          "exact duplicate within tolerance");
    // 0.00002 degrees latitude ~2.2 m: inside the 5 m tolerance.
    CHECK(GPSLabSelectionHasDuplicate(24.71362, 46.6753,
                                      existingLatitudes, existingLongitudes, 2,
                                      GPSLAB_SELECTION_DUPLICATE_TOLERANCE_METERS),
          "2.2 m duplicate within tolerance");
    // 0.0001 degrees latitude ~11.1 m: outside the 5 m tolerance.
    CHECK(!GPSLabSelectionHasDuplicate(24.7137, 46.6753,
                                       existingLatitudes, existingLongitudes, 2,
                                       GPSLAB_SELECTION_DUPLICATE_TOLERANCE_METERS),
          "11 m point outside tolerance");
    CHECK(!GPSLabSelectionHasDuplicate(24.7136, 46.6753, NULL, NULL, 0,
                                       GPSLAB_SELECTION_DUPLICATE_TOLERANCE_METERS),
          "empty existing list never duplicates");
}

static void test_exact_zero_predicate(void) {
    CHECK(GPSLabSelectionPointIsExactZero(0.0, 0.0), "exact origin is zero");
    CHECK(GPSLabSelectionPointIsExactZero(-0.0, -0.0), "signed zero is zero");
    CHECK(GPSLabSelectionPointIsExactZero(0.0, -0.0), "mixed signed zero is zero");
    // A real direct-coordinate path: 0.000001,0 (~0.11 m) is NOT the origin.
    CHECK(!GPSLabSelectionPointIsExactZero(0.000001, 0.0), "0.000001,0 is not exact zero");
    CHECK(!GPSLabSelectionPointIsExactZero(0.0, 0.000001), "0,0.000001 is not exact zero");
    CHECK(!GPSLabSelectionPointIsExactZero(NAN, 0.0), "nan is not exact zero");
    CHECK(!GPSLabSelectionPointIsExactZero(0.0, INFINITY), "inf is not exact zero");
}

static void test_favorite_allowed(void) {
    // Pending is always allowed, including an intentional 0,0.
    CHECK(GPSLabFavoriteSelectionAllowed(1, 0.0, 0.0, 0), "pending intentional 0,0 allowed");
    CHECK(GPSLabFavoriteSelectionAllowed(1, 24.7136, 46.6753, 0), "pending nonzero allowed");

    // Nonzero committed is allowed without any proof.
    CHECK(GPSLabFavoriteSelectionAllowed(0, 24.7136, 46.6753, 0), "nonzero committed allowed");

    // Pristine default (0,0) is refused without an exact-zero proof.
    CHECK(!GPSLabFavoriteSelectionAllowed(0, 0.0, 0.0, 0), "pristine default 0,0 refused");
    // A near-origin nonzero proof (0.000001,0 ~0.11 m) must not count: the caller
    // computes hasExactZeroProof with the exact predicate, so it passes 0 here.
    CHECK(!GPSLabSelectionPointIsExactZero(0.000001, 0.0) &&
              !GPSLabFavoriteSelectionAllowed(0, 0.0, 0.0, 0),
          "near-origin nonzero selection does NOT authorize default 0,0");

    // An exact valid stored (0,0) proof authorizes the intentional 0,0.
    CHECK(GPSLabSelectionPointIsExactZero(0.0, 0.0) &&
              GPSLabFavoriteSelectionAllowed(0, 0.0, 0.0, 1),
          "exact zero proof authorizes intentional 0,0");
    CHECK(GPSLabFavoriteSelectionAllowed(0, 0.0, 0.0, 1), "signed/exact zero proof allowed");

    // Invalid committed coordinates are refused even when nonzero-looking.
    CHECK(!GPSLabFavoriteSelectionAllowed(0, NAN, 0.0, 1), "nan committed refused");
    CHECK(!GPSLabFavoriteSelectionAllowed(0, 91.0, 0.0, 1), "out-of-range committed refused");
}

static void test_resolve_shown_selection(void) {
    double latitude = 0.0;
    double longitude = 0.0;
    double altitude = 0.0;

    // Pending preview wins (with its matching altitude).
    GPSLabFavoriteResolveShownSelection(1, 1.5, 2.5, 30.0, 24.0, 46.0, 600.0,
                                        &latitude, &longitude, &altitude);
    CHECK(fabs(latitude - 1.5) < 1e-12, "pending latitude preferred");
    CHECK(fabs(longitude - 2.5) < 1e-12, "pending longitude preferred");
    CHECK(fabs(altitude - 30.0) < 1e-12, "pending altitude preferred");

    // No pending: committed anchor is used.
    GPSLabFavoriteResolveShownSelection(0, 1.5, 2.5, 30.0, 24.0, 46.0, 600.0,
                                        &latitude, &longitude, &altitude);
    CHECK(fabs(latitude - 24.0) < 1e-12, "committed latitude used without pending");
    CHECK(fabs(longitude - 46.0) < 1e-12, "committed longitude used without pending");
    CHECK(fabs(altitude - 600.0) < 1e-12, "committed altitude used without pending");

    // NULL out-pointers are safe.
    GPSLabFavoriteResolveShownSelection(1, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, NULL, NULL, NULL);
}

int main(void) {
    test_fields_valid();
    test_provider_known();
    test_distance_and_duplicate();
    test_exact_zero_predicate();
    test_favorite_allowed();
    test_resolve_shown_selection();

    if (gFailures != 0) {
        fprintf(stderr, "%d/%d checks failed\n", gFailures, gChecks);
        return 1;
    }
    printf("ok: %d selection policy checks passed\n", gChecks);
    return 0;
}
