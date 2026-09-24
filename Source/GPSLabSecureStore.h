//
//  GPSLabSecureStore.h
//  GPSLab
//
//  License material lives ONLY in the Keychain (device-only, never synced and never
//  in NSUserDefaults):
//    * a random installation UUID,
//    * the verified token envelope,
//    * a minimal anti-rollback metadata blob (last-seen wall/uptime + authenticated
//      status, version and nothing else),
//    * an optional refresh token,
//    * a per-installation 32-byte device secret used ONLY as the device pairing /
//      feedback proof. It is deliberately separate from license material:
//      `clearLicenseMaterial` keeps it, so pairing survives sign-out, and it is
//      never placed in a URL, a log or the metadata blob.
//
//  The metadata blob is the one item beyond "UUID/token/refresh"; it is required to
//  detect wall-clock rollback and to preserve an authenticated revoked/expired status
//  across network failures. It deliberately contains no host data, no PII and no
//  coordinates.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface GPSLabSecureStore : NSObject

+ (instancetype)sharedStore;

/** Random installation UUID, created and persisted on first access. */
- (nullable NSString *)installationUUID;

- (nullable NSData *)tokenEnvelope;
- (nullable NSData *)entitlementMeta;
- (nullable NSString *)refreshToken;

/**
 * Per-installation 32-byte device proof. Created and persisted on first access.
 * FAIL CLOSED: when the Keychain write cannot be persisted the method returns nil
 * rather than an ephemeral value, so a restart can never present a different
 * proof and silently mismatch the value enrolled first (no ephemeral enrollment).
 */
- (nullable NSData *)deviceSecret;

/** Base64 (standard alphabet) of `deviceSecret`; nil when unavailable. */
- (nullable NSString *)deviceSecretBase64;

/** Persists verified material atomically (best effort). */
- (BOOL)storeTokenEnvelope:(NSData *)envelope
                      meta:(NSData *)meta
              refreshToken:(nullable NSString *)refreshToken;

/** Persists ONLY the anti-rollback metadata (clock + authenticated status). */
- (BOOL)storeEntitlementMeta:(NSData *)meta;

/** Removes token/metadata/refresh, keeping the installation UUID (binding survives). */
- (void)clearLicenseMaterial;

@end

NS_ASSUME_NONNULL_END
