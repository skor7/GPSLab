//
//  GPSLabSchedulerCore.h
//  GPSLab
//
//  Pure C scheduler decision policy. Compiled into the dylib AND the portable
//  tests, so the exact rules the runtime obeys are testable without timers,
//  UIKit or a clock.
//
//  A "Wait" action carries a delay that is CLAMPED (never longer than one
//  bounded wake). A clamped wake is never itself the due event: the caller must
//  re-evaluate with the real clock on every wake. This is what prevents a
//  schedule more than one wake away from firing early, and a window end longer
//  than one wake away from stopping early.
//

#ifndef GPSLAB_SCHEDULER_CORE_H
#define GPSLAB_SCHEDULER_CORE_H

#include "GPSLabProfileCore.h"

#ifdef __cplusplus
extern "C" {
#endif

/** Longest single wait before a mandatory re-evaluation. */
#define GPSLAB_SCHEDULER_MAX_WAIT_SECONDS (24LL * 60LL * 60LL)

typedef enum {
    GPSLabSchedulerActionNone = 0,      /* nothing to do / not applicable */
    GPSLabSchedulerActionWait = 1,      /* schedule a bounded wake, then re-evaluate */
    GPSLabSchedulerActionFire = 2,      /* apply the profile now */
    GPSLabSchedulerActionWindowEnd = 3, /* stop the owned scheduled profile */
    GPSLabSchedulerActionCancel = 4,    /* expired / disarmed: clear pending work */
} GPSLabSchedulerAction;

typedef struct {
    int mode;              /* GPSLabProfileScheduleMode */
    long long startEpoch;  /* UTC seconds */
    long long endEpoch;    /* UTC seconds (== start for a one-shot) */
    long long now;         /* UTC seconds */
    int fired;             /* the profile has already been applied for this arm */
    int foreground;        /* the app is active */
    int engineEnabled;     /* the synthetic engine is currently enabled */
    int licenseUnlocked;   /* the entitlement currently allows synthesis */
    int manuallyDisabled;  /* the user explicitly disabled GPSLab */
    int ownerValid;        /* the applied profile is still owned by this scheduler */
} GPSLabSchedulerState;

/**
 * Decides the next action. `outDelaySeconds` receives the bounded wait (always
 * >= 1 and <= GPSLAB_SCHEDULER_MAX_WAIT_SECONDS) for a Wait action.
 */
GPSLabSchedulerAction GPSLabSchedulerNextAction(GPSLabSchedulerState state,
                                                long long *outDelaySeconds);

#ifdef __cplusplus
}
#endif

#endif /* GPSLAB_SCHEDULER_CORE_H */
