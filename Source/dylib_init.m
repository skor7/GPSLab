//
//  dylib_init.m
//  GPSLab
//
//  Dylib constructor: installs the CoreLocation interception exactly once.
//

#import <Foundation/Foundation.h>

#import <CoreLocation/CoreLocation.h>

#import "CoreLocationHooks.h"
#import "Diagnostics.h"
#import "GPSLabEngine.h"

__attribute__((constructor))
static void GPSLabDylibInitialize(void) {
    @autoreleasepool {
        GPSLabDiagDylibLoaded();

        if ([GPSLabCoreLocationHooks installHooks]) {
            CLLocation *anchor = [[GPSLabEngine sharedEngine] currentLocation];
            GPSLabDiagSpoofActive(anchor.coordinate.latitude,
                                  anchor.coordinate.longitude,
                                  anchor.altitude);
        }
    }
}
