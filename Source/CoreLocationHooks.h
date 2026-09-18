//
//  CoreLocationHooks.h
//  GPSLab
//
//  CoreLocation interception via the Objective-C runtime only.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface GPSLabCoreLocationHooks : NSObject

/** Installs every CoreLocation interception once. Returns YES when installed. */
+ (BOOL)installHooks;

/** Whether interception has been installed. */
+ (BOOL)areHooksInstalled;

@end

NS_ASSUME_NONNULL_END
