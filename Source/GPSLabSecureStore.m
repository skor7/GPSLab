//
//  GPSLabSecureStore.m
//  GPSLab
//
//  Keychain-backed storage for license material. Only the Keychain is used; the
//  user-defaults store is never touched.
//

#import "GPSLabSecureStore.h"

#import <Security/Security.h>

static NSString * const kGPSLabKeychainService = @"com.gpslab.runtime.license";
static NSString * const kGPSLabAccountInstallation = @"installationUUID";
static NSString * const kGPSLabAccountToken = @"tokenEnvelope";
static NSString * const kGPSLabAccountMeta = @"entitlementMeta";
static NSString * const kGPSLabAccountRefresh = @"refreshToken";
static NSString * const kGPSLabAccountDeviceSecret = @"deviceSecret";

static const NSUInteger kGPSLabDeviceSecretBytes = 32;

@implementation GPSLabSecureStore

+ (instancetype)sharedStore {
    static GPSLabSecureStore *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[GPSLabSecureStore alloc] init];
    });
    return instance;
}

#pragma mark - Generic helpers

- (NSMutableDictionary *)baseQueryForAccount:(NSString *)account {
    return [@{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kGPSLabKeychainService,
        (__bridge id)kSecAttrAccount: account,
    } mutableCopy];
}

- (nullable NSData *)dataForAccount:(NSString *)account {
    NSMutableDictionary *query = [self baseQueryForAccount:account];
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;

    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status != errSecSuccess || result == NULL) {
        return nil;
    }
    return CFBridgingRelease(result);
}

- (BOOL)setData:(NSData *)data forAccount:(NSString *)account {
    if (data.length == 0) {
        [self removeAccount:account];
        return YES;
    }

    NSMutableDictionary *query = [self baseQueryForAccount:account];
    NSDictionary *attributes = @{
        (__bridge id)kSecValueData: data,
        (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    };

    OSStatus updateStatus = SecItemUpdate((__bridge CFDictionaryRef)query,
                                          (__bridge CFDictionaryRef)attributes);
    if (updateStatus == errSecSuccess) {
        return YES;
    }
    if (updateStatus != errSecItemNotFound) {
        return NO;
    }

    NSMutableDictionary *addQuery = [self baseQueryForAccount:account];
    [addQuery addEntriesFromDictionary:attributes];
    return SecItemAdd((__bridge CFDictionaryRef)addQuery, NULL) == errSecSuccess;
}

- (void)removeAccount:(NSString *)account {
    NSMutableDictionary *query = [self baseQueryForAccount:account];
    SecItemDelete((__bridge CFDictionaryRef)query);
}

#pragma mark - Public

- (NSString *)installationUUID {
    NSData *stored = [self dataForAccount:kGPSLabAccountInstallation];
    if (stored.length > 0) {
        NSString *value = [[NSString alloc] initWithData:stored encoding:NSUTF8StringEncoding];
        if (value.length > 0) {
            return value;
        }
    }

    NSString *generated = [NSUUID UUID].UUIDString;
    NSData *encoded = [generated dataUsingEncoding:NSUTF8StringEncoding];
    if (![self setData:encoded forAccount:kGPSLabAccountInstallation]) {
        // Keychain unavailable: still return a per-process value so binding checks fail
        // closed rather than silently accept anything.
        return generated;
    }
    return generated;
}

- (NSData *)tokenEnvelope {
    return [self dataForAccount:kGPSLabAccountToken];
}

- (NSData *)entitlementMeta {
    return [self dataForAccount:kGPSLabAccountMeta];
}

- (NSString *)refreshToken {
    NSData *data = [self dataForAccount:kGPSLabAccountRefresh];
    if (data.length == 0) {
        return nil;
    }
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

- (NSData *)deviceSecret {
    NSData *stored = [self dataForAccount:kGPSLabAccountDeviceSecret];
    if (stored.length == kGPSLabDeviceSecretBytes) {
        return stored;
    }

    NSMutableData *generated = [NSMutableData dataWithLength:kGPSLabDeviceSecretBytes];
    if (generated == nil ||
        SecRandomCopyBytes(kSecRandomDefault, kGPSLabDeviceSecretBytes, generated.mutableBytes) != errSecSuccess) {
        return nil;
    }
    NSData *secret = [generated copy];
    if (![self setData:secret forAccount:kGPSLabAccountDeviceSecret]) {
        // FAIL CLOSED: an ephemeral secret would not survive a restart, so the
        // device could later present a value that no longer matches what it
        // enrolled first (a silent trust-on-first-use mismatch). Return nil (no
        // proof) rather than a value that is lost on the next launch.
        return nil;
    }
    return secret;
}

- (NSString *)deviceSecretBase64 {
    NSData *secret = [self deviceSecret];
    if (secret.length == 0) {
        return nil;
    }
    return [secret base64EncodedStringWithOptions:0];
}

- (BOOL)storeTokenEnvelope:(NSData *)envelope meta:(NSData *)meta refreshToken:(NSString *)refreshToken {
    BOOL ok = [self setData:envelope forAccount:kGPSLabAccountToken];
    ok = [self setData:meta forAccount:kGPSLabAccountMeta] && ok;
    if (refreshToken.length > 0) {
        ok = [self setData:[refreshToken dataUsingEncoding:NSUTF8StringEncoding]
                forAccount:kGPSLabAccountRefresh] && ok;
    } else {
        [self removeAccount:kGPSLabAccountRefresh];
    }
    return ok;
}

- (BOOL)storeEntitlementMeta:(NSData *)meta {
    return [self setData:meta forAccount:kGPSLabAccountMeta];
}

- (void)clearLicenseMaterial {
    [self removeAccount:kGPSLabAccountToken];
    [self removeAccount:kGPSLabAccountMeta];
    [self removeAccount:kGPSLabAccountRefresh];
}

@end
