/*
 * GPSLab scheduler decision-policy tests (portable C).
 *
 * Exercises Source/GPSLabSchedulerCore.c directly — the exact policy used at
 * runtime. Every wait is bounded and must be re-evaluated with the real clock,
 * so a clamped wake can never fire early or stop a window early.
 *
 * Build/run:
 *   cc -I Source tests/gpslab_scheduler_test.c Source/GPSLabSchedulerCore.c \
 *     Source/GPSLabProfileCore.c -o scheduler_test && ./scheduler_test
 */

#include <stdio.h>

#include "GPSLabSchedulerCore.h"

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

static GPSLabSchedulerState base_state(void) {
    GPSLabSchedulerState state;
    state.mode = GPSLabProfileScheduleOnce;
    state.startEpoch = 0;
    state.endEpoch = 0;
    state.now = 0;
    state.fired = 0;
    state.foreground = 1;
    state.engineEnabled = 1;
    state.licenseUnlocked = 1;
    state.manuallyDisabled = 0;
    state.ownerValid = 0;
    return state;
}

static void test_far_future_is_wait_not_fire(void) {
    GPSLabSchedulerState state = base_state();
    state.startEpoch = 48LL * 3600LL;
    state.now = 0;
    long long delay = 0;
    CHECK(GPSLabSchedulerNextAction(state, &delay) == GPSLabSchedulerActionWait,
          "48h-away schedule waits");
    CHECK(delay == GPSLAB_SCHEDULER_MAX_WAIT_SECONDS, "wait is clamped to one bounded wake");

    // The clamped wake is NOT the due event: re-evaluating far from start waits.
    state.now = delay;
    CHECK(GPSLabSchedulerNextAction(state, &delay) == GPSLabSchedulerActionWait,
          "clamped wake re-evaluates and still waits");
    CHECK(delay == GPSLAB_SCHEDULER_MAX_WAIT_SECONDS, "second clamped wake");

    // Only when the real clock reaches the start does it fire.
    state.now = state.startEpoch;
    CHECK(GPSLabSchedulerNextAction(state, &delay) == GPSLabSchedulerActionFire,
          "fires at the real start");
}

static void test_background_suspends(void) {
    GPSLabSchedulerState state = base_state();
    state.startEpoch = 1000;
    state.now = 1000;
    state.foreground = 0;
    long long delay = 0;
    CHECK(GPSLabSchedulerNextAction(state, &delay) == GPSLabSchedulerActionNone,
          "background performs no work");
    CHECK(delay == 0, "no delay while backgrounded");
}

static void test_window_end_maintained(void) {
    GPSLabSchedulerState state = base_state();
    state.mode = GPSLabProfileScheduleWindow;
    state.startEpoch = 1000;
    state.endEpoch = 1000 + 48LL * 3600LL;
    state.fired = 1;
    state.ownerValid = 1;
    state.now = 1000;
    long long delay = 0;
    CHECK(GPSLabSchedulerNextAction(state, &delay) == GPSLabSchedulerActionWait,
          "owned window waits for its end");
    CHECK(delay == GPSLAB_SCHEDULER_MAX_WAIT_SECONDS, "window wait is clamped, not the end");

    // A long window must NOT stop early at the clamped wake.
    state.now = 1000 + GPSLAB_SCHEDULER_MAX_WAIT_SECONDS;
    CHECK(GPSLabSchedulerNextAction(state, &delay) == GPSLabSchedulerActionWait,
          "still waiting before the real window end");
    CHECK(delay == GPSLAB_SCHEDULER_MAX_WAIT_SECONDS, "re-clamped");

    state.now = state.endEpoch;
    CHECK(GPSLabSchedulerNextAction(state, &delay) == GPSLabSchedulerActionWindowEnd,
          "stops at the real window end");
}

static void test_one_shot_done_and_lost_owner(void) {
    GPSLabSchedulerState state = base_state();
    state.fired = 1;
    state.mode = GPSLabProfileScheduleOnce;
    state.ownerValid = 1;
    long long delay = 0;
    CHECK(GPSLabSchedulerNextAction(state, &delay) == GPSLabSchedulerActionNone,
          "fired one-shot is done");

    state.mode = GPSLabProfileScheduleWindow;
    state.endEpoch = state.now + 3600;
    state.ownerValid = 0;
    CHECK(GPSLabSchedulerNextAction(state, &delay) == GPSLabSchedulerActionNone,
          "lost ownership never stops anything");
}

static void test_manual_disable_and_gate(void) {
    GPSLabSchedulerState state = base_state();
    state.startEpoch = 1000;
    state.now = 1000;
    state.manuallyDisabled = 1;
    long long delay = 0;
    CHECK(GPSLabSchedulerNextAction(state, &delay) == GPSLabSchedulerActionCancel,
          "manual disable cancels");

    state.manuallyDisabled = 0;
    state.engineEnabled = 0;
    CHECK(GPSLabSchedulerNextAction(state, &delay) == GPSLabSchedulerActionWait,
          "in-window but engine off waits (never enables)");
    CHECK(delay > 0, "wait carries a positive delay");

    state.now = state.startEpoch + GPSLAB_PROFILE_ONCE_WINDOW_SECONDS + 1;
    CHECK(GPSLabSchedulerNextAction(state, &delay) == GPSLabSchedulerActionCancel,
          "missed window is skipped");

    state.licenseUnlocked = 0;
    state.now = state.startEpoch;
    CHECK(GPSLabSchedulerNextAction(state, &delay) == GPSLabSchedulerActionWait,
          "in-window but locked waits");
}

int main(void) {
    test_far_future_is_wait_not_fire();
    test_background_suspends();
    test_window_end_maintained();
    test_one_shot_done_and_lost_owner();
    test_manual_disable_and_gate();

    if (gFailures == 0) {
        printf("gpslab_scheduler_test: %d checks passed\n", gChecks);
        return 0;
    }
    fprintf(stderr, "gpslab_scheduler_test: %d/%d checks failed\n", gFailures, gChecks);
    return 1;
}
