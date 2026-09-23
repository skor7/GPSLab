//
//  GPSLabWiFiRuntime.h
//  GPSLab
//
//  Public NetworkExtension host-process simulation. C-based CaptiveNetwork APIs
//  remain untouched and therefore retain original system behavior.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface GPSLabWiFiRuntime : NSObject
+ (BOOL)installHooks;
@end
NS_ASSUME_NONNULL_END
