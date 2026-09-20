//
//  GPSLabSimulationRegistry.m
//  GPSLab
//

#import "GPSLabSimulationRegistry.h"

static GPSLabProfileWiFiConfig *gGPSLabActiveWiFiConfig = nil;
static GPSLabProfileBluetoothConfig *gGPSLabActiveBluetoothConfig = nil;

@implementation GPSLabSimulationRegistry

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
    if (config == nil) {
        gGPSLabActiveWiFiConfig = nil;
        return;
    }
    gGPSLabActiveWiFiConfig = [self.wifiModule normalizedConfig:config];
}

+ (void)activateBluetoothConfig:(nullable GPSLabProfileBluetoothConfig *)config {
    if (config == nil) {
        gGPSLabActiveBluetoothConfig = nil;
        return;
    }
    gGPSLabActiveBluetoothConfig = [self.bluetoothModule normalizedConfig:config];
}

+ (GPSLabProfileWiFiConfig *)activeWiFiConfig {
    return gGPSLabActiveWiFiConfig;
}

+ (GPSLabProfileBluetoothConfig *)activeBluetoothConfig {
    return gGPSLabActiveBluetoothConfig;
}

@end
