//
//  GPSLabWiFiRuntime.m
//  GPSLab
//

#import "GPSLabWiFiRuntime.h"

#import <NetworkExtension/NetworkExtension.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "GPSLabSimulationRegistry.h"

static void (*gOriginalFetchCurrent)(id, SEL, void (^)(NEHotspotNetwork * _Nullable)) = NULL;

static const void *kGPSLabWiFiSSID = &kGPSLabWiFiSSID;
static const void *kGPSLabWiFiBSSID = &kGPSLabWiFiBSSID;
static const void *kGPSLabWiFiSignal = &kGPSLabWiFiSignal;

static uint64_t GPSLabWiFiHash(NSString *value) {
    NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    uint64_t hash = 1469598103934665603ULL;
    const uint8_t *bytes = data.bytes;
    for (NSUInteger i = 0; i < data.length; i++) {
        hash ^= bytes[i];
        hash *= 1099511628211ULL;
    }
    return hash;
}

static NSString *GPSLabDerivedBSSID(NSString *ssid) {
    uint64_t hash = GPSLabWiFiHash(ssid ?: @"GPSLab");
    return [NSString stringWithFormat:@"02:%02X:%02X:%02X:%02X:%02X",
            (unsigned)((hash >> 32) & 0xFF),
            (unsigned)((hash >> 24) & 0xFF),
            (unsigned)((hash >> 16) & 0xFF),
            (unsigned)((hash >> 8) & 0xFF),
            (unsigned)(hash & 0xFF)];
}

static NSString *GPSLabFakeSSID(id self, SEL _cmd) {
    (void)_cmd;
    return objc_getAssociatedObject(self, kGPSLabWiFiSSID);
}

static NSString *GPSLabFakeBSSID(id self, SEL _cmd) {
    (void)_cmd;
    return objc_getAssociatedObject(self, kGPSLabWiFiBSSID);
}

static double GPSLabFakeSignal(id self, SEL _cmd) {
    (void)_cmd;
    NSNumber *signal = objc_getAssociatedObject(self, kGPSLabWiFiSignal);
    return MAX(0.0, MIN(1.0, signal.doubleValue));
}

static BOOL GPSLabFakeSecure(id self, SEL _cmd) { (void)self; (void)_cmd; return YES; }
static BOOL GPSLabFakeAutoJoined(id self, SEL _cmd) { (void)self; (void)_cmd; return NO; }
static BOOL GPSLabFakeJustJoined(id self, SEL _cmd) { (void)self; (void)_cmd; return NO; }

static Class GPSLabFakeHotspotClass(void) {
    static Class cls = Nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class base = NSClassFromString(@"NEHotspotNetwork");
        if (base == Nil) return;
        cls = objc_allocateClassPair(base, "GPSLabSyntheticNEHotspotNetwork", 0);
        if (cls == Nil) {
            cls = NSClassFromString(@"GPSLabSyntheticNEHotspotNetwork");
            return;
        }
        class_addMethod(cls, @selector(SSID), (IMP)GPSLabFakeSSID, "@@:");
        class_addMethod(cls, @selector(BSSID), (IMP)GPSLabFakeBSSID, "@@:");
        class_addMethod(cls, @selector(signalStrength), (IMP)GPSLabFakeSignal, "d@:");
        class_addMethod(cls, @selector(isSecure), (IMP)GPSLabFakeSecure, "B@:");
        class_addMethod(cls, @selector(didAutoJoin), (IMP)GPSLabFakeAutoJoined, "B@:");
        class_addMethod(cls, @selector(didJustJoin), (IMP)GPSLabFakeJustJoined, "B@:");
        objc_registerClassPair(cls);
    });
    return cls;
}

static NEHotspotNetwork *GPSLabCreateHotspot(void) {
    GPSLabProfileWiFiConfig *config = [GPSLabSimulationRegistry activeWiFiConfig];
    if (config == nil) return nil;
    Class cls = GPSLabFakeHotspotClass();
    if (cls == Nil) return nil;
    id network = [[cls alloc] init];
    if (network == nil) return nil;
    objc_setAssociatedObject(network, kGPSLabWiFiSSID, config.ssid, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(network, kGPSLabWiFiBSSID, GPSLabDerivedBSSID(config.ssid), OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(network, kGPSLabWiFiSignal, @((double)config.signal / 100.0), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return network;
}

static void GPSLabFetchCurrent(id self, SEL _cmd, void (^completion)(NEHotspotNetwork * _Nullable)) {
    if (![GPSLabSimulationRegistry isWiFiEnabled]) {
        if (gOriginalFetchCurrent != NULL) gOriginalFetchCurrent(self, _cmd, completion);
        return;
    }
    if (completion == nil) return;
    NEHotspotNetwork *network = GPSLabCreateHotspot();
    dispatch_async(dispatch_get_main_queue(), ^{
        completion(network);
    });
}

@implementation GPSLabWiFiRuntime

+ (BOOL)installHooks {
    static dispatch_once_t onceToken;
    static BOOL installed = NO;
    dispatch_once(&onceToken, ^{
        Class cls = NSClassFromString(@"NEHotspotNetwork");
        if (cls == Nil) return;
        Class meta = object_getClass(cls);
        SEL selector = @selector(fetchCurrentWithCompletionHandler:);
        Method method = class_getClassMethod(cls, selector);
        if (meta == Nil || method == NULL) return;
        gOriginalFetchCurrent = (void (*)(id, SEL, void (^)(NEHotspotNetwork * _Nullable)))method_getImplementation(method);
        const char *types = method_getTypeEncoding(method);
        class_replaceMethod(meta, selector, (IMP)GPSLabFetchCurrent, types);
        installed = (method_getImplementation(class_getClassMethod(cls, selector)) == (IMP)GPSLabFetchCurrent);
    });
    return installed;
}

@end
