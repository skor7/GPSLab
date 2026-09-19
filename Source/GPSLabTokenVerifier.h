//
//  GPSLabTokenVerifier.h
//  GPSLab
//
//  Offline verification of a server-issued signed entitlement envelope.
//
//  Wire contract (documented, stable):
//    Envelope JSON:
//      { "version": 1, "alg": "ES256",
//        "payload":   "<base64url of the canonical UTF-8 payload JSON>",
//        "signature": "<base64url of the DER-encoded ECDSA P-256 SHA-256 signature>",
//        "keyId":     "<optional diagnostic id>" }
//    Payload JSON claims:
//      { "entitlementId": "...", "installationId": "<UUID string>",
//        "plan": "...", "status": "active|grace|expired|revoked",
//        "issuedAt": <unix seconds>, "expiresAt": <unix seconds>,
//        "graceUntil": <unix seconds, 0 when none>,
//        "issuer": "...", "audience": "..." }
//
//  Public key: base64 of an EXACT P-256 SubjectPublicKeyInfo (26-byte prefix + the
//  65-byte X9.63 point) or the raw 65-byte X9.63 point (0x04||X||Y). Anything else,
//  including arbitrary DER tails, is rejected. The key is public verification
//  material; a signing private key must never ship.
//
//  Rejected (fail-closed): envelope above the size cap (checked before any JSON or
//  base64 work), malformed JSON, unsupported version/alg, fractional/boolean/oversized
//  numeric fields, oversized payload/signature/key, bad key shape, invalid signature,
//  missing/invalid claims, installation mismatch, issuer/audience mismatch, or unsafe
//  timestamps.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const GPSLabLicenseErrorDomain;

typedef NS_ENUM(NSInteger, GPSLabLicenseErrorCode) {
    GPSLabLicenseErrorMalformed = 1,
    GPSLabLicenseErrorUnsupported = 2,
    GPSLabLicenseErrorPayloadTooLarge = 3,
    GPSLabLicenseErrorMissingKey = 4,
    GPSLabLicenseErrorInvalidKey = 5,
    GPSLabLicenseErrorBadSignature = 6,
    GPSLabLicenseErrorInvalidClaims = 7,
    GPSLabLicenseErrorBindingMismatch = 8,
    GPSLabLicenseErrorIssuerMismatch = 9,
    GPSLabLicenseErrorAudienceMismatch = 10,
    GPSLabLicenseErrorUnsafeTime = 11,
    GPSLabLicenseErrorEnvelopeTooLarge = 12,
};

/** Verified, bound claims. */
@interface GPSLabLicenseClaims : NSObject
@property (nonatomic, copy) NSString *entitlementId;
@property (nonatomic, copy) NSString *installationId;
@property (nonatomic, copy) NSString *plan;
@property (nonatomic, copy) NSString *status;      // lowercased
@property (nonatomic, copy, nullable) NSString *issuer;
@property (nonatomic, copy, nullable) NSString *audience;
@property (nonatomic, assign) long long issuedAt;
@property (nonatomic, assign) long long expiresAt;
@property (nonatomic, assign) long long graceUntil;
@end

@interface GPSLabTokenVerifier : NSObject

/**
 * Verifies and validates an envelope. Returns nil (with a stable, non-sensitive error)
 * on any failure.
 *
 * `maxEnvelopeBytes` caps the raw envelope BEFORE parsing (0 uses 256 KiB).
 * `maxPayloadBytes` caps the decoded payload and the encoded payload string (0 uses 64 KiB).
 */
+ (nullable GPSLabLicenseClaims *)verifyEnvelopeData:(NSData *)envelopeData
                                           publicKey:(nullable NSData *)publicKey
                                expectedInstallation:(NSString *)installationId
                                              issuer:(nullable NSString *)issuer
                                            audience:(nullable NSString *)audience
                                     maxPayloadBytes:(NSUInteger)maxPayloadBytes
                                    maxEnvelopeBytes:(NSUInteger)maxEnvelopeBytes
                                               error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
