//
//  GPSLabProtectedStringCore.h
//  GPSLab
//
//  Pure C XOR decode used by the production-only protected-string facility.
//  No Foundation, no allocation: it decodes into a caller-provided buffer, so it
//  is compiled into the dylib AND into the portable CI test (see
//  tests/gpslab_protected_strings_test.c).
//

#ifndef GPSLAB_PROTECTED_STRING_CORE_H
#define GPSLAB_PROTECTED_STRING_CORE_H

#include <stddef.h>

/**
 * XOR-decodes `length` bytes of `blob` with `key` into `out`.
 *
 * `out` must have room for at least `length` bytes. A NULL `blob`/`out` or a
 * zero `length` is a no-op (fail closed). This is obfuscation, not cryptography.
 */
void GPSLabProtectedStringDecodeBytes(const unsigned char *blob,
                                      size_t length,
                                      unsigned char key,
                                      unsigned char *out);

#endif /* GPSLAB_PROTECTED_STRING_CORE_H */
