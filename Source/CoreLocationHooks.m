//
//  CoreLocationHooks.m
//  GPSLab
//
//  CoreLocation interception via the Objective-C runtime only.
//
//  GPSLab links no third-party method-interception framework of any kind. Only the
//  public Objective-C runtime and public CoreLocation APIs are used.
//
//  Every intercepted selector captures its original IMP. When the engine is disabled
//  - or when the specific manager is bypassed - the hook forwards to that original,
//  so the host genuinely gets CoreLocation behavior back. No call is silently dropped.
//

#import "CoreLocationHooks.h"

#import <CoreLocation/CoreLocation.h>
#import <objc/runtime.h>

#import "Diagnostics.h"
#import "GPSLabEngine.h"
#import "LocationStream.h"

static BOOL gGPSLabHooksInstalled = NO;
static char kGPSLabBypassKey;

#pragma mark - Original implementations

static CLLocation *(*gGPSLabOriginalLocation)(id, SEL) = NULL;
static void (*gGPSLabOriginalSetDelegate)(id, SEL, id) = NULL;
static void (*gGPSLabOriginalStartUpdatingLocation)(id, SEL) = NULL;
static void (*gGPSLabOriginalStopUpdatingLocation)(id, SEL) = NULL;
static void (*gGPSLabOriginalRequestLocation)(id, SEL) = NULL;
static void (*gGPSLabOriginalStartSignificant)(id, SEL) = NULL;
static void (*gGPSLabOriginalStopSignificant)(id, SEL) = NULL;
static void (*gGPSLabOriginalRequestWhenInUse)(id, SEL) = NULL;
static void (*gGPSLabOriginalRequestAlways)(id, SEL) = NULL;
static CLAuthorizationStatus (*gGPSLabOriginalAuthorizationStatusClass)(id, SEL) = NULL;
static CLAuthorizationStatus (*gGPSLabOriginalAuthorizationStatusInstance)(id, SEL) = NULL;
static CLAccuracyAuthorization (*gGPSLabOriginalAccuracyAuthorization)(id, SEL) = NULL;
static BOOL (*gGPSLabOriginalLocationServicesEnabled)(id, SEL) = NULL;

#pragma mark - Bypass state

static BOOL GPSLabIsBypassedManager(CLLocationManager *manager) {
    if (manager == nil) {
        return NO;
    }
    return [objc_getAssociatedObject(manager, &kGPSLabBypassKey) boolValue];
}

#pragma mark - Helpers

static BOOL GPSLabEngineIsEnabled(void) {
    return [[GPSLabEngine sharedEngine] isEnabled];
}

// A hook should produce synthetic output only when the engine is on and this specific
// manager is not bypassed.
static BOOL GPSLabShouldSynthesize(CLLocationManager *manager) {
    return GPSLabEngineIsEnabled() && !GPSLabIsBypassedManager(manager);
}

#pragma mark - Replacements

static CLLocation *GPSLabHookLocation(id self, SEL _cmd) {
    if (gGPSLabOriginalLocation == NULL) {
        return nil;
    }
    if (!GPSLabShouldSynthesize((CLLocationManager *)self)) {
        return gGPSLabOriginalLocation(self, _cmd);
    }
    return [[GPSLabEngine sharedEngine] currentLocation];
}

static void GPSLabHookSetDelegate(id self, SEL _cmd, id delegate) {
    // Always forward: the delegate assignment must keep working normally.
    if (gGPSLabOriginalSetDelegate != NULL) {
        gGPSLabOriginalSetDelegate(self, _cmd, delegate);
    }
}

static void GPSLabHookStartUpdatingLocation(id self, SEL _cmd) {
    CLLocationManager *manager = (CLLocationManager *)self;
    // Record the host's intent first. The stream starts synthetic delivery only when
    // the engine is enabled (and this manager is not bypassed); the intent is kept
    // even while disabled so a later enable/foreground can resume it.
    [[GPSLabLocationStream sharedStream] requestStandardForManager:manager];
    if (!GPSLabShouldSynthesize(manager)) {
        // Disabled or bypassed: real CoreLocation must handle the call.
        if (gGPSLabOriginalStartUpdatingLocation != NULL) {
            gGPSLabOriginalStartUpdatingLocation(self, _cmd);
        }
    }
}

