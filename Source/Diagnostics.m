//
//  Diagnostics.m
//  GPSLab
//
//  os_log-only diagnostics. No coordinates, identifiers, tokens, queries or errors.
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

void GPSLabDiagEngineEnabled(BOOL enabled) {
    os_log(GPSLabLogHandle(), "GPSLab engine enabled=%{public}d", enabled ? 1 : 0);
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

void GPSLabDiagLicenseCheckStarted(void) {
    os_log(GPSLabLogHandle(), "GPSLab license check started");
}

void GPSLabDiagLicenseStateChanged(NSInteger stateCode) {
    // Numeric code only: never an entitlement id, installation id or server message.
    os_log(GPSLabLogHandle(), "GPSLab license state=%{public}ld", (long)stateCode);
}

void GPSLabDiagInternalError(NSInteger code) {
    // Code-only: never log NSError.localizedDescription, queries or coordinates.
    os_log(GPSLabLogHandle(), "GPSLab internal error code=%{public}ld", (long)code);
}
