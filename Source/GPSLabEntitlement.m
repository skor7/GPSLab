//
//  GPSLabEntitlement.m
//  GPSLab
//

#import "GPSLabEntitlement.h"

@implementation GPSLabEntitlement

- (instancetype)init {
    self = [super init];
    if (self) {
        _state = GPSLabEntitlementStateUnknown;
    }
    return self;
}

- (BOOL)isUnlocked {
    return GPSLabLicenseStateIsUnlocked(self.state) != 0;
}

- (NSString *)localizedStateDescription {
    switch (self.state) {
        case GPSLabEntitlementStateUnknown:
            return @"Status unknown";
        case GPSLabEntitlementStateChecking:
            return @"Checking subscription...";
        case GPSLabEntitlementStateActive:
            return self.plan.length > 0
                ? [NSString stringWithFormat:@"Active - %@", self.plan]
                : @"Active";
        case GPSLabEntitlementStateGrace:
            return @"Active (grace period)";
        case GPSLabEntitlementStateExpired:
            return @"Subscription expired";
        case GPSLabEntitlementStateInvalid:
            return @"Subscription not valid on this device";
        case GPSLabEntitlementStateOffline:
            return @"Subscription unavailable";
    }
    return @"Subscription unavailable";
}

- (id)copyWithZone:(NSZone *)zone {
    GPSLabEntitlement *copy = [[GPSLabEntitlement allocWithZone:zone] init];
    copy.state = self.state;
    copy.entitlementId = self.entitlementId;
    copy.installationId = self.installationId;
    copy.plan = self.plan;
    copy.issuedAt = self.issuedAt;
    copy.expiresAt = self.expiresAt;
    copy.graceUntil = self.graceUntil;
    copy.lastVerifiedAt = self.lastVerifiedAt;
    copy.fromCache = self.fromCache;
    return copy;
}

@end