static void GPSLabHookStopUpdatingLocation(id self, SEL _cmd) {
    CLLocationManager *manager = (CLLocationManager *)self;
    // Always clear the recorded intent, then always stop the original too: it may
    // have been started while disabled/bypassed.
    [[GPSLabLocationStream sharedStream] cancelStandardForManager:manager];
    if (gGPSLabOriginalStopUpdatingLocation != NULL) {
        gGPSLabOriginalStopUpdatingLocation(self, _cmd);
    }
}

static void GPSLabHookRequestLocation(id self, SEL _cmd) {
    CLLocationManager *manager = (CLLocationManager *)self;
    if (!GPSLabShouldSynthesize(manager)) {
        if (gGPSLabOriginalRequestLocation != NULL) {
            gGPSLabOriginalRequestLocation(self, _cmd);
        }
        return;
    }
    [[GPSLabLocationStream sharedStream] deliverSingleUpdateForManager:manager];
}

static void GPSLabHookStartSignificantChanges(id self, SEL _cmd) {
    CLLocationManager *manager = (CLLocationManager *)self;
    // Intent is recorded before the enable/bypass decision, mirroring standard updates.
    [[GPSLabLocationStream sharedStream] requestSignificantForManager:manager];
    if (!GPSLabShouldSynthesize(manager)) {
        if (gGPSLabOriginalStartSignificant != NULL) {
            gGPSLabOriginalStartSignificant(self, _cmd);
        }
    }
}

static void GPSLabHookStopSignificantChanges(id self, SEL _cmd) {
    CLLocationManager *manager = (CLLocationManager *)self;
    [[GPSLabLocationStream sharedStream] cancelSignificantForManager:manager];
    if (gGPSLabOriginalStopSignificant != NULL) {
        gGPSLabOriginalStopSignificant(self, _cmd);
    }
}

static CLAuthorizationStatus GPSLabHookAuthorizationStatusClass(id self, SEL _cmd) {
    if (gGPSLabOriginalAuthorizationStatusClass != NULL && !GPSLabEngineIsEnabled()) {
        return gGPSLabOriginalAuthorizationStatusClass(self, _cmd);
    }
    return kCLAuthorizationStatusAuthorizedAlways;
}

static CLAuthorizationStatus GPSLabHookAuthorizationStatusInstance(id self, SEL _cmd) {
    if (!GPSLabShouldSynthesize((CLLocationManager *)self) &&
        gGPSLabOriginalAuthorizationStatusInstance != NULL) {
        return gGPSLabOriginalAuthorizationStatusInstance(self, _cmd);
    }
    return kCLAuthorizationStatusAuthorizedAlways;
}

static CLAccuracyAuthorization GPSLabHookAccuracyAuthorization(id self, SEL _cmd) {
    if (!GPSLabShouldSynthesize((CLLocationManager *)self) &&
        gGPSLabOriginalAccuracyAuthorization != NULL) {
        return gGPSLabOriginalAccuracyAuthorization(self, _cmd);
    }
    return CLAccuracyAuthorizationFullAccuracy;
}

static BOOL GPSLabHookLocationServicesEnabled(id self, SEL _cmd) {
    if (!GPSLabEngineIsEnabled() && gGPSLabOriginalLocationServicesEnabled != NULL) {
        return gGPSLabOriginalLocationServicesEnabled(self, _cmd);
    }
    return YES;
}

static void GPSLabHookRequestWhenInUseAuthorization(id self, SEL _cmd) {
    CLLocationManager *manager = (CLLocationManager *)self;
    if (!GPSLabShouldSynthesize(manager)) {
        if (gGPSLabOriginalRequestWhenInUse != NULL) {
            gGPSLabOriginalRequestWhenInUse(self, _cmd);
        }
        return;
    }
    [[GPSLabLocationStream sharedStream] notifyAuthorizationGrantedForManager:manager];
}

