//
//  GPSLabLicenseManager.h
//  GPSLab
//
//  Coordinates the signed-entitlement lifecycle and is the ONLY place that decides
//  whether the synthetic engine may run. Fail-closed:
//    * unconfigured build              -> Offline (locked)
//    * no verified cache, checking     -> Checking (locked)
//    * verified Active/Grace           -> unlocked
//    * revoked/tampered/expired        -> Invalid/Expired (locked, cache handled)
//
//  The verified token envelope, metadata clock and refresh token live in the Keychain
//  only (GPSLabSecureStore). Nothing is written to NSUserDefaults.
//

#import <Foundation/Foundation.h>

#import "GPSLabEntitlement.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const GPSLabLicenseStateDidChangeNotification;

@interface GPSLabLicenseManager : NSObject

+ (instancetype)sharedManager;

- (GPSLabEntitlementState)state;
- (GPSLabEntitlement *)currentEntitlement;
- (BOOL)isUnlocked;

/** YES when an HTTPS endpoint and a verification public key are configured. */
- (BOOL)isServiceConfigured;

/** Non-technical status text for the subscription screen. */
- (NSString *)nonTechnicalServiceStatus;

/** Loads the verified Keychain cache, applies the gate, then refreshes over the network. */
- (void)loadAndStart;

/** Foreground reconciliation: cached-first, then a bounded network refresh. */
- (void)reconcileOnForeground;

/** Re-checks the server. Completion runs on the main queue. */
- (void)refreshWithCompletion:(nullable void (^)(GPSLabEntitlementState state))completion;

/** Submits an activation code to the configured endpoint. */
- (void)activateWithCode:(nullable NSString *)code
              completion:(nullable void (^)(GPSLabEntitlementState state, NSString * _Nullable message))completion;

/** Restores entitlement from the stored refresh token / server. */
- (void)restoreWithCompletion:(nullable void (^)(GPSLabEntitlementState state, NSString * _Nullable message))completion;

@end

NS_ASSUME_NONNULL_END
