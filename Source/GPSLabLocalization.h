//
//  GPSLabLocalization.h
//  GPSLab
//
//  Foundation-only localization wrapper around the embedded C catalog. The
//  catalog ships inside the dylib, so no host main-bundle `.strings`/`.lproj`
//  resource is required. Arabic is the default; the choice is persisted under
//  the GPSLab-owned suite key and never mutates the process-wide language list.
//

#import <Foundation/Foundation.h>

#import "GPSLabLocalizationCore.h"

#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#endif

NS_ASSUME_NONNULL_BEGIN

/** Posted after the language changes. Observers re-apply their own strings. */
FOUNDATION_EXPORT NSNotificationName const GPSLabLanguageDidChangeNotification;

/** Convenience accessor for the current language. */
#define GPSLabLocalized(key) [GPSLabLocalization stringForKey:(key)]

@interface GPSLabLocalization : NSObject

#pragma mark - Language

/** Current UI language; Arabic unless a valid persisted value exists. */
+ (GPSLabLanguageCode)currentLanguage;

/** Persists and broadcasts a language change (main thread). Whitelist: ar/en. */
+ (void)setLanguage:(GPSLabLanguageCode)language;

/** Pure resolver: Arabic unless the value is an "en" identifier. */
+ (GPSLabLanguageCode)languageForStoredValue:(nullable NSString *)value;

/** Canonical persistence identifier for the current language ("ar"/"en"). */
+ (NSString *)languageIdentifier;

/** Canonical persistence identifier for an explicit language. */
+ (NSString *)identifierForLanguage:(GPSLabLanguageCode)language;

/** Testable variants that operate on an injected defaults instance. */
+ (GPSLabLanguageCode)currentLanguageInDefaults:(NSUserDefaults *)defaults;
+ (void)setLanguage:(GPSLabLanguageCode)language inDefaults:(NSUserDefaults *)defaults;

#pragma mark - Catalog

/** Localized string for the current language; missing keys fall back to the key. */
+ (NSString *)stringForKey:(NSString *)key;

/** Localized string for an explicit language; missing keys fall back to the key. */
+ (NSString *)stringForKey:(NSString *)key language:(GPSLabLanguageCode)language;

/** Every catalog key. Used by tests to prove completeness of both languages. */
+ (NSArray<NSString *> *)allKeys;

#pragma mark - Numeric input

/** Normalizes Arabic-Indic digits/separators and bidi marks to ASCII. */
+ (NSString *)normalizedNumericInput:(NSString *)input;

/**
 * Strict parse of a complete numeric field value (full consumption, finite).
 * Arabic-Indic and Extended Arabic-Indic digits are normalized first; valid
 * ASCII inputs are preserved. Returns NO for empty/partial/non-finite input.
 */
+ (BOOL)parseNumber:(nullable NSString *)input value:(double *_Nonnull)outValue;

/** POSIX/LTR decimal formatting (Latin digits, "." decimal) for coordinates. */
+ (NSString *)decimalString:(double)value fractionDigits:(NSInteger)fractionDigits;

/** decimalString: with trailing zeros (and a bare ".") trimmed. */
+ (NSString *)trimmedDecimalString:(double)value fractionDigits:(NSInteger)fractionDigits;

/** POSIX/LTR "lat, lon" readable string; map coordinate updates are unchanged. */
+ (NSString *)coordinateStringWithLatitude:(double)latitude longitude:(double)longitude;

#if TARGET_OS_IPHONE
/** Applies the catalog language direction to a GPSLab-owned view subtree. */
+ (void)applyLanguageAttributesToView:(UIView *)view;
/** Forces LTR for geography/numeric content (maps are never physically mirrored). */
+ (void)forceLeftToRight:(UIView *)view;
#endif

@end

NS_ASSUME_NONNULL_END
