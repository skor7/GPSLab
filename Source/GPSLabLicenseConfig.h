//
//  GPSLabLicenseConfig.h
//  GPSLab
//
//  License configuration resolved from, in priority order:
//    1. GPSLab build-time macros (Source/GPSLabLicenseBuildConfig.h or -D flags)
//    2. the host app Info.plist
//    3. empty defaults
//
//  Every field is EMPTY by default, which makes the license fail closed: no endpoint
//  or no verification public key means no synthetic engine. No secret is embedded.
//
//  Host Info.plist keys (all optional):
//    GPSLabLicenseEndpoint, GPSLabLicensePublicKey, GPSLabSignInURL,
//    GPSLabManageAccountURL, GPSLabLicenseIssuer, GPSLabLicenseAudience,
//    GPSLabMaxOfflineGraceSeconds, GPSLabMaxClockSkewSeconds
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface GPSLabLicenseConfig : NSObject

@property (nonatomic, copy, nullable) NSURL *endpoint;
@property (nonatomic, copy, nullable) NSData *publicKey;

@property (nonatomic, copy, nullable) NSURL *signInURL;
@property (nonatomic, copy, nullable) NSURL *manageAccountURL;

@property (nonatomic, copy, nullable) NSString *issuer;
@property (nonatomic, copy, nullable) NSString *audience;

/** Local cap on `graceUntil - expiresAt`. Default 604800 (7 days). */
@property (nonatomic, assign) NSTimeInterval maxOfflineGraceSeconds;

/** Allowed clock skew for `issuedAt` into the future. Default 300 s. */
@property (nonatomic, assign) NSTimeInterval maxClockSkewSeconds;

/** Network bounds. Defaults: 15 s request, 30 s resource, 128 KiB body, 256 KiB envelope. */
@property (nonatomic, assign) NSTimeInterval requestTimeoutSeconds;
@property (nonatomic, assign) NSTimeInterval resourceTimeoutSeconds;
@property (nonatomic, assign) NSUInteger maxResponseBytes;
@property (nonatomic, assign) NSUInteger maxEnvelopeBytes;

/** YES only when a valid HTTPS endpoint AND a public key are present. */
@property (nonatomic, readonly) BOOL isConfigured;

+ (instancetype)sharedConfig;

/** Testable initializer that reads the same keys from an arbitrary dictionary. */
+ (instancetype)configFromInfoDictionary:(nullable NSDictionary *)info;

@end

NS_ASSUME_NONNULL_END
