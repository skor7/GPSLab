//
//  GPSLabPrimaryInterface.h
//  GPSLab
//
//  The single place that decides what the overlay presenter hosts.
//
//  Today the primary interface is the map-first overlay. A later phase can register
//  a subscription/account screen here (via `+setProvider:`) without the presenter,
//  the runtime or the hook layer needing to know which one is shown. This phase does
//  not implement any subscription logic; it only provides the seam.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@protocol GPSLabPrimaryInterfaceProviding <NSObject>

/** Builds a new root view controller for the primary GPSLab interface. */
- (UIViewController *)makePrimaryViewController;

@end

@interface GPSLabPrimaryInterface : NSObject

/**
 * Installs the provider used for new presentations. Passing nil restores the default
 * map-first overlay. Intended for the next phase (subscription vs. overlay selection).
 */
+ (void)setProvider:(nullable id<GPSLabPrimaryInterfaceProviding>)provider;

/** Returns a new root view controller for the primary interface. */
+ (UIViewController *)makePrimaryViewController;

@end

NS_ASSUME_NONNULL_END
