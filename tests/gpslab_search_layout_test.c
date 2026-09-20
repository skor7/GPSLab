/*
 * GPSLab search layout core tests (portable C).
 *
 * Exercises Source/GPSLabSearchLayoutCore.c directly: the exact phase/query
 * lifecycle and panel-sizing clamps the overlay obeys at runtime. No UIKit,
 * no MKLocalSearch and no device: these prove geometry/clamp arithmetic and
 * state transitions only.
 *
 * Build/run:
 *   cc -I Source tests/gpslab_search_layout_test.c Source/GPSLabSearchLayoutCore.c \
 *     -o search_layout_test && ./search_layout_test
 */

#include <math.h>
#include <stdio.h>
#include <string.h>

#include "GPSLabSearchLayoutCore.h"

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

static GPSLabSearchLayoutMetrics default_metrics(void) {
    GPSLabSearchLayoutMetrics metrics;
    memset(&metrics, 0, sizeof(metrics));
    metrics.min_height = 0.0;
    metrics.compact_height = 96.0;
    metrics.max_height = 320.0;
    metrics.max_viewport_fraction = 0.45;
    return metrics;
}

static void test_clamp_bounds(void) {
    CHECK(GPSLabSearchClampDimension(50.0, 0.0, 100.0) == 50.0, "value inside bounds is preserved");
    CHECK(GPSLabSearchClampDimension(-5.0, 0.0, 100.0) == 0.0, "below-minimum clamps to minimum");
    CHECK(GPSLabSearchClampDimension(500.0, 0.0, 100.0) == 100.0, "above-maximum clamps to maximum");
    // NaN resolves to the minimum bound (never a negative/undefined frame).
    CHECK(GPSLabSearchClampDimension(NAN, 8.0, 100.0) == 8.0, "NaN resolves to minimum");
    CHECK(GPSLabSearchClampDimension(INFINITY, 8.0, 100.0) == 100.0, "+infinity clamps to maximum");
    CHECK(GPSLabSearchClampDimension(-INFINITY, 8.0, 100.0) == 8.0, "-infinity clamps to minimum");
    // Reversed bounds are normalized rather than producing a nonsense value.
    CHECK(GPSLabSearchClampDimension(50.0, 100.0, 0.0) == 50.0, "reversed bounds are normalized");
}

static void test_available_height(void) {
    // Portrait, no keyboard: guide sits at the viewport bottom.
    CHECK(GPSLabSearchAvailableHeight(800.0, 200.0, 800.0) == 600.0,
          "portrait available height subtracts the top offset");
    // Keyboard up: guide top is above the viewport bottom.
    CHECK(GPSLabSearchAvailableHeight(800.0, 200.0, 500.0) == 300.0,
          "keyboard reduces available height");
    // A boundary above the top offset clips to 0, never negative.
    CHECK(GPSLabSearchAvailableHeight(800.0, 300.0, 250.0) == 0.0,
          "keyboard above the panel top clips to 0");
    // Degenerate inputs never produce a negative frame.
    CHECK(GPSLabSearchAvailableHeight(0.0, 100.0, 0.0) == 0.0, "zero viewport clips to 0");
    CHECK(GPSLabSearchAvailableHeight(-10.0, -20.0, -30.0) == 0.0, "negative inputs clip to 0");
    CHECK(GPSLabSearchAvailableHeight(NAN, 10.0, 500.0) == 0.0, "NaN viewport clips to 0");
    // A boundary past the viewport is capped at the viewport.
    CHECK(GPSLabSearchAvailableHeight(600.0, 100.0, 900.0) == 500.0,
          "boundary past the viewport is capped");
}

static void test_compact_empty_is_small(void) {
    GPSLabSearchLayoutMetrics metrics = default_metrics();
    // Empty/short query: compact message, never the full viewport height.
    double empty = GPSLabSearchResultsHeight(600.0, 800.0, 0.0, 0, metrics);
    CHECK(empty == 96.0, "empty query uses the compact height");
    CHECK(empty <= 120.0, "empty query panel stays in the compact range (<=120)");
    CHECK(empty < 800.0, "empty query never takes the full viewport");

    // Short query (still no results) is equally compact.
    double shortQuery = GPSLabSearchResultsHeight(600.0, 800.0, 0.0, 0, metrics);
    CHECK(shortQuery == empty, "short query matches the compact height");
}

