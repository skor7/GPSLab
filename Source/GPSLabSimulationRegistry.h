//
//  GPSLabSimulationRegistry.h
//  GPSLab
//
//  Registry and master controls for host-app-only environment simulation.
//

#import "GPSLabSimulationModule.h"
#import "GPSLabWiFiSimulationModule.h"
#import "GPSLabBluetoothSimulationModule.h"

NS_ASSUME_NONNULL_BEGIN

@interface GPSLabSimulationRegistry : NSObject

+ (NSArray<GPSLabSimulationCapability *> *)capabilities;
+ (GPSLabWiFiSimulationModule *)wifiModule;
+ (GPSLabBluetoothSimulationModule *)bluetoothModule;

+ (void)activateWiFiConfig:(nullable GPSLabProfileWiFiConfig *)config;
+ (void)activateBluetoothConfig:(nullable GPSLabProfileBluetoothConfig *)config;
+ (nullable GPSLabProfileWiFiConfig *)activeWiFiConfig;
+ (nullable GPSLabProfileBluetoothConfig *)activeBluetoothConfig;

/** Independent master controls. OFF always means original host behavior. */
+ (BOOL)isWiFiEnabled;
+ (void)setWiFiEnabled:(BOOL)enabled;
+ (BOOL)isBluetoothEnabled;
+ (void)setBluetoothEnabled:(BOOL)enabled;

/**
 * VPN interface masking (ported standalone VPNMask). Default Disabled; while
 * Disabled the getifaddrs hook is a pure pass-through. Persisted immediately and
 * restored on the next launch; the runtime hook is refreshed on every change.
 */
+ (BOOL)isVPNEnabled;
+ (void)setVPNEnabled:(BOOL)enabled;

/** Installs public-API host-process interception. Safe to call repeatedly. */
+ (BOOL)installRuntimeHooks;

@end

NS_ASSUME_NONNULL_END
