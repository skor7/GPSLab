//
//  GPSLabBluetoothSimulationModule.h
//  GPSLab
//
//  Bluetooth *test profile* config. No CoreBluetooth central/peripheral API,
//  scan, advertisement, pairing or advertising-data emission is used. The
//  arbitrary "pattern" is documented metadata only and is never emitted.
//

#import "GPSLabSimulationModule.h"

NS_ASSUME_NONNULL_BEGIN

@interface GPSLabBluetoothSimulationModule : NSObject <GPSLabSimulationModule>

- (GPSLabSimulationModuleResult *)validateConfig:(nullable GPSLabProfileBluetoothConfig *)config;

- (nullable GPSLabProfileBluetoothConfig *)normalizedConfig:(nullable GPSLabProfileBluetoothConfig *)config;

@end

NS_ASSUME_NONNULL_END
