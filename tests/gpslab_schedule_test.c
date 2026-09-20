/*
 * GPSLab schedule boundary-policy tests (portable C).
 *
 * The scheduler must be deterministic across foreground/background: if a due
 * instant was missed while the app was backgrounded, it skips when the window is
 * over and applies exactly once when the instant is still inside the window.
 * These exercise the exact Source/GPSLabProfileCore.c policy used at runtime.
 *
 * Build/run:
 *   cc -I Source tests/gpslab_schedule_test.c Source/GPSLabProfileCore.c -o schedule_test && ./schedule_test
 */

#include <stdio.h>

#include "GPSLabProfileCore.h"

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

static void test_once_overdue_policy(void) {
    const long long start = 1000000;
    // Foreground at the instant: apply once.
    CHECK(GPSLabProfileScheduleEvaluate(start, start, start, 0) == GPSLabProfileScheduleActionApply,
          "on time applies");
    // Backgrounded past the one-shot window: skip (expired), never apply late.
    CHECK(GPSLabProfileScheduleEvaluate(start, start, start + GPSLAB_PROFILE_ONCE_WINDOW_SECONDS + 1, 0)
              == GPSLabProfileScheduleActionExpired,
          "overdue one-shot is skipped");
    // Backgrounded but still inside the window: apply once.
    CHECK(GPSLabProfileScheduleEvaluate(start, start, start + 60, 0) == GPSLabProfileScheduleActionApply,
          "late but in-window applies once");
    // Already fired: never re-apply.
    CHECK(GPSLabProfileScheduleEvaluate(start, start, start + 60, 1) == GPSLabProfileScheduleActionWait,
          "fired once never repeats");
}

static void test_window_overdue_policy(void) {
    const long long start = 2000000;
    const long long end = start + 3600;
    CHECK(GPSLabProfileScheduleEvaluate(start, end, end - 1, 0) == GPSLabProfileScheduleActionApply,
          "just before window end applies");
    CHECK(GPSLabProfileScheduleEvaluate(start, end, end, 0) == GPSLabProfileScheduleActionExpired,
          "at window end expires");
    CHECK(GPSLabProfileScheduleEvaluate(start, end, end + 100000, 0) == GPSLabProfileScheduleActionExpired,
          "long past window expires");
}

static void test_monotonic_scan(void) {
    // A full scan from before start to after the window must produce exactly one
    // Apply and then only Expired — never Apply again.
    const long long start = 3000000;
    const long long end = start + 500;
    int applies = 0;
    int applied = 0;
    for (long long now = start - 1000; now <= end + 1000; now += 50) {
        GPSLabProfileScheduleAction action = GPSLabProfileScheduleEvaluate(start, end, now, applied);
        if (action == GPSLabProfileScheduleActionApply) {
            applies++;
            applied = 1;
        }
    }
    CHECK(applies == 1, "exactly one apply across the whole scan");
    // A fresh, unfired evaluation past the window must be Expired (skip policy).
    CHECK(GPSLabProfileScheduleEvaluate(start, end, end + 1000, 0)
              == GPSLabProfileScheduleActionExpired,
          "past window is expired when unfired");
}

static void test_gate_matrix(void) {
    int cases = 0;
    for (int engine = 0; engine <= 1; engine++) {
        for (int license = 0; license <= 1; license++) {
            for (int disabled = 0; disabled <= 1; disabled++) {
                int expected = (engine && license && !disabled) ? 1 : 0;
                CHECK(GPSLabProfileScheduleShouldApply(engine, license, disabled) == expected,
                      "gate matches engine && license && !manual-disable");
                cases++;
            }
        }
    }
    CHECK(cases == 8, "all eight gate combinations covered");
}

int main(void) {
    test_once_overdue_policy();
    test_window_overdue_policy();
    test_monotonic_scan();
    test_gate_matrix();

    if (gFailures == 0) {
        printf("gpslab_schedule_test: %d checks passed\n", gChecks);
        return 0;
    }
    fprintf(stderr, "gpslab_schedule_test: %d/%d checks failed\n", gFailures, gChecks);
    return 1;
}
