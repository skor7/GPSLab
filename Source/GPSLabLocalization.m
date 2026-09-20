//
//  GPSLabLocalization.m
//  GPSLab
//
//  Foundation-only wrapper over the embedded C catalog. UIKit helpers are
//  compiled only for iOS so the same file can be linked by the macOS CI tests.
//

#import "GPSLabLocalization.h"

#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#endif

NSNotificationName const GPSLabLanguageDidChangeNotification = @"com.gpslab.language.didChange";

static NSString * const kGPSLabLanguageSuiteName = @"com.gpslab.runtime";
static NSString * const kGPSLabLanguageDefaultsKey = @"GPSLab.language";

@implementation GPSLabLocalization

#pragma mark - Defaults

+ (NSUserDefaults *)gpslab_defaults {
    NSUserDefaults *scoped = [[NSUserDefaults alloc] initWithSuiteName:kGPSLabLanguageSuiteName];
    return scoped ?: [NSUserDefaults standardUserDefaults];
}

#pragma mark - Language

+ (GPSLabLanguageCode)languageForStoredValue:(NSString *)value {
    return GPSLabLanguageResolve(value.UTF8String);
}

+ (GPSLabLanguageCode)currentLanguageInDefaults:(NSUserDefaults *)defaults {
    NSString *stored = [defaults stringForKey:kGPSLabLanguageDefaultsKey];
    return [self languageForStoredValue:stored];
}

+ (NSString *)identifierForLanguage:(GPSLabLanguageCode)language {
    return [NSString stringWithUTF8String:GPSLabLanguageIdentifier(language)];
}

+ (void)setLanguage:(GPSLabLanguageCode)language inDefaults:(NSUserDefaults *)defaults {
    GPSLabLanguageCode resolved = (language == GPSLabLanguageEnglish) ? GPSLabLanguageEnglish
                                                                      : GPSLabLanguageArabic;
    [defaults setObject:[self identifierForLanguage:resolved] forKey:kGPSLabLanguageDefaultsKey];
}

+ (GPSLabLanguageCode)currentLanguage {
    return [self currentLanguageInDefaults:[self gpslab_defaults]];
}

+ (void)setLanguage:(GPSLabLanguageCode)language {
    [self setLanguage:language inDefaults:[self gpslab_defaults]];
    void (^notify)(void) = ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:GPSLabLanguageDidChangeNotification
                                                           object:self];
    };
    if ([NSThread isMainThread]) {
        notify();
    } else {
        dispatch_async(dispatch_get_main_queue(), notify);
    }
}

+ (NSString *)languageIdentifier {
    return [self identifierForLanguage:[self currentLanguage]];
}

#pragma mark - Catalog

+ (NSString *)stringForKey:(NSString *)key language:(GPSLabLanguageCode)language {
    if (key.length == 0) {
        return @"";
    }
    const char *value = GPSLabLocalizationLookup(key.UTF8String, language);
    if (value == NULL) {
        return key;
    }
    NSString *localized = [NSString stringWithUTF8String:value];
    return localized ?: key;
}

+ (NSString *)stringForKey:(NSString *)key {
    return [self stringForKey:key language:[self currentLanguage]];
}

+ (NSArray<NSString *> *)allKeys {
    NSMutableArray<NSString *> *keys = [NSMutableArray arrayWithCapacity:kGPSLabLocalizationTableCount];
    for (size_t index = 0; index < kGPSLabLocalizationTableCount; index++) {
        const char *key = kGPSLabLocalizationTable[index].key;
        if (key == NULL) {
            continue;
        }
        NSString *string = [NSString stringWithUTF8String:key];
        if (string != nil) {
            [keys addObject:string];
        }
    }
    return keys;
}

#pragma mark - Numeric input

+ (NSString *)normalizedNumericInput:(NSString *)input {
    if (input.length == 0) {
        return @"";
    }
    char buffer[256];
    size_t length = GPSLabLocalizationNormalizeNumeric(input.UTF8String, buffer, sizeof(buffer));
    if (length == (size_t)-1) {
        return input;
    }
    NSString *normalized = [NSString stringWithUTF8String:buffer];
    return normalized ?: input;
}

+ (BOOL)parseNumber:(NSString *)input value:(double *)outValue {
    if (outValue == NULL || input == nil) {
        return NO;
    }
    double value = 0.0;
    if (!GPSLabLocalizationParseNumber(input.UTF8String, &value)) {
        return NO;
    }
    *outValue = value;
    return YES;
}

+ (NSString *)decimalString:(double)value fractionDigits:(NSInteger)fractionDigits {
    NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.numberStyle = NSNumberFormatterDecimalStyle;
    formatter.usesGroupingSeparator = NO;
    NSInteger digits = fractionDigits < 0 ? 0 : fractionDigits;
    formatter.minimumFractionDigits = (NSUInteger)digits;
    formatter.maximumFractionDigits = (NSUInteger)digits;
    NSString *string = [formatter stringFromNumber:@(value)];
    if (string.length > 0) {
        return string;
    }
    return [NSString stringWithFormat:@"%.*f", (int)digits, value];
}

+ (NSString *)coordinateStringWithLatitude:(double)latitude longitude:(double)longitude {
    NSString *lat = [self decimalString:latitude fractionDigits:5];
    NSString *lon = [self decimalString:longitude fractionDigits:5];
    return [NSString stringWithFormat:@"%@, %@", lat, lon];
}

#if TARGET_OS_IPHONE

+ (void)applyLanguageAttributesToView:(UIView *)view {
    if (view == nil) {
        return;
    }
    view.semanticContentAttribute = ([self currentLanguage] == GPSLabLanguageArabic)
        ? UISemanticContentAttributeForceRightToLeft
        : UISemanticContentAttributeForceLeftToRight;
}

+ (void)forceLeftToRight:(UIView *)view {
    if (view == nil) {
        return;
    }
    view.semanticContentAttribute = UISemanticContentAttributeForceLeftToRight;
}

#endif

@end
