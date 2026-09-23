//
//  dylib_init.m
//  GPSLab
//
//  Dylib constructor: installs CoreLocation plus host-app-only environment
//  simulation interception exactly once and starts the lifecycle coordinator.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import "CoreLocationHooks.h"
#import "Diagnostics.h"
#import "GPSLabEngine.h"
#import "GPSLabLicenseManager.h"
#import "GPSLabRuntime.h"
#import "GPSLabSimulationRegistry.h"

__attribute__((constructor))
static void GPSLabDylibInitialize(void) {
    @autoreleasepool {
        GPSLabDiagDylibLoaded();

        [[GPSLabEngine sharedEngine] loadPersistedConfiguration];
        [[GPSLabLicenseManager sharedManager] loadAndStart];

        (void)[GPSLabCoreLocationHooks installHooks];
        (void)[GPSLabSimulationRegistry installRuntimeHooks];

        [[GPSLabRuntime sharedRuntime] install];
    }
}
