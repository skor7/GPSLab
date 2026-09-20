//
//  GPSLabSchedulerCore.c
//  GPSLab
//

#include "GPSLabSchedulerCore.h"

static long long gpslab_scheduler_clamp_wait(long long value) {
    if (value < 1) {
        return 1;
    }
    if (value > GPSLAB_SCHEDULER_MAX_WAIT_SECONDS) {
        return GPSLAB_SCHEDULER_MAX_WAIT_SECONDS;
    }
    return value;
}

GPSLabSchedulerAction GPSLabSchedulerNextAction(GPSLabSchedulerState state,
                                                long long *outDelaySeconds) {
    if (outDelaySeconds != NULL) {
        *outDelaySeconds = 0;
    }

    // Foreground only: a suspended app performs no work.
    if (!state.foreground) {
        return GPSLabSchedulerActionNone;
    }

    if (state.fired) {
        // Maintain the window end only while the applied profile is still owned.
        if (state.mode == GPSLabProfileScheduleWindow && state.ownerValid) {
            if (state.now < state.endEpoch) {
                if (outDelaySeconds != NULL) {
                    *outDelaySeconds = gpslab_scheduler_clamp_wait(state.endEpoch - state.now);
                }
                return GPSLabSchedulerActionWait;
            }
            return GPSLabSchedulerActionWindowEnd;
        }
        return GPSLabSchedulerActionNone; // one-shot done, or ownership lost
    }

    if (state.manuallyDisabled) {
        return GPSLabSchedulerActionCancel;
    }
    if (state.startEpoch <= 0 || state.now < 0) {
        return GPSLabSchedulerActionCancel;
    }
    if (state.now < state.startEpoch) {
        if (outDelaySeconds != NULL) {
            *outDelaySeconds = gpslab_scheduler_clamp_wait(state.startEpoch - state.now);
        }
        return GPSLabSchedulerActionWait;
    }

    long long windowEnd = (state.endEpoch > state.startEpoch)
        ? state.endEpoch
        : GPSLabProfileSaturatingAdd(state.startEpoch, GPSLAB_PROFILE_ONCE_WINDOW_SECONDS);

    if (state.now >= windowEnd) {
        return GPSLabSchedulerActionCancel; // missed while suspended: skip, never late
    }
    if (state.engineEnabled && state.licenseUnlocked) {
        return GPSLabSchedulerActionFire;
    }
    // Inside the window but not allowed to apply (engine off / locked): wait and
    // re-evaluate. Never enable GPSLab automatically.
    if (outDelaySeconds != NULL) {
        *outDelaySeconds = gpslab_scheduler_clamp_wait(windowEnd - state.now);
    }
    return GPSLabSchedulerActionWait;
}
