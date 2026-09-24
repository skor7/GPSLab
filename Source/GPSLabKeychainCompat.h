//
//  GPSLabKeychainCompat.h
//  GPSLab
//
//  Process-wide Keychain access-group compatibility hook: the in-process port of
//  the operator's standalone, on-device-verified KeychainFix. fishhook rebinds the
//  four Security.framework Keychain entry points and every query/attribute
//  dictionary has kSecAttrAccessGroup stripped from a copy before the original
//  implementation runs.
//
//  Semantics are deliberately UNCONDITIONAL. Once GPSLab is loaded the hook is
//  installed for the whole process and is never gated by the synthetic-engine
//  switch or the license state; it is the exact behaviour the standalone
//  KeychainFix.dylib provides and nothing here weakens or extends it.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Installs the Keychain access-group compatibility hook exactly once.
///
/// Idempotent and safe to call from multiple threads: the first call performs
/// the fishhook rebinding, every later call is a no-op. Call it before any
/// Keychain access so no access-group query escapes the cleaner.
///
/// The symbol is hidden: it is an internal dylib entry point, not part of any
/// exported C ABI.
///
/// @return YES when the hook is installed (or was already installed).
__attribute__((visibility("hidden")))
BOOL GPSLabKeychainCompatInstall(void);

NS_ASSUME_NONNULL_END
