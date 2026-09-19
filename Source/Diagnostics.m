//
//  Diagnostics.m
//  GPSLab
//
//  os_log-only diagnostics. Coordinates, host data and real location are never logged.
//

#import "Diagnostics.h"

#import <os/log.h>

static os_log_t GPSLabLogHandle(void) {
    static os_log_t handle = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        handle = os_log_create("com.gpslab.runtime", "GPSLab");
    });
    return handle;
}

void GPSLabDiagDylibLoaded(void) {
    os_log(GPSLabLogHandle(), "GPSLab dylib loaded");
}

void GPSLabDiagHooksInstalled(int hookCount) {
    os_log(GPSLabLogHandle(), "GPSLab hooks installed count=%{public}d", hookCount);
}

void GPSLabDiagManagerRegistered(void) {
    os_log(GPSLabLogHandle(), "GPSLab manager registered");
}

void GPSLabDiagManagerUnregistered(void) {
    os_log(GPSLabLogHandle(), "GPSLab manager unregistered");
}

void GPSLabDiagSpoofActive(void) {
    os_log(GPSLabLogHandle(), "GPSLab synthetic engine active");
}

void GPSLabDiagEngineEnabled(BOOL enabled) {
    os_log(GPSLabLogHandle(), "GPSLab engine enabled=%{public}d", enabled ? 1 : 0);
}

void GPSLabDiagGeneratedLocation(void) {
    // Intentionally value-free: the synthetic coordinate is never logged.
    os_log(GPSLabLogHandle(), "GPSLab generated synthetic location");
}

void GPSLabDiagOverlayOpened(void) {
    os_log(GPSLabLogHandle(), "GPSLab overlay opened");
}

void GPSLabDiagOverlayClosed(void) {
    os_log(GPSLabLogHandle(), "GPSLab overlay closed");
}

void GPSLabDiagRouteStarted(void) {
    os_log(GPSLabLogHandle(), "GPSLab route started");
}

void GPSLabDiagRouteStopped(void) {
    os_log(GPSLabLogHandle(), "GPSLab route stopped");
}

void GPSLabDiagInternalError(NSInteger code) {
    // Code-only: never log NSError.localizedDescription, queries or coordinates,
    // all of which can contain user/host data. Codes have stable meanings that are
    // documented in README/TEST_PLAN.
    os_log(GPSLabLogHandle(), "GPSLab internal error code=%{public}ld", (long)code);
}
