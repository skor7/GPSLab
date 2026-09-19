//
//  GPSLabPrimaryInterface.m
//  GPSLab
//
//  Default primary interface is the map-first overlay. No subscription logic lives
//  here; it is only the registration seam for a later phase.
//

#import "GPSLabPrimaryInterface.h"

#import "GPSLabLicenseManager.h"
#import "GPSLabOverlayViewController.h"
#import "GPSLabSubscriptionViewController.h"

static id<GPSLabPrimaryInterfaceProviding> gGPSLabPrimaryProvider = nil;

#pragma mark - Default provider

@interface GPSLabDefaultPrimaryInterfaceProvider : NSObject <GPSLabPrimaryInterfaceProviding>
@end

@implementation GPSLabDefaultPrimaryInterfaceProvider

- (UIViewController *)makePrimaryViewController {
    // Fail-closed: without a usable signed entitlement the subscription screen is the
    // primary interface; the map canvas only appears once unlocked.
    if ([[GPSLabLicenseManager sharedManager] isUnlocked]) {
        return [[GPSLabOverlayViewController alloc] init];
    }
    return [[GPSLabSubscriptionViewController alloc] init];
}

@end

#pragma mark - Registry

@implementation GPSLabPrimaryInterface

+ (void)setProvider:(id<GPSLabPrimaryInterfaceProviding>)provider {
    gGPSLabPrimaryProvider = provider;
}

+ (UIViewController *)makePrimaryViewController {
    id<GPSLabPrimaryInterfaceProviding> provider = gGPSLabPrimaryProvider;
    if (provider != nil) {
        return [provider makePrimaryViewController];
    }
    return [[GPSLabDefaultPrimaryInterfaceProvider alloc] makePrimaryViewController];
}

@end
