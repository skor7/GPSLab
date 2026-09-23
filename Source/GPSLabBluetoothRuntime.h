//
//  GPSLabBluetoothRuntime.h
//  GPSLab
//
//  CoreBluetooth host-process simulation. No radio/daemon/system identity changes.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface GPSLabBluetoothRuntime : NSObject
+ (BOOL)installHooks;
@end

NS_ASSUME_NONNULL_END
