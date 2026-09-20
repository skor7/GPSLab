//
//  GPSLabModalPolicy.h
//  GPSLab
//
//  Pure C policy for GPSLab-owned modal presentation. The Objective-C
//  coordinator maps live UIKit state into GPSLabModalPolicyState and obeys the
//  returned decision, so the queue/transition/search-gating rules are testable
//  without UIKit. No UIKit/Foundation dependency.
//

#ifndef GPSLAB_MODAL_POLICY_H
#define GPSLAB_MODAL_POLICY_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    /** Present immediately on the current anchor. */
    GPSLabModalDecisionPresent = 0,
    /** Search owns the presentation context: queue one bounded request and end search. */
    GPSLabModalDecisionDeferSearch,
    /** An untracked transition with a live coordinator: queue one and drain from its callback. */
    GPSLabModalDecisionWaitTransition,
    /** Refuse/ignore this request (duplicate, no session, no anchor, or a second sheet). */
    GPSLabModalDecisionDrop,
    /**
     * GPSLab's own transition is in flight: park one bounded request and let the
     * presenting/dismissing completion drain it. Never retries or registers an
     * untracked coordinator.
     */
    GPSLabModalDecisionParkForTrackedTransition,
} GPSLabModalDecision;

/** Snapshot of the live conditions relevant to a presentation request. */
typedef struct {
    /** The request's session generation is still the current one. */
    int session_valid;
    /** An anchor exists and is attached to a window. */
    int anchor_present;
    /** UISearchController is active or dismissing (not yet didDismiss). */
    int search_session_active;
    /** GPSLab itself is mid present/dismiss (self.transitioning). */
    int own_transition_active;
    /** `isBeingPresented`/`isBeingDismissed` is set on the anchor or its child. */
    int untracked_transition_active;
    /** The untracked transition exposes a `transitionCoordinator` we can hook. */
    int untracked_transition_hookable;
    /** The anchor is the GPSLab root controller (no modal presented). */
    int anchor_is_root;
    /** The request is a UIAlertController (allowed to stack on a sheet). */
    int is_alert;
    /** A bounded pending request is already queued. */
    int pending_present;
} GPSLabModalPolicyState;

/**
 * Decides how to handle a presentation request. Search gating is evaluated
 * BEFORE the single-sheet rule so a sheet requested while search is active is
 * deferred, never dropped as a second sheet. A tracked (GPSLab-owned) transition
 * parks; an untracked transition waits only when it is hookable, otherwise the
 * bounded request is dropped so no nil-coordinator retry loop can form.
 */
GPSLabModalDecision GPSLabModalPolicyDecidePresentation(const GPSLabModalPolicyState *state);

/**
 * Monotonic session generation. Every queued/completed action captures the
 * generation at request time; advancing the session invalidates stale work so a
 * closed/reopened overlay or a replaced root can never present.
 */
typedef struct {
    unsigned long generation;
} GPSLabModalSession;

void GPSLabModalSessionBegin(GPSLabModalSession *session);
void GPSLabModalSessionEnd(GPSLabModalSession *session);
/** Advances the generation without closing the session (root replacement). */
void GPSLabModalSessionInvalidate(GPSLabModalSession *session);
int GPSLabModalSessionIsCurrent(const GPSLabModalSession *session, unsigned long request_generation);

#ifdef __cplusplus
}
#endif

#endif /* GPSLAB_MODAL_POLICY_H */
