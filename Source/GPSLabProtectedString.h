//
//  GPSLabProtectedString.h
//  GPSLab
//
//  Production-only decoding of implementation-revealing CLIENT literals.
//
//  Usage:
//
//      #import "GPSLabProtectedString.h"
//      ...
//      #define kGPSLabAccountInstallation GPSLAB_PROTECTED_STRING(KeychainAccountInstallation)
//
//  The literal is declared once in Source/GPSLabProtectedStrings.def and encoded
//  by scripts/gen_protected_strings.py into the generated header imported below.
//
//    DEV (default)  GPSLAB_PROTECTED_STRING(Symbol) -> the readable plaintext.
//    PRODUCTION     GPSLAB_PROTECTED_STRING(Symbol) -> runtime decode of the blob.
//
//  The macro is an expression, not a compile-time constant: use it inside method
//  bodies (or a `#define` that is only expanded inside a method), never as the
//  initializer of a file-scope `static NSString * const`.
//
//  Only use it for client implementation detail (storage namespaces, Keychain
//  service/account identifiers, internal subsystem labels, persistence keys).
//  Never for UI/legal/localization copy, and never for selectors, class names,
//  notification names or error domains that are part of the runtime API contract.
//

#ifndef GPSLAB_PROTECTED_STRING_H
#define GPSLAB_PROTECTED_STRING_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * Decodes an XOR-obfuscated UTF-8 blob into a fresh NSString.
 *
 * Returns nil when `blob` is NULL/empty, when the allocation fails, or when the
 * decoded bytes are not valid UTF-8. The intermediate buffer is scrubbed before
 * it is freed.
 */
FOUNDATION_EXPORT NSString * _Nullable GPSLabProtectedStringDecode(const unsigned char * _Nullable blob,
                                                                  NSUInteger length,
                                                                  unsigned char key);

NS_ASSUME_NONNULL_END

/* Defines GPSLAB_PROTECTED_STRING (mode-dependent) and the encoded blobs. */
#import "GPSLabProtectedStringsGenerated.h"

#endif /* GPSLAB_PROTECTED_STRING_H */
