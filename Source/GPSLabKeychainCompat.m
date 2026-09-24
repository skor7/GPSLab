//
//  GPSLabKeychainCompat.m
//  GPSLab
//
//  Near-verbatim port of the operator's on-device-verified standalone
//  KeychainFix (fishhook-based C rebinding of SecItemCopyMatching / SecItemAdd /
//  SecItemUpdate / SecItemDelete; every dictionary copy has kSecAttrAccessGroup
//  removed). It is installed explicitly and idempotently from the GPSLab dylib
//  constructor, before the license manager performs any Keychain access.
//
//  Provenance: the vendored Source/fishhook.{c,h} are byte-for-byte upstream
//  facebook/fishhook (BSD-3). The hook bodies below preserve the verified
//  standalone semantics exactly:
//    * the caller's dictionaries are never mutated (a copy is cleaned instead);
//    * the cleaned copy carries +1 and is balanced with CFRelease after the call;
//    * the original OSStatus is returned unchanged;
//    * a NULL dictionary is forwarded unchanged.
//
//  Initialization / dyld notes (deliberate and audited):
//    * fishhook registers its add-image callback on the first rebind and then
//      rewrites the lazy/non-lazy symbol pointers of every already-loaded image
//      (and every future image). SecItem* are called through those pointers, so
//      installing from the constructor covers this dylib and the host app.
//    * dispatch_once makes the install exactly-once even if it is reached from
//      several threads; the fishhook rebinding list is therefore built once and
//      never mutated again by GPSLab.
//    * the hook only touches CoreFoundation and Security, so a Keychain call made
//      while the license manager is starting up cannot loop back into the
//      constructor.
//
//  Nothing here is gated by the synthetic-engine switch or the license state.
//

#import "GPSLabKeychainCompat.h"

#import <Security/Security.h>

#import "fishhook.h"

// Original function pointers captured by fishhook.
static OSStatus (*orig_SecItemCopyMatching)(CFDictionaryRef query, CFTypeRef *result);
static OSStatus (*orig_SecItemAdd)(CFDictionaryRef attributes, CFTypeRef *result);
static OSStatus (*orig_SecItemUpdate)(CFDictionaryRef query, CFDictionaryRef attributesToUpdate);
static OSStatus (*orig_SecItemDelete)(CFDictionaryRef query);

// Universal cleaner: strips kSecAttrAccessGroup from any dictionary.
static CFDictionaryRef clean_keychain_query(CFDictionaryRef dict) {
    if (!dict) return NULL;

    NSDictionary *nsDict = (__bridge NSDictionary *)dict;
    if (nsDict[(__bridge id)kSecAttrAccessGroup]) {
        NSMutableDictionary *mutableDict = [nsDict mutableCopy];
        [mutableDict removeObjectForKey:(__bridge id)kSecAttrAccessGroup];
        return CFBridgingRetain(mutableDict);
    }
    return (CFDictionaryRef)CFRetain(dict);
}

// Hooked functions.
static OSStatus my_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    CFDictionaryRef cleaned = clean_keychain_query(query);
    OSStatus status = orig_SecItemCopyMatching(cleaned ? cleaned : query, result);
    if (cleaned) CFRelease(cleaned);
    return status;
}

static OSStatus my_SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    CFDictionaryRef cleaned = clean_keychain_query(attributes);
    OSStatus status = orig_SecItemAdd(cleaned ? cleaned : attributes, result);
    if (cleaned) CFRelease(cleaned);
    return status;
}

static OSStatus my_SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) {
    CFDictionaryRef cleanQuery = clean_keychain_query(query);
    CFDictionaryRef cleanAttrs = clean_keychain_query(attributesToUpdate);

    OSStatus status = orig_SecItemUpdate(cleanQuery ? cleanQuery : query,
                                         cleanAttrs ? cleanAttrs : attributesToUpdate);

    if (cleanQuery) CFRelease(cleanQuery);
    if (cleanAttrs) CFRelease(cleanAttrs);
    return status;
}

static OSStatus my_SecItemDelete(CFDictionaryRef query) {
    CFDictionaryRef cleaned = clean_keychain_query(query);
    OSStatus status = orig_SecItemDelete(cleaned ? cleaned : query);
    if (cleaned) CFRelease(cleaned);
    return status;
}

static dispatch_once_t gGPSLabKeychainCompatOnce;
static BOOL gGPSLabKeychainCompatInstalled = NO;

__attribute__((visibility("hidden")))
BOOL GPSLabKeychainCompatInstall(void) {
    dispatch_once(&gGPSLabKeychainCompatOnce, ^{
        struct rebinding rebindings[] = {
            {"SecItemCopyMatching", (void *)my_SecItemCopyMatching, (void **)&orig_SecItemCopyMatching},
            {"SecItemAdd", (void *)my_SecItemAdd, (void **)&orig_SecItemAdd},
            {"SecItemUpdate", (void *)my_SecItemUpdate, (void **)&orig_SecItemUpdate},
            {"SecItemDelete", (void *)my_SecItemDelete, (void **)&orig_SecItemDelete}
        };

        gGPSLabKeychainCompatInstalled =
            (rebind_symbols(rebindings, sizeof(rebindings) / sizeof(struct rebinding)) == 0);
    });
    return gGPSLabKeychainCompatInstalled;
}
