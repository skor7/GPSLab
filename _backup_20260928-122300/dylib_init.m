//
//  dylib_init.m
//  GPSLab
//
//  Dylib constructor: installs the process-wide Keychain access-group hook,
//  CoreLocation plus host-app-only environment simulation interception exactly
//  once and starts the lifecycle coordinator.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import "CoreLocationHooks.h"
#import "Diagnostics.h"
#import "GPSLabEngine.h"
#import "GPSLabKeychainCompat.h"
#import "GPSLabLicenseManager.h"
#import "GPSLabRuntime.h"
#import "GPSLabSimulationRegistry.h"

__attribute__((constructor))
static void GPSLabDylibInitialize(void) {
    @autoreleasepool {
        GPSLabDiagDylibLoaded();

        // Install the process-wide Keychain access-group compatibility hook
        // BEFORE the license manager touches the Keychain. Unconditional and
        // exactly-once (the standalone KeychainFix semantics, never gated by the
        // synthetic-engine switch or the license state).
        (void)GPSLabKeychainCompatInstall();

        [[GPSLabEngine sharedEngine] loadPersistedConfiguration];
        [[GPSLabLicenseManager sharedManager] loadAndStart];

        (void)[GPSLabCoreLocationHooks installHooks];
        (void)[GPSLabSimulationRegistry installRuntimeHooks];

        [[GPSLabRuntime sharedRuntime] install];
    }
}