static void GPSLabHookRequestAlwaysAuthorization(id self, SEL _cmd) {
    CLLocationManager *manager = (CLLocationManager *)self;
    if (!GPSLabShouldSynthesize(manager)) {
        if (gGPSLabOriginalRequestAlways != NULL) {
            gGPSLabOriginalRequestAlways(self, _cmd);
        }
        return;
    }
    [[GPSLabLocationStream sharedStream] notifyAuthorizationGrantedForManager:manager];
}

#pragma mark - Runtime helpers

// Swizzles and stores the previous IMP so the hook can always forward.
static BOOL GPSLabSwizzleInstanceCapturingOriginal(Class cls,
                                                   SEL selector,
                                                   IMP replacement,
                                                   void **originalOut) {
    Method method = class_getInstanceMethod(cls, selector);
    if (method == NULL) {
        return NO;
    }
    IMP original = method_getImplementation(method);
    if (original == replacement) {
        // Already installed by this image; the previously captured IMP is kept.
        return YES;
    }
    if (originalOut != NULL && *originalOut == NULL) {
        *originalOut = (void *)original;
    }
    (void)class_replaceMethod(cls, selector, replacement, method_getTypeEncoding(method));
    return YES;
}

// Class-method variant that stores the previous IMP for disabled passthrough.
static BOOL GPSLabSwizzleClassMethodCapturingOriginal(Class cls,
                                                      SEL selector,
                                                      IMP replacement,
                                                      void **originalOut) {
    Method method = class_getClassMethod(cls, selector);
    if (method == NULL) {
        return NO;
    }
    IMP original = method_getImplementation(method);
    if (original == replacement) {
        return YES;
    }
    if (originalOut != NULL && *originalOut == NULL) {
        *originalOut = (void *)original;
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

        // Instance methods. Every one captures its original IMP.
        installed += GPSLabSwizzleInstanceCapturingOriginal(managerClass,
                                                            @selector(location),
                                                            (IMP)GPSLabHookLocation,
                                                            (void **)&gGPSLabOriginalLocation) ? 1 : 0;
        installed += GPSLabSwizzleInstanceCapturingOriginal(managerClass,
                                                            @selector(setDelegate:),
                                                            (IMP)GPSLabHookSetDelegate,
                                                            (void **)&gGPSLabOriginalSetDelegate) ? 1 : 0;
        installed += GPSLabSwizzleInstanceCapturingOriginal(managerClass,
                                                            @selector(startUpdatingLocation),
                                                            (IMP)GPSLabHookStartUpdatingLocation,
                                                            (void **)&gGPSLabOriginalStartUpdatingLocation) ? 1 : 0;
        installed += GPSLabSwizzleInstanceCapturingOriginal(managerClass,
                                                            @selector(stopUpdatingLocation),
                                                            (IMP)GPSLabHookStopUpdatingLocation,
                                                            (void **)&gGPSLabOriginalStopUpdatingLocation) ? 1 : 0;
        installed += GPSLabSwizzleInstanceCapturingOriginal(managerClass,
                                                            @selector(requestLocation),
                                                            (IMP)GPSLabHookRequestLocation,
                                                            (void **)&gGPSLabOriginalRequestLocation) ? 1 : 0;
        installed += GPSLabSwizzleInstanceCapturingOriginal(managerClass,
                                                            @selector(startMonitoringSignificantLocationChanges),
                                                            (IMP)GPSLabHookStartSignificantChanges,
                                                            (void **)&gGPSLabOriginalStartSignificant) ? 1 : 0;
        installed += GPSLabSwizzleInstanceCapturingOriginal(managerClass,
                                                            @selector(stopMonitoringSignificantLocationChanges),
                                                            (IMP)GPSLabHookStopSignificantChanges,
                                                            (void **)&gGPSLabOriginalStopSignificant) ? 1 : 0;
        installed += GPSLabSwizzleInstanceCapturingOriginal(managerClass,
                                                            @selector(requestWhenInUseAuthorization),
                                                            (IMP)GPSLabHookRequestWhenInUseAuthorization,
                                                            (void **)&gGPSLabOriginalRequestWhenInUse) ? 1 : 0;
        installed += GPSLabSwizzleInstanceCapturingOriginal(managerClass,
                                                            @selector(requestAlwaysAuthorization),
                                                            (IMP)GPSLabHookRequestAlwaysAuthorization,
                                                            (void **)&gGPSLabOriginalRequestAlways) ? 1 : 0;

        // These exist on iOS 16; the runtime lookup keeps this safe if that changes.
        installed += GPSLabSwizzleInstanceCapturingOriginal(managerClass,
                                                            @selector(authorizationStatus),
                                                            (IMP)GPSLabHookAuthorizationStatusInstance,
                                                            (void **)&gGPSLabOriginalAuthorizationStatusInstance) ? 1 : 0;
        installed += GPSLabSwizzleInstanceCapturingOriginal(managerClass,
                                                            @selector(accuracyAuthorization),
                                                            (IMP)GPSLabHookAccuracyAuthorization,
                                                            (void **)&gGPSLabOriginalAccuracyAuthorization) ? 1 : 0;

        // Class methods.
        installed += GPSLabSwizzleClassMethodCapturingOriginal(managerClass,
                                                               @selector(authorizationStatus),
                                                               (IMP)GPSLabHookAuthorizationStatusClass,
                                                               (void **)&gGPSLabOriginalAuthorizationStatusClass) ? 1 : 0;
        installed += GPSLabSwizzleClassMethodCapturingOriginal(managerClass,
                                                               @selector(locationServicesEnabled),
                                                               (IMP)GPSLabHookLocationServicesEnabled,
                                                               (void **)&gGPSLabOriginalLocationServicesEnabled) ? 1 : 0;

        gGPSLabHooksInstalled = YES;
        GPSLabDiagHooksInstalled(installed);

        // Verify the captures that must always exist on iOS 16. A NULL here would
        // let a passthrough silently drop a host call, so report it as a stable code.
        if (gGPSLabOriginalSetDelegate == NULL ||
            gGPSLabOriginalLocation == NULL ||
            gGPSLabOriginalStartUpdatingLocation == NULL ||
            gGPSLabOriginalStopUpdatingLocation == NULL ||
            gGPSLabOriginalRequestLocation == NULL ||
            gGPSLabOriginalStartSignificant == NULL ||
            gGPSLabOriginalStopSignificant == NULL) {
            GPSLabDiagInternalError(12);
        }
    });

    return gGPSLabHooksInstalled;
}

