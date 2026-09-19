//
//  GPSLabLicenseTests.m
//  GPSLab
//
//  Real ObjC tests for the signed-token verifier using Security.framework on macOS.
//  They generate an ephemeral P-256 key, sign real envelopes, and exercise the same
//  GPSLabTokenVerifier used by the dylib (no duplicated crypto).
//
//  Build/run (macOS, GitHub Actions macos-latest):
//    clang -fobjc-arc -fmodules -framework Foundation -framework Security \
//      -ISource tests/GPSLabLicenseTests.m Source/GPSLabTokenVerifier.m \
//      Source/GPSLabLicenseConfig.m -o /tmp/gpslab-license-tests
//    /tmp/gpslab-license-tests
//

#import <Foundation/Foundation.h>
#import <Security/Security.h>

#include <stdint.h>
#include <stdio.h>

#import "GPSLabLicenseConfig.h"
#import "GPSLabLicensePolicy.h"
#import "GPSLabTokenVerifier.h"

static int gFailures = 0;
static int gChecks = 0;

#define CHECK(condition, message)                                  \
    do {                                                           \
        gChecks++;                                                 \
        if (!(condition)) {                                        \
            gFailures++;                                           \
            fprintf(stderr, "FAIL: %s\n", [(message) UTF8String]); \
        }                                                          \
    } while (0)

