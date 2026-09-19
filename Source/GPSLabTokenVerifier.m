//
//  GPSLabTokenVerifier.m
//  GPSLab
//
//  Security.framework P-256 / SHA-256 verification. No embedded key, no bypass.
//  All size/shape/numeric validation happens before decode or import.
//

#import "GPSLabTokenVerifier.h"

#import <Security/Security.h>

#import "GPSLabLicensePolicy.h"

NSString * const GPSLabLicenseErrorDomain = @"com.gpslab.runtime.license";

static const NSUInteger kGPSLabDefaultMaxPayloadBytes = 64 * 1024;
static const NSUInteger kGPSLabDefaultMaxEnvelopeBytes = 256 * 1024;
// Base64 of a DER ECDSA P-256 signature is at most ~96 chars; allow modest headroom.
static const NSUInteger kGPSLabMaxSignatureStringLength = 512;
static const NSUInteger kGPSLabRawPointLength = 65;
static const NSUInteger kGPSLabSPKILength = 91; // 26-byte prefix + 65-byte point

// Exact DER prefix for a P-256 SubjectPublicKeyInfo wrapping a 65-byte X9.63 point.
static const uint8_t kGPSLabP256SPKIPrefix[] = {
    0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
    0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
};

@implementation GPSLabLicenseClaims
@end

#pragma mark - Helpers

static void GPSLabSetError(NSError **error, GPSLabLicenseErrorCode code) {
    if (error == NULL) {
        return;
    }
    *error = [NSError errorWithDomain:GPSLabLicenseErrorDomain code:code userInfo:nil];
}

static NSData *GPSLabDecodeBase64(NSString *string) {
    if (![string isKindOfClass:[NSString class]] || string.length == 0) {
        return nil;
    }
    NSMutableString *normalized = [string mutableCopy];
    [normalized replaceOccurrencesOfString:@"-" withString:@"+" options:0 range:NSMakeRange(0, normalized.length)];
    [normalized replaceOccurrencesOfString:@"_" withString:@"/" options:0 range:NSMakeRange(0, normalized.length)];
    NSMutableString *compact = [NSMutableString stringWithCapacity:normalized.length];
    for (NSUInteger index = 0; index < normalized.length; index++) {
        unichar character = [normalized characterAtIndex:index];
        if (character != ' ' && character != '\n' && character != '\r' && character != '\t') {
            [compact appendFormat:@"%C", character];
        }
    }
    while (compact.length % 4 != 0) {
        [compact appendString:@"="];
    }
    return [[NSData alloc] initWithBase64EncodedString:compact options:0];
}

/** YES for exactly 65 bytes starting with the uncompressed point marker 0x04. */
static BOOL GPSLabIsRawPoint(NSData *data) {
    return data.length == kGPSLabRawPointLength && ((const uint8_t *)data.bytes)[0] == 0x04;
}

/** YES only for the exact known P-256 SPKI prefix followed by a 65-byte point. */
static BOOL GPSLabIsExactP256SPKI(NSData *data) {
    if (data.length != kGPSLabSPKILength) {
        return NO;
    }
    const uint8_t *bytes = data.bytes;
    if (memcmp(bytes, kGPSLabP256SPKIPrefix, sizeof(kGPSLabP256SPKIPrefix)) != 0) {
        return NO;
    }
    return bytes[sizeof(kGPSLabP256SPKIPrefix)] == 0x04;
}

// Imports a raw X9.63 point as a P-256 public key. No tail extraction, no DER trust.
static SecKeyRef GPSLabImportRawPoint(NSData *point) {
    if (!GPSLabIsRawPoint(point)) {
        return NULL;
    }
    NSDictionary *attributes = @{
        (__bridge id)kSecAttrKeyType: (__bridge id)kSecAttrKeyTypeECSECPrimeRandom,
        (__bridge id)kSecAttrKeyClass: (__bridge id)kSecAttrKeyClassPublic,
        (__bridge id)kSecAttrKeySizeInBits: @256,
    };
    CFErrorRef creationError = NULL;
    SecKeyRef key = SecKeyCreateWithData((__bridge CFDataRef)point,
                                         (__bridge CFDictionaryRef)attributes,
                                         &creationError);
    if (creationError != NULL) {
        CFRelease(creationError);
    }
    return key;
}

// Accepts ONLY an exact P-256 SPKI or a raw 65-byte point; extracts the raw point
// before import so SecKey never sees an unexpected DER shape.
static SecKeyRef GPSLabCreatePublicKey(NSData *keyData) {
    if (GPSLabIsExactP256SPKI(keyData)) {
        NSUInteger offset = keyData.length - kGPSLabRawPointLength;
        return GPSLabImportRawPoint([keyData subdataWithRange:NSMakeRange(offset, kGPSLabRawPointLength)]);
    }
    if (GPSLabIsRawPoint(keyData)) {
        return GPSLabImportRawPoint(keyData);
    }
    return NULL;
}

static BOOL GPSLabReadNonEmptyString(NSDictionary *dictionary, NSString *key, NSString **outValue) {
    id value = dictionary[key];
    if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) {
        if (outValue != NULL) {
            *outValue = value;
        }
        return YES;
    }
    return NO;
}