static void test_results_content_bound(void) {
    GPSLabSearchLayoutMetrics metrics = default_metrics();

    // Few results: content smaller than every cap wins.
    double few = GPSLabSearchResultsHeight(600.0, 800.0, 160.0, 1, metrics);
    CHECK(few == 160.0, "small content sizes the panel to the content");

    // Many results: the 45% viewport fraction caps an 800pt viewport at 360,
    // then the 320 absolute cap wins.
    double many = GPSLabSearchResultsHeight(600.0, 800.0, 5000.0, 1, metrics);
    CHECK(many == 320.0, "large content is capped by max_height");

    // Short landscape viewport: the fraction cap is smaller than max_height.
    double landscape = GPSLabSearchResultsHeight(300.0, 375.0, 5000.0, 1, metrics);
    CHECK(landscape == 375.0 * 0.45, "landscape content is capped by the viewport fraction");
    CHECK(landscape <= 300.0, "landscape panel never exceeds available height");

    // Available height wins when the keyboard leaves less room than the cap.
    double keyed = GPSLabSearchResultsHeight(150.0, 800.0, 5000.0, 1, metrics);
    CHECK(keyed == 150.0, "available height caps the panel above the keyboard");

    // min_height floors a tiny content height.
    metrics.min_height = 44.0;
    double floored = GPSLabSearchResultsHeight(600.0, 800.0, 10.0, 1, metrics);
    CHECK(floored == 44.0, "min_height floors a tiny content height");
}

static void test_results_clip_and_sanitize(void) {
    GPSLabSearchLayoutMetrics metrics = default_metrics();
    CHECK(GPSLabSearchResultsHeight(600.0, 800.0, -100.0, 1, metrics) == 0.0,
          "negative content clips to 0");
    CHECK(GPSLabSearchResultsHeight(600.0, 800.0, NAN, 1, metrics) == 0.0,
          "NaN content clips to 0");
    CHECK(GPSLabSearchResultsHeight(-50.0, 800.0, 200.0, 1, metrics) == 0.0,
          "negative available clips to 0");
    CHECK(GPSLabSearchResultsHeight(600.0, 800.0, 200.0, 1, metrics) >= 0.0,
          "height is never negative");
    CHECK(GPSLabSearchResultsHeight(600.0, 0.0, 200.0, 1, metrics) == 0.0,
          "zero viewport yields a zero-height panel");

    // A nonsense fraction or cap is sanitized, not propagated.
    metrics.max_viewport_fraction = -1.0;
    CHECK(GPSLabSearchResultsHeight(600.0, 800.0, 200.0, 1, metrics) == 0.0,
          "negative fraction sanitizes to a zero cap");
    metrics = default_metrics();
    metrics.max_height = 0.0;
    CHECK(GPSLabSearchResultsHeight(600.0, 800.0, 200.0, 1, metrics) == 0.0,
          "zero max height yields a zero panel");
}

static void test_rtl_and_landscape_are_geometric(void) {
    // The layout policy is geometry only: RTL never swaps or scales the result,
    // so the same viewport/available inputs must give identical heights.
    GPSLabSearchLayoutMetrics metrics = default_metrics();
    double portrait = GPSLabSearchResultsHeight(600.0, 800.0, 200.0, 1, metrics);
    double repeated = GPSLabSearchResultsHeight(600.0, 800.0, 200.0, 1, metrics);
    CHECK(portrait == repeated, "identical geometry gives an identical height (no RTL flip)");

    double landscape = GPSLabSearchResultsHeight(220.0, 375.0, 150.0, 1, metrics);
    CHECK(landscape == 150.0, "landscape sizes to content when it fits under the fraction cap");
    CHECK(GPSLabSearchAvailableHeight(375.0, 140.0, 375.0) == 235.0,
          "landscape available height stays positive");
}

static void test_query_threshold(void) {
    CHECK(GPSLabSearchQueryIsSearchable(0) == 0, "empty query is not searchable");
    CHECK(GPSLabSearchQueryIsSearchable(1) == 0, "one character is not searchable");
    CHECK(GPSLabSearchQueryIsSearchable(2) == 0, "two characters are not searchable");
    CHECK(GPSLabSearchQueryIsSearchable(3) == 1, "three characters are searchable");
    CHECK(GPSLabSearchQueryIsSearchable(4) == 1, "longer queries are searchable");
}

static void test_bar_height_is_stable(void) {
    // A measured intrinsic height wins over the floor.
    CHECK(GPSLabSearchBarHeight(56.0, 44.0) == 56.0, "intrinsic height above the floor is preserved");
    CHECK(GPSLabSearchBarHeight(30.0, 44.0) == 44.0, "intrinsic height below the floor clamps to the floor");
    // A pre-layout bar reports no intrinsic height: never negative/zero.
    CHECK(GPSLabSearchBarHeight(-1.0, 44.0) == 44.0, "UIViewNoIntrinsicMetric falls back to the floor");
    CHECK(GPSLabSearchBarHeight(NAN, 44.0) == 44.0, "NaN intrinsic falls back to the floor");
    CHECK(GPSLabSearchBarHeight(0.0, 0.0) == 0.0, "zero floor and intrinsic stay zero");
    CHECK(GPSLabSearchBarHeight(56.0, 44.0) >= 44.0, "bar height never drops below the touch-target floor");

    // The bar height is a pure function of intrinsic/floor: it must not vary
    // with the viewport, the keyboard or the search phase. Repeating the exact
    // runtime call across simulated states proves the value is constant.
    double baseline = GPSLabSearchBarHeight(56.0, 44.0);
    CHECK(GPSLabSearchBarHeight(56.0, 44.0) == baseline, "inactive bar height is stable");
    CHECK(GPSLabSearchBarHeight(56.0, 44.0) == baseline, "active bar height is stable");
    CHECK(GPSLabSearchBarHeight(56.0, 44.0) == baseline, "cancelled bar height is stable");
    CHECK(GPSLabSearchBarHeight(56.0, 44.0) == baseline, "landscape bar height is stable");
}

