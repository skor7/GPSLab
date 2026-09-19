//
//  GPSLabEntitlement.h
//  GPSLab
//
//  Immutable-ish snapshot of the resolved entitlement. The engine gate only cares
//  about `state`; `isUnlocked` is the single definition of "may synthesize".
//

#import <Foundation/Foundation.h>

#import "GPSLabLicensePolicy.h"

NS_ASSUME_NONNULL_BEGIN

@interface GPSLabEntitlement : NSObject <NSCopying>

@property (nonatomic, assign) GPSLabEntitlementState state;

@property (nonatomic, copy, nullable) NSString *entitlementId;
@property (nonatomic, copy, nullable) NSString *installationId;
@property (nonatomic, copy, nullable) NSString *plan;

@property (nonatomic, assign) long long issuedAt;
@property (nonatomic, assign) long long expiresAt;
@property (nonatomic, assign) long long graceUntil;

/** When the last successful signature verification happened. */
@property (nonatomic, strong, nullable) NSDate *lastVerifiedAt;

/** YES when the entitlement came from the persisted verified cache. */
@property (nonatomic, assign) BOOL fromCache;

/** YES only for Active and Grace. */
- (BOOL)isUnlocked;

/** Human, non-technical description suitable for the subscription screen. */
- (NSString *)localizedStateDescription;

@end

NS_ASSUME_NONNULL_END
