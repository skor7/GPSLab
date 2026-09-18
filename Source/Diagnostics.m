//
//  Diagnostics.m
//  GPSLab
//
//  os_log-only diagnostics. No real (user) data is ever logged.
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

void GPSLabDiagSpoofActive(double latitude, double longitude, double altitude) {
    os_log(GPSLabLogHandle(),
           "GPSLab spoof active anchor lat=%{public}.6f lon=%{public}.6f alt=%{public}.2f",
           latitude,
           longitude,
           altitude);
}

void GPSLabDiagGeneratedCoordinate(double latitude, double longitude, double altitude) {
    os_log(GPSLabLogHandle(),
           "GPSLab generated coordinate lat=%{public}.6f lon=%{public}.6f alt=%{public}.2f",
           latitude,
           longitude,
           altitude);
}
