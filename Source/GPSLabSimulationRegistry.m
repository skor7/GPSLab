//
//  GPSLabSimulationRegistry.m
//  GPSLab
//

#import "GPSLabSimulationRegistry.h"

#import <objc/message.h>

#import "GPSLabProtectedString.h"

static GPSLabProfileWiFiConfig *gGPSLabActiveWiFiConfig = nil;
static GPSLabProfileBluetoothConfig *gGPSLabActiveBluetoothConfig = nil;

// Client-only storage namespace/keys: decoded in PRODUCTION, readable in DEV.
#define kGPSLabSimulationSuite GPSLAB_PROTECTED_STRING(DefaultsSuite)
#define kGPSLabWiFiEnabledKey GPSLAB_PROTECTED_STRING(WiFiSimulationKey)
#define kGPSLabBluetoothEnabledKey GPSLAB_PROTECTED_STRING(BluetoothSimulationKey)

@implementation GPSLabSimulationRegistry

+ (NSUserDefaults *)simulationDefaults {
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:kGPSLabSimulationSuite];
    return defaults ?: [NSUserDefaults standardUserDefaults];
}

+ (GPSLabWiFiSimulationModule *)wifiModule {
    static GPSLabWiFiSimulationModule *module = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        module = [[GPSLabWiFiSimulationModule alloc] init];
    });
    return module;
}

+ (GPSLabBluetoothSimulationModule *)bluetoothModule {
    static GPSLabBluetoothSimulationModule *module = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        module = [[GPSLabBluetoothSimulationModule alloc] init];
    });
    return module;
}

+ (NSArray<GPSLabSimulationCapability *> *)capabilities {
    return @[ self.wifiModule.capability, self.bluetoothModule.capability ];
}

+ (void)activateWiFiConfig:(nullable GPSLabProfileWiFiConfig *)config {
    @synchronized(self) {
        gGPSLabActiveWiFiConfig = (config == nil) ? nil : [self.wifiModule normalizedConfig:config];
    }
}

+ (void)activateBluetoothConfig:(nullable GPSLabProfileBluetoothConfig *)config {
    @synchronized(self) {
        gGPSLabActiveBluetoothConfig = (config == nil) ? nil : [self.bluetoothModule normalizedConfig:config];
    }
}

+ (GPSLabProfileWiFiConfig *)activeWiFiConfig {
    @synchronized(self) {
        return gGPSLabActiveWiFiConfig;
    }
}

+ (GPSLabProfileBluetoothConfig *)activeBluetoothConfig {
    @synchronized(self) {
        return gGPSLabActiveBluetoothConfig;
    }
}

+ (BOOL)isWiFiEnabled {
    return [[self simulationDefaults] boolForKey:kGPSLabWiFiEnabledKey];
}

+ (void)setWiFiEnabled:(BOOL)enabled {
    [[self simulationDefaults] setBool:enabled forKey:kGPSLabWiFiEnabledKey];
}

+ (BOOL)isBluetoothEnabled {
    return [[self simulationDefaults] boolForKey:kGPSLabBluetoothEnabledKey];
}

+ (void)setBluetoothEnabled:(BOOL)enabled {
    [[self simulationDefaults] setBool:enabled forKey:kGPSLabBluetoothEnabledKey];
}

+ (BOOL)installRuntimeHooks {
    BOOL bluetooth = NO;
    BOOL wifi = NO;
    SEL selector = NSSelectorFromString(@"installHooks");

    Class bluetoothClass = NSClassFromString(@"GPSLabBluetoothRuntime");
    if (bluetoothClass != Nil && [bluetoothClass respondsToSelector:selector]) {
        BOOL (*invoke)(id, SEL) = (BOOL (*)(id, SEL))[bluetoothClass methodForSelector:selector];
        bluetooth = invoke != NULL ? invoke(bluetoothClass, selector) : NO;
    }

    Class wifiClass = NSClassFromString(@"GPSLabWiFiRuntime");
    if (wifiClass != Nil && [wifiClass respondsToSelector:selector]) {
        BOOL (*invoke)(id, SEL) = (BOOL (*)(id, SEL))[wifiClass methodForSelector:selector];
        wifi = invoke != NULL ? invoke(wifiClass, selector) : NO;
    }

    // One unavailable public API must not prevent the other simulation module
    // from functioning; installation succeeds when at least one hook set exists.
    return bluetooth || wifi;
}

@end