static NSString *GPSLabBase64URL(NSData *data) {
    NSString *base64 = [data base64EncodedStringWithOptions:0];
    base64 = [base64 stringByReplacingOccurrencesOfString:@"+" withString:@"-"];
    base64 = [base64 stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    base64 = [base64 stringByReplacingOccurrencesOfString:@"=" withString:@""];
    return base64;
}

static NSData *GPSLabBase64URLData(NSString *string) {
    NSMutableString *normalized = [string mutableCopy];
    [normalized replaceOccurrencesOfString:@"-" withString:@"+" options:0 range:NSMakeRange(0, normalized.length)];
    [normalized replaceOccurrencesOfString:@"_" withString:@"/" options:0 range:NSMakeRange(0, normalized.length)];
    while (normalized.length % 4 != 0) {
        [normalized appendString:@"="];
    }
    return [[NSData alloc] initWithBase64EncodedString:normalized options:0];
}

static NSData *GPSLabSPKIWrap(NSData *point) {
    static const uint8_t prefix[] = {
        0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
        0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
    };
    NSMutableData *spki = [NSMutableData dataWithBytes:prefix length:sizeof(prefix)];
    [spki appendData:point];
    return spki;
}

static NSDictionary *GPSLabClaimsRaw(NSString *installationId, NSString *status,
                                     id issuedAt, id expiresAt, id graceUntil) {
    return @{
        @"entitlementId": @"ent-unit-test",
        @"installationId": installationId,
        @"plan": @"pro",
        @"status": status,
        @"issuedAt": issuedAt,
        @"expiresAt": expiresAt,
        @"graceUntil": graceUntil,
        @"issuer": @"gpslab-test-issuer",
        @"audience": @"com.gpslab.runtime",
    };
}

static NSData *GPSLabEnvelopeFromClaims(NSDictionary *claims, SecKeyRef privateKey, NSData **outPayload) {
    NSData *payload = [NSJSONSerialization dataWithJSONObject:claims options:0 error:NULL];
    CFErrorRef error = NULL;
    NSData *signature = CFBridgingRelease(SecKeyCreateSignature(privateKey,
                                                                kSecKeyAlgorithmECDSASignatureMessageX962SHA256,
                                                                (__bridge CFDataRef)payload,
                                                                &error));
    if (signature == nil) {
        return nil;
    }
    if (outPayload != NULL) {
        *outPayload = payload;
    }
    NSDictionary *envelope = @{
        @"version": @1,
        @"alg": @"ES256",
        @"payload": GPSLabBase64URL(payload),
        @"signature": GPSLabBase64URL(signature),
    };
    return [NSJSONSerialization dataWithJSONObject:envelope options:0 error:NULL];
}

static NSData *GPSLabEnvelopeRaw(id version, NSString *alg, NSString *payloadB64, NSString *signatureB64) {
    NSMutableDictionary *envelope = [NSMutableDictionary dictionary];
    if (version != nil) {
        envelope[@"version"] = version;
    }
    if (alg != nil) {
        envelope[@"alg"] = alg;
    }
    if (payloadB64 != nil) {
        envelope[@"payload"] = payloadB64;
    }
    if (signatureB64 != nil) {
        envelope[@"signature"] = signatureB64;
    }
    return [NSJSONSerialization dataWithJSONObject:envelope options:0 error:NULL];
}

static GPSLabLicenseClaims *GPSLabVerifyFull(NSData *envelope, NSData *publicKey,
                                             NSString *installationId, NSString *issuer,
                                             NSString *audience, NSUInteger maxPayload,
                                             NSUInteger maxEnvelope, NSError **error) {
    return [GPSLabTokenVerifier verifyEnvelopeData:envelope
                                          publicKey:publicKey
                               expectedInstallation:installationId
                                             issuer:issuer
                                           audience:audience
                                    maxPayloadBytes:maxPayload
                                   maxEnvelopeBytes:maxEnvelope
                                              error:error];
}

static GPSLabLicenseClaims *GPSLabVerify(NSData *envelope, NSData *publicKey,
                                         NSString *installationId, NSError **error) {
    return GPSLabVerifyFull(envelope, publicKey, installationId, @"gpslab-test-issuer",
                            @"com.gpslab.runtime", 0, 0, error);
}

int main(void) {
    @autoreleasepool {
        NSDictionary *keyAttributes = @{
            (__bridge id)kSecAttrKeyType: (__bridge id)kSecAttrKeyTypeECSECPrimeRandom,
            (__bridge id)kSecAttrKeySizeInBits: @256,
        };
        CFErrorRef keyError = NULL;
        SecKeyRef privateKey = SecKeyCreateRandomKey((__bridge CFDictionaryRef)keyAttributes, &keyError);
        if (privateKey == NULL) {
            fprintf(stderr, "FAIL: could not generate test key\n");
            return 1;
        }
        SecKeyRef publicKey = SecKeyCopyPublicKey(privateKey);
        NSData *rawPoint = CFBridgingRelease(SecKeyCopyExternalRepresentation(publicKey, &keyError));
        NSData *spki = GPSLabSPKIWrap(rawPoint);

        NSString *installation = @"11111111-2222-3333-4444-555555555555";
        long long now = (long long)[NSDate date].timeIntervalSince1970;

        // 1) Valid envelope verifies with the exact SPKI key.
        NSError *error = nil;
        NSDictionary *goodClaims = GPSLabClaimsRaw(installation, @"active", @(now), @(now + 86400), @0);
        NSData *validEnvelope = GPSLabEnvelopeFromClaims(goodClaims, privateKey, NULL);
        GPSLabLicenseClaims *claims = GPSLabVerify(validEnvelope, spki, installation, &error);
        CHECK(claims != nil, @"valid envelope verifies with SPKI key");
        CHECK([claims.entitlementId isEqualToString:@"ent-unit-test"], @"entitlement id parsed");
        CHECK([claims.status isEqualToString:@"active"], @"status parsed");

        // 2) Valid envelope also verifies with the raw X9.63 point.
        error = nil;
        claims = GPSLabVerify(validEnvelope, rawPoint, installation, &error);
        CHECK(claims != nil, @"valid envelope verifies with raw X9.63 key");

        // 3) Tampered payload fails the signature.
        error = nil;
        NSMutableDictionary *tamperedClaims = [goodClaims mutableCopy];
        tamperedClaims[@"plan"] = @"enterprise";
        NSData *tamperedPayload = [NSJSONSerialization dataWithJSONObject:tamperedClaims options:0 error:NULL];
        NSDictionary *validDict = [NSJSONSerialization JSONObjectWithData:validEnvelope options:0 error:NULL];
        claims = GPSLabVerify(GPSLabEnvelopeRaw(@1, @"ES256", GPSLabBase64URL(tamperedPayload),
                                                validDict[@"signature"]),
                              spki, installation, &error);
        CHECK(claims == nil && error.code == GPSLabLicenseErrorBadSignature, @"tampered payload rejected");

        // 4) Tampered signature fails.
        error = nil;
        NSMutableData *badSignature = [GPSLabBase64URLData(validDict[@"signature"]) mutableCopy];
        if (badSignature.length > 0) {
            ((uint8_t *)badSignature.mutableBytes)[badSignature.length - 1] ^= 0xFF;
        }
        claims = GPSLabVerify(GPSLabEnvelopeRaw(@1, @"ES256", validDict[@"payload"],
                                                GPSLabBase64URL(badSignature)),
                              spki, installation, &error);
        CHECK(claims == nil, @"tampered signature rejected");

        // 5) Wrong installation binding.
        error = nil;
        claims = GPSLabVerify(validEnvelope, spki, @"99999999-0000-0000-0000-000000000000", &error);
        CHECK(claims == nil && error.code == GPSLabLicenseErrorBindingMismatch, @"binding mismatch rejected");

        // 6) Issuer/audience mismatch.
        error = nil;
        claims = GPSLabVerifyFull(validEnvelope, spki, installation, @"other-issuer",
                                  @"com.gpslab.runtime", 0, 0, &error);
        CHECK(claims == nil && error.code == GPSLabLicenseErrorIssuerMismatch, @"issuer mismatch rejected");
        error = nil;
        claims = GPSLabVerifyFull(validEnvelope, spki, installation, @"gpslab-test-issuer",
                                  @"other-audience", 0, 0, &error);
        CHECK(claims == nil && error.code == GPSLabLicenseErrorAudienceMismatch, @"audience mismatch rejected");

        // 7) Envelope size cap is enforced BEFORE parsing/decoding.
        error = nil;
        claims = GPSLabVerifyFull(validEnvelope, spki, installation, @"gpslab-test-issuer",
                                  @"com.gpslab.runtime", 0, 8, &error);
        CHECK(claims == nil && error.code == GPSLabLicenseErrorEnvelopeTooLarge,
              @"envelope size cap enforced before parse");

        // 8) Version must be the integer 1, not fractional or boolean.
        error = nil;
        claims = GPSLabVerify(GPSLabEnvelopeRaw(@1.5, @"ES256", validDict[@"payload"],
                                                validDict[@"signature"]),
                              spki, installation, &error);
        CHECK(claims == nil && error.code == GPSLabLicenseErrorUnsupported, @"fractional version rejected");
        error = nil;
        claims = GPSLabVerify(GPSLabEnvelopeRaw(@YES, @"ES256", validDict[@"payload"],
                                                validDict[@"signature"]),
                              spki, installation, &error);
        CHECK(claims == nil && error.code == GPSLabLicenseErrorUnsupported, @"boolean version rejected");
        error = nil;
        claims = GPSLabVerify(GPSLabEnvelopeRaw(@2, @"ES256", validDict[@"payload"],
                                                validDict[@"signature"]),
                              spki, installation, &error);
        CHECK(claims == nil && error.code == GPSLabLicenseErrorUnsupported, @"version 2 rejected");
        error = nil;
        claims = GPSLabVerify(GPSLabEnvelopeRaw(@1, @"HS256", validDict[@"payload"],
                                                validDict[@"signature"]),
                              spki, installation, &error);
        CHECK(claims == nil && error.code == GPSLabLicenseErrorUnsupported, @"HS256 rejected");

        // 9) Missing key, malformed input, oversized signature.
        error = nil;
        claims = GPSLabVerify(validEnvelope, [NSData data], installation, &error);
        CHECK(claims == nil && error.code == GPSLabLicenseErrorMissingKey, @"missing key rejected");
        error = nil;
        claims = GPSLabVerify([@"not json" dataUsingEncoding:NSUTF8StringEncoding], spki, installation, &error);
        CHECK(claims == nil && error.code == GPSLabLicenseErrorMalformed, @"malformed envelope rejected");
        error = nil;
        claims = GPSLabVerify(GPSLabEnvelopeRaw(@1, @"ES256", validDict[@"payload"],
                                                [@"" stringByPaddingToLength:600 withString:@"A" startingAtIndex:0]),
                              spki, installation, &error);
        CHECK(claims == nil && error.code == GPSLabLicenseErrorMalformed, @"oversized signature rejected");

        // 10) Payload cap (encoded string) and future-dated rejection.
        error = nil;
        claims = GPSLabVerifyFull(validEnvelope, spki, installation, @"gpslab-test-issuer",
                                  @"com.gpslab.runtime", 8, 0, &error);
        CHECK(claims == nil && error.code == GPSLabLicenseErrorPayloadTooLarge, @"oversized payload rejected");

        // 11) Unsafe timestamps: fractional, boolean, oversized, reversed, bad grace.
        error = nil;
        claims = GPSLabVerify(GPSLabEnvelopeFromClaims(
                                  GPSLabClaimsRaw(installation, @"active", @(now + 0.5), @(now + 86400), @0),
                                  privateKey, NULL),
                              spki, installation, &error);
        CHECK(claims == nil && error.code == GPSLabLicenseErrorUnsafeTime, @"fractional issuedAt rejected");
        error = nil;
        claims = GPSLabVerify(GPSLabEnvelopeFromClaims(
                                  GPSLabClaimsRaw(installation, @"active", @YES, @(now + 86400), @0),
                                  privateKey, NULL),
                              spki, installation, &error);
        CHECK(claims == nil && error.code == GPSLabLicenseErrorUnsafeTime, @"boolean issuedAt rejected");
        error = nil;
        claims = GPSLabVerify(GPSLabEnvelopeFromClaims(
                                  GPSLabClaimsRaw(installation, @"active", @(now),
                                                  @(GPSLAB_LICENSE_MAX_TIMESTAMP + 1), @0),
                                  privateKey, NULL),
                              spki, installation, &error);
        CHECK(claims == nil && error.code == GPSLabLicenseErrorUnsafeTime, @"oversized expiry rejected");
        error = nil;
        claims = GPSLabVerify(GPSLabEnvelopeFromClaims(
                                  GPSLabClaimsRaw(installation, @"active", @(now + 100), @(now), @0),
                                  privateKey, NULL),
                              spki, installation, &error);
        CHECK(claims == nil && error.code == GPSLabLicenseErrorUnsafeTime, @"issuedAt > expiresAt rejected");
        error = nil;
        claims = GPSLabVerify(GPSLabEnvelopeFromClaims(
                                  GPSLabClaimsRaw(installation, @"grace", @(now), @(now + 86400), @(now + 10)),
                                  privateKey, NULL),
                              spki, installation, &error);
        CHECK(claims == nil && error.code == GPSLabLicenseErrorUnsafeTime, @"graceUntil < expiresAt rejected");
        error = nil;
        claims = GPSLabVerify(GPSLabEnvelopeFromClaims(
                                  GPSLabClaimsRaw(installation, @"whatever", @(now), @(now + 86400), @0),
                                  privateKey, NULL),
                              spki, installation, &error);
        CHECK(claims == nil && error.code == GPSLabLicenseErrorInvalidClaims, @"unknown status rejected");

        // 12) Malformed / arbitrary key shapes are rejected (no tail trust).
        error = nil;
        claims = GPSLabVerify(validEnvelope, [spki subdataWithRange:NSMakeRange(0, 90)], installation, &error);
        CHECK(claims == nil && error.code == GPSLabLicenseErrorInvalidKey, @"truncated SPKI rejected");
        error = nil;
        claims = GPSLabVerify(validEnvelope, [NSMutableData dataWithLength:91], installation, &error);
        CHECK(claims == nil && error.code == GPSLabLicenseErrorInvalidKey, @"zeroed 91-byte key rejected");
        NSMutableData *badPoint = [NSMutableData dataWithBytes:((uint8_t *)spki.bytes) length:26];
        [badPoint appendData:[NSMutableData dataWithLength:65]];
        error = nil;
        claims = GPSLabVerify(validEnvelope, badPoint, installation, &error);
        CHECK(claims == nil && error.code == GPSLabLicenseErrorInvalidKey, @"SPKI with bad point byte rejected");
        NSMutableData *badPrefix = [NSMutableData dataWithLength:26];
        [badPrefix appendData:rawPoint];
        error = nil;
        claims = GPSLabVerify(validEnvelope, badPrefix, installation, &error);
        CHECK(claims == nil && error.code == GPSLabLicenseErrorInvalidKey, @"arbitrary tail rejected");

        // 13) Future issuedAt verifies cryptographically but the policy rejects it.
        long long future = now + 1000000;
        error = nil;
        NSData *futureEnvelope = GPSLabEnvelopeFromClaims(
            GPSLabClaimsRaw(installation, @"active", @(future), @(future + 86400), @0), privateKey, NULL);
        claims = GPSLabVerify(futureEnvelope, spki, installation, &error);
        CHECK(claims != nil, @"future-dated claims still verify cryptographically");
        CHECK(GPSLabLicenseIssuedAtAcceptable(claims.issuedAt, now, 300) == 0,
              @"policy rejects future issuedAt beyond skew");
        CHECK(GPSLabLicenseIssuedAtAcceptable(claims.issuedAt, future, 300) == 1,
              @"policy accepts issuedAt once the clock catches up");

        // 14) Expired/revoked claims verify; the policy resolves them locked.
        error = nil;
        NSData *expiredEnvelope = GPSLabEnvelopeFromClaims(
            GPSLabClaimsRaw(installation, @"active", @(now - 172800), @(now - 86400), @0), privateKey, NULL);
        claims = GPSLabVerify(expiredEnvelope, spki, installation, &error);
        CHECK(claims != nil, @"expired claims still verify");
        CHECK(GPSLabLicenseStateForTime(now, claims.expiresAt, claims.graceUntil, 604800) ==
                  GPSLabEntitlementStateExpired, @"policy marks expired claims expired");
        error = nil;
        NSData *revokedEnvelope = GPSLabEnvelopeFromClaims(
            GPSLabClaimsRaw(installation, @"revoked", @(now), @(now + 86400), @0), privateKey, NULL);
        claims = GPSLabVerify(revokedEnvelope, spki, installation, &error);
        CHECK(claims != nil && [claims.status isEqualToString:@"revoked"], @"revoked status parsed");
        CHECK(GPSLabLicenseResolveAuth(1, GPSLabLicenseAuthStatusRevoked, now,
                                       claims.expiresAt, claims.graceUntil, 604800) ==
                  GPSLabEntitlementStateInvalid, @"revocation resolves invalid");

        // 16) Server-truthful issuedAt: the server signs its current time even when the
        //     subscription already lapsed, so a fresh issuedAt with a past expiry must
        //     verify for grace/expired/revoked (and only those states).
        error = nil;
        long long pastExpiry = now - 3600;
        NSData *graceEnvelope = GPSLabEnvelopeFromClaims(
            GPSLabClaimsRaw(installation, @"grace", @(now), @(pastExpiry), @(now + 43200)),
            privateKey, NULL);
        claims = GPSLabVerify(graceEnvelope, spki, installation, &error);
        CHECK(claims != nil && [claims.status isEqualToString:@"grace"],
              @"fresh issuedAt with past expiry verifies for grace");
        CHECK(claims != nil &&
                  GPSLabLicenseStateForTime(now, claims.expiresAt, claims.graceUntil, 604800) ==
                      GPSLabEntitlementStateGrace,
              @"grace past expiry resolves unlocked grace");
        error = nil;
        NSData *expiredServerEnvelope = GPSLabEnvelopeFromClaims(
            GPSLabClaimsRaw(installation, @"expired", @(now), @(now - 86400), @0), privateKey, NULL);
        claims = GPSLabVerify(expiredServerEnvelope, spki, installation, &error);
        CHECK(claims != nil && [claims.status isEqualToString:@"expired"],
              @"fresh issuedAt with past expiry verifies for expired");
        CHECK(claims != nil &&
                  GPSLabLicenseStateForTime(now, claims.expiresAt, claims.graceUntil, 604800) ==
                      GPSLabEntitlementStateExpired,
              @"expired past expiry resolves expired (locked)");
        error = nil;
        NSData *revokedServerEnvelope = GPSLabEnvelopeFromClaims(
            GPSLabClaimsRaw(installation, @"revoked", @(now), @(now - 86400), @0), privateKey, NULL);
        claims = GPSLabVerify(revokedServerEnvelope, spki, installation, &error);
        CHECK(claims != nil && [claims.status isEqualToString:@"revoked"],
              @"fresh issuedAt with past expiry verifies for revoked");
        CHECK(claims != nil &&
                  GPSLabLicenseResolveAuth(1, GPSLabLicenseAuthStatusRevoked, now,
                                           claims.expiresAt, claims.graceUntil, 604800) ==
                      GPSLabEntitlementStateInvalid,
              @"revoked past expiry stays locked");

        // 17) Inconsistent state/time combinations still fail closed; an authoritative
        //     signed status never unlocks.
        error = nil;
        claims = GPSLabVerify(GPSLabEnvelopeFromClaims(
                                  GPSLabClaimsRaw(installation, @"grace", @(now), @(now - 3600), @0),
                                  privateKey, NULL),
                              spki, installation, &error);
        CHECK(claims == nil && error.code == GPSLabLicenseErrorUnsafeTime,
              @"grace without a real grace window rejected");
        error = nil;
        claims = GPSLabVerify(GPSLabEnvelopeFromClaims(
                                  GPSLabClaimsRaw(installation, @"grace", @(now), @(now - 3600), @(now - 7200)),
                                  privateKey, NULL),
                              spki, installation, &error);
        CHECK(claims == nil && error.code == GPSLabLicenseErrorUnsafeTime,
              @"grace with graceUntil before expiry rejected");
        error = nil;
        claims = GPSLabVerify(GPSLabEnvelopeFromClaims(
                                  GPSLabClaimsRaw(installation, @"expired", @(now), @(now + 86400), @0),
                                  privateKey, NULL),
                              spki, installation, &error);
        CHECK(claims != nil, @"signed expired status still verifies");
        CHECK(claims != nil &&
                  GPSLabLicenseResolveAuth(1, GPSLabLicenseAuthStatusExpired, now,
                                           claims.expiresAt, claims.graceUntil, 604800) ==
                      GPSLabEntitlementStateExpired,
              @"signed expired status stays locked regardless of the expiry value");

        // 18) A cross-key signature is rejected; optional envelope fields are ignored so
        //     a future key rotation (keyId hint) never changes the verification contract.
        error = nil;
        CFErrorRef crossKeyError = NULL;
        SecKeyRef otherKey = SecKeyCreateRandomKey((__bridge CFDictionaryRef)keyAttributes, &crossKeyError);
        if (crossKeyError != NULL) {
            CFRelease(crossKeyError);
            crossKeyError = NULL;
        }
        CHECK(otherKey != NULL, @"second ephemeral key generated");
        if (otherKey != NULL) {
            NSData *crossEnvelope = GPSLabEnvelopeFromClaims(goodClaims, otherKey, NULL);
            claims = GPSLabVerify(crossEnvelope, spki, installation, &error);
            CHECK(claims == nil && error.code == GPSLabLicenseErrorBadSignature,
                  @"signature from a different key rejected");
            CFRelease(otherKey);
        }
        error = nil;
        NSDictionary *envelopeObject = [NSJSONSerialization JSONObjectWithData:validEnvelope
                                                                      options:0
                                                                        error:NULL];
        NSMutableDictionary *withExtras = [envelopeObject mutableCopy];
        withExtras[@"keyId"] = @"rotated-key-2";
        withExtras[@"refreshToken"] = @"not-a-real-token";
        withExtras[@"futureField"] = @{@"any": @"value"};
        NSData *extraEnvelopeData = [NSJSONSerialization dataWithJSONObject:withExtras options:0 error:NULL];
        claims = GPSLabVerify(extraEnvelopeData, spki, installation, &error);
        CHECK(claims != nil && [claims.entitlementId isEqualToString:@"ent-unit-test"],
              @"extra envelope fields (keyId/refreshToken/future) are ignored");

        // 19) Config parsing: HTTPS required, base64 key decoded, build-time empty default.
        GPSLabLicenseConfig *unconfigured = [GPSLabLicenseConfig configFromInfoDictionary:@{}];
        CHECK(!unconfigured.isConfigured, @"empty config is not configured");
        GPSLabLicenseConfig *httpConfig = [GPSLabLicenseConfig configFromInfoDictionary:@{
            @"GPSLabLicenseEndpoint": @"http://example.com/license",
            @"GPSLabLicensePublicKey": GPSLabBase64URL(spki),
        }];
        CHECK(!httpConfig.isConfigured, @"non-HTTPS endpoint is rejected");
        GPSLabLicenseConfig *httpsConfig = [GPSLabLicenseConfig configFromInfoDictionary:@{
            @"GPSLabLicenseEndpoint": @"https://example.com/license",
            @"GPSLabLicensePublicKey": GPSLabBase64URL(spki),
            @"GPSLabLicenseIssuer": @"gpslab-test-issuer",
            @"GPSLabLicenseAudience": @"com.gpslab.runtime",
        }];
        CHECK(httpsConfig.isConfigured, @"HTTPS endpoint plus key is configured");
        CHECK(httpsConfig.publicKey.length == spki.length, @"public key base64 decoded");
        CHECK(httpsConfig.maxClockSkewSeconds > 0, @"default clock skew configured");

        CFRelease(publicKey);
        CFRelease(privateKey);
    }

    if (gFailures == 0) {
        printf("GPSLabLicenseTests: %d checks passed\n", gChecks);
        return 0;
    }
    fprintf(stderr, "GPSLabLicenseTests: %d/%d checks failed\n", gFailures, gChecks);
    return 1;
}