+ (BOOL)areHooksInstalled {
    return gGPSLabHooksInstalled;
}

#pragma mark - Bypass

+ (void)setBypassed:(BOOL)bypassed forManager:(CLLocationManager *)manager {
    if (manager == nil) {
        return;
    }
    objc_setAssociatedObject(manager,
                             &kGPSLabBypassKey,
                             bypassed ? @YES : nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

+ (BOOL)isBypassedManager:(CLLocationManager *)manager {
    return GPSLabIsBypassedManager(manager);
}

#pragma mark - Original passthrough

+ (BOOL)forwardSelector:(SEL)selector onManager:(CLLocationManager *)manager {
    if (selector == NULL || manager == nil) {
        return NO;
    }

    if (selector == @selector(startUpdatingLocation) && gGPSLabOriginalStartUpdatingLocation != NULL) {
        gGPSLabOriginalStartUpdatingLocation(manager, selector);
        return YES;
    }
    if (selector == @selector(stopUpdatingLocation) && gGPSLabOriginalStopUpdatingLocation != NULL) {
        gGPSLabOriginalStopUpdatingLocation(manager, selector);
        return YES;
    }
    if (selector == @selector(startMonitoringSignificantLocationChanges) &&
        gGPSLabOriginalStartSignificant != NULL) {
        gGPSLabOriginalStartSignificant(manager, selector);
        return YES;
    }
    if (selector == @selector(stopMonitoringSignificantLocationChanges) &&
        gGPSLabOriginalStopSignificant != NULL) {
        gGPSLabOriginalStopSignificant(manager, selector);
        return YES;
    }
    if (selector == @selector(requestWhenInUseAuthorization) && gGPSLabOriginalRequestWhenInUse != NULL) {
        gGPSLabOriginalRequestWhenInUse(manager, selector);
        return YES;
    }
    if (selector == @selector(requestAlwaysAuthorization) && gGPSLabOriginalRequestAlways != NULL) {
        gGPSLabOriginalRequestAlways(manager, selector);
        return YES;
    }
    return NO;
}

@end
