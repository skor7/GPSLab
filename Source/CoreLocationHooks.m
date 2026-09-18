//
//  CoreLocationHooks.m
//  GPSLab
//
//  CoreLocation interception via the Objective-C runtime only.
//
//  Only selectors listed in the v0.1 specification are intercepted. Anything that
//  could trigger a system permission prompt or start real hardware updates is never
//  forwarded to the original implementation.
//

#import "CoreLocationHooks.h"

#import <CoreLocation/CoreLocation.h>
#import <objc/runtime.h>

#import "Diagnostics.h"
#import "GPSLabEngine.h"
#import "LocationStream.h"

static BOOL gGPSLabHooksInstalled = NO;

#pragma mark - Original implementations

static void (*gGPSLabOriginalSetDelegate)(id, SEL, id) = NULL;
static CLAuthorizationStatus (*gGPSLabOriginalAuthorizationStatusClass)(id, SEL) = NULL;
static CLAuthorizationStatus (*gGPSLabOriginalAuthorizationStatusInstance)(id, SEL) = NULL;
static NSInteger (*gGPSLabOriginalAccuracyAuthorization)(id, SEL) = NULL;
static BOOL (*gGPSLabOriginalLocationServicesEnabled)(id, SEL) = NULL;
static void (*gGPSLabOriginalDealloc)(id, SEL) = NULL;

#pragma mark - Replacements

static CLLocation *GPSLabHookLocation(id self, SEL _cmd) {
    (void)self;
    (void)_cmd;
    return [[GPSLabEngine sharedEngine] currentLocation];
}

static void GPSLabHookSetDelegate(id self, SEL _cmd, id delegate) {
    // Setting a delegate is inert and is required for synthetic delegate callbacks.
    if (gGPSLabOriginalSetDelegate != NULL) {
        gGPSLabOriginalSetDelegate(self, _cmd, delegate);
    }
}

static void GPSLabHookStartUpdatingLocation(id self, SEL _cmd) {
    (void)_cmd;
    [[GPSLabLocationStream sharedStream] startStandardUpdatesForManager:(CLLocationManager *)self];
}

static void GPSLabHookStopUpdatingLocation(id self, SEL _cmd) {
    (void)_cmd;
    [[GPSLabLocationStream sharedStream] stopStandardUpdatesForManager:(CLLocationManager *)self];
}

static void GPSLabHookRequestLocation(id self, SEL _cmd) {
    (void)_cmd;
    [[GPSLabLocationStream sharedStream] deliverSingleUpdateForManager:(CLLocationManager *)self];
}

static void GPSLabHookStartSignificantChanges(id self, SEL _cmd) {
    (void)_cmd;
    [[GPSLabLocationStream sharedStream] startSignificantUpdatesForManager:(CLLocationManager *)self];
}

static void GPSLabHookStopSignificantChanges(id self, SEL _cmd) {
    (void)_cmd;
    [[GPSLabLocationStream sharedStream] stopSignificantUpdatesForManager:(CLLocationManager *)self];
}

static CLAuthorizationStatus GPSLabHookAuthorizationStatusClass(id self, SEL _cmd) {
    (void)self;
    (void)_cmd;
    return kCLAuthorizationStatusAuthorizedAlways;
}

static CLAuthorizationStatus GPSLabHookAuthorizationStatusInstance(id self, SEL _cmd) {
    (void)self;
    (void)_cmd;
    return kCLAuthorizationStatusAuthorizedAlways;
}

static CLAccuracyAuthorization GPSLabHookAccuracyAuthorization(id self, SEL _cmd) {
    (void)self;
    (void)_cmd;
    return CLAccuracyAuthorizationFullAccuracy;
}

static BOOL GPSLabHookLocationServicesEnabled(id self, SEL _cmd) {
    (void)self;
    (void)_cmd;
    return YES;
}

static void GPSLabHookRequestWhenInUseAuthorization(id self, SEL _cmd) {
    (void)_cmd;
    [[GPSLabLocationStream sharedStream] notifyAuthorizationGrantedForManager:(CLLocationManager *)self];
}

static void GPSLabHookRequestAlwaysAuthorization(id self, SEL _cmd) {
    (void)_cmd;
    [[GPSLabLocationStream sharedStream] notifyAuthorizationGrantedForManager:(CLLocationManager *)self];
}

static void GPSLabHookDealloc(id self, SEL _cmd) {
    [[GPSLabLocationStream sharedStream] unregisterManager:(CLLocationManager *)self];
    if (gGPSLabOriginalDealloc != NULL) {
        gGPSLabOriginalDealloc(self, _cmd);
    }
}

#pragma mark - Runtime helpers

