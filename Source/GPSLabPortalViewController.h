//
//  GPSLabPortalViewController.h
//  GPSLab
//
//  The web-portal account screen, available whether or not the entitlement is
//  unlocked: subscription status, sign-in, manage/renew, trial device pairing,
//  help and in-app feedback. It performs no licensing decisions; it only opens
//  safe same-origin browser URLs and calls the device-proof client.
//

#import "GPSLabSheetViewController.h"

NS_ASSUME_NONNULL_BEGIN

@interface GPSLabPortalViewController : GPSLabSheetViewController

@end

NS_ASSUME_NONNULL_END
