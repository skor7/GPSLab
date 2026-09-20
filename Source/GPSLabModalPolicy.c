//
//  GPSLabModalPolicy.c
//  GPSLab
//
//  Pure C modal decision + session generation policy. Compiled into the dylib
//  and into the portable CI test.
//

#include "GPSLabModalPolicy.h"

GPSLabModalDecision GPSLabModalPolicyDecidePresentation(const GPSLabModalPolicyState *state) {
    if (state == NULL) {
        return GPSLabModalDecisionDrop;
    }
    if (!state->session_valid) {
        return GPSLabModalDecisionDrop;
    }
    if (!state->anchor_present) {
        return GPSLabModalDecisionDrop;
    }

    // Search owns the presentation context first: never let the single-sheet
    // rule misread the search results controller as "a sheet is already up".
    if (state->search_session_active) {
        return state->pending_present ? GPSLabModalDecisionDrop : GPSLabModalDecisionDeferSearch;
    }

    // GPSLab's own transition: park one bounded request; our present/dismiss
    // completion drains it. Never register an untracked coordinator or retry.
    if (state->own_transition_active) {
        return state->pending_present ? GPSLabModalDecisionDrop
                                      : GPSLabModalDecisionParkForTrackedTransition;
    }

    // An untracked/interactive transition. Only a live coordinator gives us a
    // safe drain event; otherwise drop the bounded request (never retry on a
    // nil coordinator, which would recurse).
    if (state->untracked_transition_active) {
        if (state->pending_present) {
            return GPSLabModalDecisionDrop;
        }
        return state->untracked_transition_hookable ? GPSLabModalDecisionWaitTransition
                                                    : GPSLabModalDecisionDrop;
    }

    // At most one GPSLab sheet; alerts may stack on the active topmost.
    if (!state->is_alert && !state->anchor_is_root) {
        return GPSLabModalDecisionDrop;
    }

    return GPSLabModalDecisionPresent;
}

void GPSLabModalSessionBegin(GPSLabModalSession *session) {
    if (session != NULL) {
        session->generation += 1;
    }
}

void GPSLabModalSessionEnd(GPSLabModalSession *session) {
    if (session != NULL) {
        session->generation += 1;
    }
}

void GPSLabModalSessionInvalidate(GPSLabModalSession *session) {
    if (session != NULL) {
        session->generation += 1;
    }
}

int GPSLabModalSessionIsCurrent(const GPSLabModalSession *session, unsigned long request_generation) {
    if (session == NULL) {
        return 0;
    }
    return session->generation == request_generation ? 1 : 0;
}