static BOOL GPSLabSwizzleInstance(Class cls, SEL selector, IMP replacement, void **originalOut) {
    Method method = class_getInstanceMethod(cls, selector);
    if (method == NULL) {
        return NO;
    }
    if (originalOut != NULL) {
        *originalOut = method_getImplementation(method);
    }
    (void)class_replaceMethod(cls, selector, replacement, method_getTypeEncoding(method));
    return YES;
}

static BOOL GPSLabSwizzleClassMethod(Class cls, SEL selector, IMP replacement, void **originalOut) {
    Method method = class_getClassMethod(cls, selector);
    if (method == NULL) {
        return NO;
    }
    if (originalOut != NULL) {
        *originalOut = method_getImplementation(method);
    }
    (void)class_replaceMethod(object_getClass(cls), selector, replacement, method_getTypeEncoding(method));
    return YES;
}

#pragma mark - Installation

@implementation GPSLabCoreLocationHooks

+ (BOOL)installHooks {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class managerClass = [CLLocationManager class];
        int installed = 0;

        // Instance methods.
        installed += GPSLabSwizzleInstance(managerClass,
                                           @selector(location),
                                           (IMP)GPSLabHookLocation,
                                           NULL) ? 1 : 0;
        installed += GPSLabSwizzleInstance(managerClass,
                                           @selector(setDelegate:),
                                           (IMP)GPSLabHookSetDelegate,
                                           (void **)&gGPSLabOriginalSetDelegate) ? 1 : 0;
        installed += GPSLabSwizzleInstance(managerClass,
                                           @selector(startUpdatingLocation),
                                           (IMP)GPSLabHookStartUpdatingLocation,
                                           NULL) ? 1 : 0;
        installed += GPSLabSwizzleInstance(managerClass,
                                           @selector(stopUpdatingLocation),
                                           (IMP)GPSLabHookStopUpdatingLocation,
                                           NULL) ? 1 : 0;
        installed += GPSLabSwizzleInstance(managerClass,
                                           @selector(requestLocation),
                                           (IMP)GPSLabHookRequestLocation,
                                           NULL) ? 1 : 0;
        installed += GPSLabSwizzleInstance(managerClass,
                                           @selector(startMonitoringSignificantLocationChanges),
                                           (IMP)GPSLabHookStartSignificantChanges,
                                           NULL) ? 1 : 0;
        installed += GPSLabSwizzleInstance(managerClass,
                                           @selector(stopMonitoringSignificantLocationChanges),
                                           (IMP)GPSLabHookStopSignificantChanges,
                                           NULL) ? 1 : 0;
        installed += GPSLabSwizzleInstance(managerClass,
                                           @selector(requestWhenInUseAuthorization),
                                           (IMP)GPSLabHookRequestWhenInUseAuthorization,
                                           NULL) ? 1 : 0;
        installed += GPSLabSwizzleInstance(managerClass,
                                           @selector(requestAlwaysAuthorization),
                                           (IMP)GPSLabHookRequestAlwaysAuthorization,
                                           NULL) ? 1 : 0;
        installed += GPSLabSwizzleInstance(managerClass,
                                           @selector(dealloc),
                                           (IMP)GPSLabHookDealloc,
                                           (void **)&gGPSLabOriginalDealloc) ? 1 : 0;

        // `-authorizationStatus` and `-accuracyAuthorization` only exist on newer
        // systems (both are present on iOS 16, but the runtime check keeps this
        // safe and warning-free if that ever changes).
        installed += GPSLabSwizzleInstance(managerClass,
                                           @selector(authorizationStatus),
                                           (IMP)GPSLabHookAuthorizationStatusInstance,
                                           (void **)&gGPSLabOriginalAuthorizationStatusInstance) ? 1 : 0;
        installed += GPSLabSwizzleInstance(managerClass,
                                           @selector(accuracyAuthorization),
                                           (IMP)GPSLabHookAccuracyAuthorization,
                                           (void **)&gGPSLabOriginalAccuracyAuthorization) ? 1 : 0;

        // Class methods.
        installed += GPSLabSwizzleClassMethod(managerClass,
                                              @selector(authorizationStatus),
                                              (IMP)GPSLabHookAuthorizationStatusClass,
                                              (void **)&gGPSLabOriginalAuthorizationStatusClass) ? 1 : 0;
        installed += GPSLabSwizzleClassMethod(managerClass,
                                              @selector(locationServicesEnabled),
                                              (IMP)GPSLabHookLocationServicesEnabled,
                                              (void **)&gGPSLabOriginalLocationServicesEnabled) ? 1 : 0;

        gGPSLabHooksInstalled = YES;
        GPSLabDiagHooksInstalled(installed);
    });

    return gGPSLabHooksInstalled;
}

+ (BOOL)areHooksInstalled {
    return gGPSLabHooksInstalled;
}

@end