/** Strict integer NSNumber: rejects booleans and fractional values. */
static BOOL GPSLabIsStrictInteger(NSNumber *number) {
    const char *type = number.objCType;
    if (type == NULL) {
        return NO;
    }
    switch (type[0]) {
        case 'c':   // char / CFBoolean
        case 'C':
        case 'B':
        case 'f':
        case 'd':
            return NO;
        default:
            return YES;
    }
}

static BOOL GPSLabReadTimestamp(NSDictionary *dictionary, NSString *key, BOOL allowZero, long long *outValue) {
    id value = dictionary[key];
    if (![value isKindOfClass:[NSNumber class]] || !GPSLabIsStrictInteger((NSNumber *)value)) {
        return NO;
    }
    long long number = [(NSNumber *)value longLongValue];
    if (allowZero) {
        if (number < 0 || number > GPSLAB_LICENSE_MAX_TIMESTAMP) {
            return NO;
        }
    } else if (!GPSLabLicenseIsSaneTimestamp(number)) {
        return NO;
    }
    if (outValue != NULL) {
        *outValue = number;
    }
    return YES;
}

#pragma mark - Verifier

@implementation GPSLabTokenVerifier

+ (GPSLabLicenseClaims *)verifyEnvelopeData:(NSData *)envelopeData
                                  publicKey:(NSData *)publicKey
                       expectedInstallation:(NSString *)installationId
                                     issuer:(NSString *)issuer
                                   audience:(NSString *)audience
                            maxPayloadBytes:(NSUInteger)maxPayloadBytes
                           maxEnvelopeBytes:(NSUInteger)maxEnvelopeBytes
                                      error:(NSError **)error {
    NSUInteger envelopeCap = maxEnvelopeBytes > 0 ? maxEnvelopeBytes : kGPSLabDefaultMaxEnvelopeBytes;
    NSUInteger payloadCap = maxPayloadBytes > 0 ? maxPayloadBytes : kGPSLabDefaultMaxPayloadBytes;

    // Size gate BEFORE any JSON or base64 work.
    if (envelopeData.length == 0) {
        GPSLabSetError(error, GPSLabLicenseErrorMalformed);
        return nil;
    }
    if (envelopeData.length > envelopeCap) {
        GPSLabSetError(error, GPSLabLicenseErrorEnvelopeTooLarge);
        return nil;
    }

    id rootObject = [NSJSONSerialization JSONObjectWithData:envelopeData options:0 error:NULL];
    if (![rootObject isKindOfClass:[NSDictionary class]]) {
        GPSLabSetError(error, GPSLabLicenseErrorMalformed);
        return nil;
    }
    NSDictionary *envelope = rootObject;

    id version = envelope[@"version"];
    if (![version isKindOfClass:[NSNumber class]] || !GPSLabIsStrictInteger((NSNumber *)version) ||
        [(NSNumber *)version longLongValue] != 1) {
        GPSLabSetError(error, GPSLabLicenseErrorUnsupported);
        return nil;
    }
    NSString *algorithm = envelope[@"alg"];
    if (![algorithm isKindOfClass:[NSString class]] ||
        ![[algorithm uppercaseString] isEqualToString:@"ES256"]) {
        GPSLabSetError(error, GPSLabLicenseErrorUnsupported);
        return nil;
    }

    NSString *payloadString = envelope[@"payload"];
    NSString *signatureString = envelope[@"signature"];
    if (![payloadString isKindOfClass:[NSString class]] || ![signatureString isKindOfClass:[NSString class]]) {
        GPSLabSetError(error, GPSLabLicenseErrorMalformed);
        return nil;
    }
    // Bound the ENCODED strings before decoding.
    if (payloadString.length > payloadCap * 2) {
        GPSLabSetError(error, GPSLabLicenseErrorPayloadTooLarge);
        return nil;
    }
    if (signatureString.length == 0 || signatureString.length > kGPSLabMaxSignatureStringLength) {
        GPSLabSetError(error, GPSLabLicenseErrorMalformed);
        return nil;
    }

    NSData *payload = GPSLabDecodeBase64(payloadString);
    if (payload.length == 0) {
        GPSLabSetError(error, GPSLabLicenseErrorMalformed);
        return nil;
    }
    if (payload.length > payloadCap) {
        GPSLabSetError(error, GPSLabLicenseErrorPayloadTooLarge);
        return nil;
    }
    NSData *signature = GPSLabDecodeBase64(signatureString);
    if (signature.length == 0) {
        GPSLabSetError(error, GPSLabLicenseErrorMalformed);
        return nil;
    }

    if (publicKey.length == 0) {
        GPSLabSetError(error, GPSLabLicenseErrorMissingKey);
        return nil;
    }
    if (publicKey.length != kGPSLabRawPointLength && publicKey.length != kGPSLabSPKILength) {
        GPSLabSetError(error, GPSLabLicenseErrorInvalidKey);
        return nil;
    }
    SecKeyRef key = GPSLabCreatePublicKey(publicKey);
    if (key == NULL) {
        GPSLabSetError(error, GPSLabLicenseErrorInvalidKey);
        return nil;
    }

    CFErrorRef verifyError = NULL;
    BOOL verified = SecKeyVerifySignature(key,
                                          kSecKeyAlgorithmECDSASignatureMessageX962SHA256,
                                          (__bridge CFDataRef)payload,
                                          (__bridge CFDataRef)signature,
                                          &verifyError);
    if (verifyError != NULL) {
        CFRelease(verifyError);
    }
    CFRelease(key);
    if (!verified) {
        GPSLabSetError(error, GPSLabLicenseErrorBadSignature);
        return nil;
    }

    id payloadObject = [NSJSONSerialization JSONObjectWithData:payload options:0 error:NULL];
    if (![payloadObject isKindOfClass:[NSDictionary class]]) {
        GPSLabSetError(error, GPSLabLicenseErrorInvalidClaims);
        return nil;
    }
    NSDictionary *claimsDictionary = payloadObject;

    GPSLabLicenseClaims *claims = [[GPSLabLicenseClaims alloc] init];
    NSString *entitlementId = nil;
    NSString *boundInstallation = nil;
    NSString *plan = nil;
    NSString *status = nil;
    if (!GPSLabReadNonEmptyString(claimsDictionary, @"entitlementId", &entitlementId) ||
        !GPSLabReadNonEmptyString(claimsDictionary, @"installationId", &boundInstallation) ||
        !GPSLabReadNonEmptyString(claimsDictionary, @"plan", &plan) ||
        !GPSLabReadNonEmptyString(claimsDictionary, @"status", &status)) {
        GPSLabSetError(error, GPSLabLicenseErrorInvalidClaims);
        return nil;
    }

    NSString *normalizedStatus = [status lowercaseString];
    NSSet<NSString *> *allowedStatuses = [NSSet setWithObjects:@"active", @"grace", @"expired", @"revoked", nil];
    if (![allowedStatuses containsObject:normalizedStatus]) {
        GPSLabSetError(error, GPSLabLicenseErrorInvalidClaims);
        return nil;
    }

    long long issuedAt = 0;
    long long expiresAt = 0;
    long long graceUntil = 0;
    if (!GPSLabReadTimestamp(claimsDictionary, @"issuedAt", NO, &issuedAt) ||
        !GPSLabReadTimestamp(claimsDictionary, @"expiresAt", NO, &expiresAt) ||
        !GPSLabReadTimestamp(claimsDictionary, @"graceUntil", YES, &graceUntil)) {
        GPSLabSetError(error, GPSLabLicenseErrorUnsafeTime);
        return nil;
    }

    // The server always signs its TRUTHFUL current time as `issuedAt`. For an
    // authoritative status that can be produced after the subscription lapsed
    // (grace/expired/revoked), `issuedAt` legitimately exceeds `expiresAt`; that is
    // still a signed server statement about a locked or grace state. For `active`,
    // a reversed interval remains unsafe and is rejected.
    BOOL statusMayFollowExpiry = [normalizedStatus isEqualToString:@"grace"] ||
                                 [normalizedStatus isEqualToString:@"expired"] ||
                                 [normalizedStatus isEqualToString:@"revoked"];
    if (!statusMayFollowExpiry && issuedAt > expiresAt) {
        GPSLabSetError(error, GPSLabLicenseErrorUnsafeTime);
        return nil;
    }
    // An inconsistent state/time combination fails closed: `grace` requires a real
    // window at/after expiry, and any other state rejects a reversed grace window.
    if ([normalizedStatus isEqualToString:@"grace"]) {
        if (graceUntil <= expiresAt) {
            GPSLabSetError(error, GPSLabLicenseErrorUnsafeTime);
            return nil;
        }
    } else if (graceUntil != 0 && graceUntil < expiresAt) {
        GPSLabSetError(error, GPSLabLicenseErrorUnsafeTime);
        return nil;
    }

    if (installationId.length == 0 || ![boundInstallation isEqualToString:installationId]) {
        GPSLabSetError(error, GPSLabLicenseErrorBindingMismatch);
        return nil;
    }

    NSString *claimIssuer = nil;
    GPSLabReadNonEmptyString(claimsDictionary, @"issuer", &claimIssuer);
    if (issuer.length > 0 && ![claimIssuer isEqualToString:issuer]) {
        GPSLabSetError(error, GPSLabLicenseErrorIssuerMismatch);
        return nil;
    }

    NSString *claimAudience = nil;
    GPSLabReadNonEmptyString(claimsDictionary, @"audience", &claimAudience);
    if (audience.length > 0 && ![claimAudience isEqualToString:audience]) {
        GPSLabSetError(error, GPSLabLicenseErrorAudienceMismatch);
        return nil;
    }

    claims.entitlementId = entitlementId;
    claims.installationId = boundInstallation;
    claims.plan = plan;
    claims.status = normalizedStatus;
    claims.issuer = claimIssuer;
    claims.audience = claimAudience;
    claims.issuedAt = issuedAt;
    claims.expiresAt = expiresAt;
    claims.graceUntil = graceUntil;
    return claims;
}

@end
