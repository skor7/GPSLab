//
//  dylib_init.m
//  GPSLab
//
//  Dylib constructor: installs the CoreLocation interception exactly once and
//  starts the lifecycle coordinator once UIKit is ready.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import "CoreLocationHooks.h"
#import "Diagnostics.h"
#import "GPSLabEngine.h"
#import "GPSLabLicenseManager.h"
#import "GPSLabRuntime.h"

__attribute__((constructor))
static void GPSLabDylibInitialize(void) {
    @autoreleasepool {
        GPSLabDiagDylibLoaded();

        // Restore the persisted allow-listed configuration before hooks go live.
        [[GPSLabEngine sharedEngine] loadPersistedConfiguration];

        // Resolve the signed entitlement (verified Keychain cache first, then a bounded
        // network refresh). This applies the fail-closed gate before any hook can run.
        [[GPSLabLicenseManager sharedManager] loadAndStart];

        (void)[GPSLabCoreLocationHooks installHooks];

        // The overlay must only be installed after the app is ready; the runtime
        // observes UIApplication/scene notifications and attaches then.
        [[GPSLabRuntime sharedRuntime] install];
    }
}
