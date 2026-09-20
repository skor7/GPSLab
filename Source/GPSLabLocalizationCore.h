//
//  GPSLabLocalizationCore.h
//  GPSLab
//
//  Pure-C bilingual catalog and numeric normalization core. This file has no
//  Foundation/UIKit dependency so it can be compiled both into the dylib and
//  into portable CI tests (Linux/macOS). The Objective-C wrapper
//  (GPSLabLocalization) is a thin layer over these functions.
//

#ifndef GPSLAB_LOCALIZATION_CORE_H
#define GPSLAB_LOCALIZATION_CORE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/** Supported UI languages. Arabic (0) is the default; see GPSLabLanguageResolve. */
typedef enum {
    GPSLabLanguageArabic = 0,
    GPSLabLanguageEnglish = 1,
} GPSLabLanguageCode;

/** One catalog row. Keys are stable ASCII identifiers; values are UTF-8. */
typedef struct {
    const char *key;
    const char *arabic;
    const char *english;
} GPSLabLocalizationEntry;

/** The embedded catalog and its entry count (defined in GPSLabLocalizationCore.c). */
extern const GPSLabLocalizationEntry kGPSLabLocalizationTable[];
extern const size_t kGPSLabLocalizationTableCount;

/**
 * Resolves a persisted language identifier to a supported language. Any value
 * other than an "en" prefix (case-insensitive) resolves to Arabic, so a missing
 * or invalid stored value is Arabic regardless of the host locale.
 */
GPSLabLanguageCode GPSLabLanguageResolve(const char *stored);

/** Returns the canonical persistence identifier: "ar" or "en". */
const char *GPSLabLanguageIdentifier(GPSLabLanguageCode language);

/**
 * Looks up a catalog key for a language. Falls back to English, then returns
 * NULL when the key is unknown. A NULL key returns NULL.
 */
const char *GPSLabLocalizationLookup(const char *key, GPSLabLanguageCode language);

/**
 * Normalizes a user-entered numeric string into an ASCII numeric string:
 *   * Arabic-Indic (U+0660..U+0669) and Extended Arabic-Indic (U+06F0..U+06F9)
 *     digits map to '0'..'9';
 *   * the Arabic decimal separator U+066B maps to '.', thousands U+066C is dropped;
 *   * the Unicode minus U+2212 maps to '-';
 *   * bidi control characters (U+200E/200F, U+202A..202E, U+2066..2069, U+061C)
 *     are removed; U+00A0 maps to a space.
 * Returns the written length (excluding the NUL terminator) or (size_t)-1 when
 * the result would not fit in `outputSize` bytes. `output` is always NUL
 * terminated on success.
 */
size_t GPSLabLocalizationNormalizeNumeric(const char *input, char *output, size_t outputSize);

/**
 * Strictly parses a complete numeric string after normalization. The whole
 * input must be consumed, only [0-9 + - . e E] and non-ASCII digits mapped by
 * normalization are accepted, and the result must be finite. Returns 1 on
 * success and writes the value; returns 0 for empty, partial or non-finite
 * input. Valid ASCII inputs are preserved.
 */
int GPSLabLocalizationParseNumber(const char *input, double *output);

#ifdef __cplusplus
}
#endif

#endif /* GPSLAB_LOCALIZATION_CORE_H */