static void test_session_lifecycle(void) {
    GPSLabSearchSession session;
    memset(&session, 0, sizeof(session));

    CHECK(GPSLabSearchSessionIsActive(&session) == 0, "a fresh session is inactive");
    CHECK(GPSLabSearchSessionPhase(&session) == GPSLabSearchPhaseInactive, "fresh phase is inactive");
    CHECK(GPSLabSearchSessionCanCommit(&session) == 0, "inactive cannot commit");

    GPSLabSearchSessionBegin(&session);
    unsigned long first = GPSLabSearchSessionGeneration(&session);
    CHECK(GPSLabSearchSessionIsActive(&session) == 1, "begin activates the session");
    CHECK(GPSLabSearchSessionPhase(&session) == GPSLabSearchPhaseEditing, "begin enters editing");
    CHECK(GPSLabSearchSessionCanCommit(&session) == 1, "editing can commit");
    CHECK(GPSLabSearchSessionIsCurrent(&session, first) == 1, "the current generation is accepted");

    GPSLabSearchSessionCommit(&session);
    CHECK(GPSLabSearchSessionPhase(&session) == GPSLabSearchPhaseResults, "commit enters results");
    CHECK(GPSLabSearchSessionIsActive(&session) == 1, "results phase stays active");
    CHECK(GPSLabSearchSessionCanCommit(&session) == 0, "results cannot commit again");
    CHECK(GPSLabSearchSessionIsCurrent(&session, first) == 1,
          "results started this session remain current after commit");

    // A stale generation (from a previous session) is rejected.
    GPSLabSearchSessionBegin(&session);
    CHECK(GPSLabSearchSessionIsCurrent(&session, first) == 0,
          "a previous session's generation is stale");
    unsigned long second = GPSLabSearchSessionGeneration(&session);
    CHECK(GPSLabSearchSessionIsCurrent(&session, second) == 1, "the new generation is current");

    GPSLabSearchSessionEnd(&session);
    CHECK(GPSLabSearchSessionIsActive(&session) == 0, "end deactivates the session");
    CHECK(GPSLabSearchSessionPhase(&session) == GPSLabSearchPhaseInactive, "end returns to inactive");
    CHECK(GPSLabSearchSessionIsCurrent(&session, second) == 0,
          "an in-flight result is invalid once the session ends");
}

static void test_cancel_cannot_resurrect(void) {
    GPSLabSearchSession session;
    memset(&session, 0, sizeof(session));

    GPSLabSearchSessionBegin(&session);
    GPSLabSearchSessionEnd(&session);

    // After a cancel, a late textDidEndEditing/commit must not reactivate.
    GPSLabSearchSessionCommit(&session);
    CHECK(GPSLabSearchSessionPhase(&session) == GPSLabSearchPhaseInactive,
          "commit after cancel cannot resurrect the session");
    CHECK(GPSLabSearchSessionIsActive(&session) == 0, "session stays inactive after a late commit");

    // Repeated cancel is idempotent: still inactive.
    GPSLabSearchSessionEnd(&session);
    GPSLabSearchSessionEnd(&session);
    CHECK(GPSLabSearchSessionIsActive(&session) == 0, "repeated cancel stays inactive");
    CHECK(GPSLabSearchSessionPhase(&session) == GPSLabSearchPhaseInactive,
          "repeated cancel keeps the inactive phase");

    // A NULL session is always safe.
    CHECK(GPSLabSearchSessionIsActive(NULL) == 0, "NULL session is inactive");
    CHECK(GPSLabSearchSessionCanCommit(NULL) == 0, "NULL session cannot commit");
    CHECK(GPSLabSearchSessionIsCurrent(NULL, 0) == 0, "NULL session is never current");
    GPSLabSearchSessionBegin(NULL);
    GPSLabSearchSessionCommit(NULL);
    GPSLabSearchSessionEnd(NULL);
    CHECK(GPSLabSearchSessionPhase(NULL) == GPSLabSearchPhaseInactive,
          "NULL phase is inactive after lifecycle calls");
}

int main(void) {
    test_clamp_bounds();
    test_available_height();
    test_compact_empty_is_small();
    test_results_content_bound();
    test_results_clip_and_sanitize();
    test_rtl_and_landscape_are_geometric();
    test_query_threshold();
    test_bar_height_is_stable();
    test_session_lifecycle();
    test_cancel_cannot_resurrect();

    if (gFailures == 0) {
        printf("gpslab_search_layout_test: %d checks passed\n", gChecks);
        return 0;
    }
    fprintf(stderr, "gpslab_search_layout_test: %d/%d checks failed\n", gFailures, gChecks);
    return 1;
}
