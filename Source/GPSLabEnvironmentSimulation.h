//
//  GPSLabEnvironmentSimulation.h
//  GPSLab
//
//  Public seams for host-app-only environment simulation. Implementations must
//  be passthrough when disabled and must never claim to alter system-wide radio,
//  daemon, device identity, or other applications.
//

#import <Foundation/Foundation.h>

@class GPSLabProfileBluetoothConfig;
@class GPSLabProfileWiFiConfig;

NS_ASSUME_NONNULL_BEGIN

@protocol GPSLabEnvironmentSimulation <NSObject>
@property (nonatomic, getter=isEnabled) BOOL enabled;
- (BOOL)installRuntimeHooks;
@end

@protocol GPSLabBluetoothSimulation <GPSLabEnvironmentSimulation>
@property (nonatomic, readonly, nullable) GPSLabProfileBluetoothConfig *activeBluetoothConfig;
@end

@protocol GPSLabWiFiSimulation <GPSLabEnvironmentSimulation>
@property (nonatomic, readonly, nullable) GPSLabProfileWiFiConfig *activeWiFiConfig;
@end

NS_ASSUME_NONNULL_END
