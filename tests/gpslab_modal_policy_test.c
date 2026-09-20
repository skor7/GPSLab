/*
 * GPSLab modal policy tests (portable C).
 *
 * Exercises Source/GPSLabModalPolicy.c directly: the exact decision and session
 * generation rules the coordinator obeys at runtime, including the tracked vs
 * untracked transition branches that must never form a synchronous retry loop.
 * No UIKit/Foundation.
 *
 * Build/run:
 *   cc -I Source tests/gpslab_modal_policy_test.c Source/GPSLabModalPolicy.c -o modal_test && ./modal_test
 */

#include <stdio.h>
#include <string.h>

#include "GPSLabModalPolicy.h"

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

static GPSLabModalPolicyState baseline(void) {
    GPSLabModalPolicyState state;
    memset(&state, 0, sizeof(state));
    state.session_valid = 1;
    state.anchor_present = 1;
    state.anchor_is_root = 1;
    return state;
}

static void test_present_baseline(void) {
    GPSLabModalPolicyState state = baseline();
    CHECK(GPSLabModalPolicyDecidePresentation(&state) == GPSLabModalDecisionPresent,
          "clean root state presents");
}

static void test_session_and_anchor_refusals(void) {
    GPSLabModalPolicyState state = baseline();
    state.session_valid = 0;
    CHECK(GPSLabModalPolicyDecidePresentation(&state) == GPSLabModalDecisionDrop,
          "stale session is dropped");

    state = baseline();
    state.anchor_present = 0;
    CHECK(GPSLabModalPolicyDecidePresentation(&state) == GPSLabModalDecisionDrop,
          "missing anchor is dropped");

    CHECK(GPSLabModalPolicyDecidePresentation(NULL) == GPSLabModalDecisionDrop,
          "NULL state is dropped");
}

static void test_search_gating_before_sheet_rule(void) {
    GPSLabModalPolicyState state = baseline();
    state.search_session_active = 1;
    CHECK(GPSLabModalPolicyDecidePresentation(&state) == GPSLabModalDecisionDeferSearch,
          "search active defers");

    // A sheet requested during search has anchor != root; search must win.
    state.anchor_is_root = 0;
    CHECK(GPSLabModalPolicyDecidePresentation(&state) == GPSLabModalDecisionDeferSearch,
          "search gating precedes the single-sheet rule");

    state.pending_present = 1;
    CHECK(GPSLabModalPolicyDecidePresentation(&state) == GPSLabModalDecisionDrop,
          "duplicate request during search is dropped (bounded one)");

    // Search wins over transitions too.
    state = baseline();
    state.search_session_active = 1;
    state.own_transition_active = 1;
    state.untracked_transition_active = 1;
    state.untracked_transition_hookable = 1;
    CHECK(GPSLabModalPolicyDecidePresentation(&state) == GPSLabModalDecisionDeferSearch,
          "search gating precedes both transition branches");
}

static void test_tracked_transition_parks(void) {
    GPSLabModalPolicyState state = baseline();
    state.own_transition_active = 1;
    CHECK(GPSLabModalPolicyDecidePresentation(&state) ==
              GPSLabModalDecisionParkForTrackedTransition,
          "tracked transition parks (never retries or registers a coordinator)");

    state.pending_present = 1;
    CHECK(GPSLabModalPolicyDecidePresentation(&state) == GPSLabModalDecisionDrop,
          "duplicate during tracked transition is dropped (bounded one)");

    // Tracked wins over untracked signals.
    state = baseline();
    state.own_transition_active = 1;
    state.untracked_transition_active = 1;
    state.untracked_transition_hookable = 1;
    CHECK(GPSLabModalPolicyDecidePresentation(&state) ==
              GPSLabModalDecisionParkForTrackedTransition,
          "tracked transition takes precedence over untracked");
}

static void test_untracked_transition_branches(void) {
    // Hookable: wait for the coordinator callback.
    GPSLabModalPolicyState state = baseline();
    state.untracked_transition_active = 1;
    state.untracked_transition_hookable = 1;
    CHECK(GPSLabModalPolicyDecidePresentation(&state) == GPSLabModalDecisionWaitTransition,
          "hookable untracked transition waits");

    state.pending_present = 1;
    CHECK(GPSLabModalPolicyDecidePresentation(&state) == GPSLabModalDecisionDrop,
          "duplicate during hookable untracked transition is dropped");

    // Not hookable (flag set, coordinator nil): drop, never retry immediately.
    state = baseline();
    state.untracked_transition_active = 1;
    state.untracked_transition_hookable = 0;
    CHECK(GPSLabModalPolicyDecidePresentation(&state) == GPSLabModalDecisionDrop,
          "untracked transition without a coordinator is dropped, not retried");

    state.pending_present = 1;
    CHECK(GPSLabModalPolicyDecidePresentation(&state) == GPSLabModalDecisionDrop,
          "duplicate without a coordinator is still dropped");
}

static void test_single_sheet_and_alerts(void) {
    GPSLabModalPolicyState state = baseline();
    state.anchor_is_root = 0;
    CHECK(GPSLabModalPolicyDecidePresentation(&state) == GPSLabModalDecisionDrop,
          "second sheet is dropped");

    state.is_alert = 1;
    CHECK(GPSLabModalPolicyDecidePresentation(&state) == GPSLabModalDecisionPresent,
          "alert may stack on the active topmost");
}

static void test_session_generation(void) {
    GPSLabModalSession session;
    memset(&session, 0, sizeof(session));

    GPSLabModalSessionBegin(&session);
    unsigned long first = session.generation;
    CHECK(GPSLabModalSessionIsCurrent(&session, first) == 1, "request in current session is valid");

    GPSLabModalSessionInvalidate(&session);
    CHECK(GPSLabModalSessionIsCurrent(&session, first) == 0,
          "root replacement invalidates stale requests");
    unsigned long afterInvalidate = session.generation;
    CHECK(GPSLabModalSessionIsCurrent(&session, afterInvalidate) == 1,
          "new request after invalidation is valid");

    GPSLabModalSessionEnd(&session);
    CHECK(GPSLabModalSessionIsCurrent(&session, afterInvalidate) == 0,
          "session close invalidates stale requests");

    GPSLabModalSessionBegin(&session);
    CHECK(GPSLabModalSessionIsCurrent(&session, afterInvalidate) == 0,
          "reopened session keeps stale requests invalid");
    CHECK(GPSLabModalSessionIsCurrent(&session, session.generation) == 1,
          "reopened session accepts new requests");

    CHECK(GPSLabModalSessionIsCurrent(NULL, 0) == 0, "NULL session is never current");
}

int main(void) {
    test_present_baseline();
    test_session_and_anchor_refusals();
    test_search_gating_before_sheet_rule();
    test_tracked_transition_parks();
    test_untracked_transition_branches();
    test_single_sheet_and_alerts();
    test_session_generation();

    if (gFailures == 0) {
        printf("gpslab_modal_policy_test: %d checks passed\n", gChecks);
        return 0;
    }
    fprintf(stderr, "gpslab_modal_policy_test: %d/%d checks failed\n", gFailures, gChecks);
    return 1;
}
