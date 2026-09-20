//
//  GPSLabSimulationRegistry.h
//  GPSLab
//
//  A tiny registry of the GPSLab simulation/test modules. Deliberately small:
//  no framework is loaded and no host process is modified.
//

#import "GPSLabSimulationModule.h"
#import "GPSLabWiFiSimulationModule.h"
#import "GPSLabBluetoothSimulationModule.h"

NS_ASSUME_NONNULL_BEGIN

@interface GPSLabSimulationRegistry : NSObject

/** Capability descriptors for every registered module, in display order. */
+ (NSArray<GPSLabSimulationCapability *> *)capabilities;

+ (GPSLabWiFiSimulationModule *)wifiModule;
+ (GPSLabBluetoothSimulationModule *)bluetoothModule;

/**
 * Activates (or clears, when nil) the in-memory Wi-Fi test metadata for the
 * currently applied profile. Config-only: no hardware API is touched. Passing an
 * invalid config clears the active config instead of storing garbage.
 */
+ (void)activateWiFiConfig:(nullable GPSLabProfileWiFiConfig *)config;
+ (void)activateBluetoothConfig:(nullable GPSLabProfileBluetoothConfig *)config;

/** The currently active test metadata, or nil. Read-only, in-memory. */
+ (nullable GPSLabProfileWiFiConfig *)activeWiFiConfig;
+ (nullable GPSLabProfileBluetoothConfig *)activeBluetoothConfig;

@end

NS_ASSUME_NONNULL_END
