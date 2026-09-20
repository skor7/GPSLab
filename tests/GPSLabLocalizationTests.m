//
//  GPSLabLocalizationTests.m
//  GPSLab
//
//  Real Foundation tests for the GPSLab localization wrapper: catalog
//  completeness, Arabic default, invalid-language fallback, missing-key
//  fallback, numeric normalization/parse and language persistence in an
//  isolated NSUserDefaults suite. No UIKit; runs on macOS CI.
//
//  Build/run (macOS):
//    clang -fobjc-arc -fmodules -framework Foundation -ISource \
//      tests/GPSLabLocalizationTests.m Source/GPSLabLocalization.m \
//      Source/GPSLabLocalizationCore.c -o /tmp/gpslab-localization-tests
//    /tmp/gpslab-localization-tests
//

#import <Foundation/Foundation.h>

#include <math.h>

#import "GPSLabLocalization.h"

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

static int nearly(double a, double b) {
    return fabs(a - b) < 1e-9;
}

int main(void) {
    @autoreleasepool {
        // Isolated defaults so the test never touches real user state.
        NSString *suiteName = [NSString stringWithFormat:@"gpslab.localization.tests.%@",
                               [[NSUUID UUID] UUIDString]];
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suiteName];
        CHECK(defaults != nil, @"isolated defaults created");

        // 1) Missing stored value is Arabic regardless of the host locale.
        [defaults removeObjectForKey:@"GPSLab.language"];
        CHECK([GPSLabLocalization currentLanguageInDefaults:defaults] == GPSLabLanguageArabic,
              @"missing stored language is Arabic");
        CHECK([GPSLabLocalization languageForStoredValue:nil] == GPSLabLanguageArabic,
              @"nil stored value is Arabic");
        CHECK([GPSLabLocalization languageForStoredValue:@"de"] == GPSLabLanguageArabic,
              @"invalid stored value is Arabic");
        CHECK([GPSLabLocalization languageForStoredValue:@"en-US"] == GPSLabLanguageEnglish,
              @"en-US stored value is English");

        // 2) Persistence round-trip in the injected suite.
        [GPSLabLocalization setLanguage:GPSLabLanguageEnglish inDefaults:defaults];
        CHECK([GPSLabLocalization currentLanguageInDefaults:defaults] == GPSLabLanguageEnglish,
              @"English choice persists");
        [GPSLabLocalization setLanguage:GPSLabLanguageArabic inDefaults:defaults];
        CHECK([GPSLabLocalization currentLanguageInDefaults:defaults] == GPSLabLanguageArabic,
              @"Arabic choice persists");

        // 3) Catalog completeness + missing-key fallback.
        NSArray<NSString *> *keys = [GPSLabLocalization allKeys];
        CHECK(keys.count > 100, @"catalog exposes a realistic number of keys");
        for (NSString *key in keys) {
            NSString *arabic = [GPSLabLocalization stringForKey:key language:GPSLabLanguageArabic];
            NSString *english = [GPSLabLocalization stringForKey:key language:GPSLabLanguageEnglish];
            CHECK(arabic.length > 0, @"Arabic value present for every key");
            CHECK(english.length > 0, @"English value present for every key");
        }
        NSString *missing = [GPSLabLocalization stringForKey:@"does.not.exist"
                                                    language:GPSLabLanguageArabic];
        CHECK([missing isEqualToString:@"does.not.exist"], @"missing key falls back to the key");

        // 4) Numeric normalization + strict parse through the wrapper.
        CHECK([[GPSLabLocalization normalizedNumericInput:@"\u0661\u0662\u0663"] isEqualToString:@"123"],
              @"wrapper normalizes Arabic-Indic digits");
        double value = 0.0;
        CHECK([GPSLabLocalization parseNumber:@"\u0661\u0662\u066B\u0665" value:&value] && nearly(value, 12.5),
              @"wrapper parses Arabic-Indic decimal");
        CHECK(![GPSLabLocalization parseNumber:@"12abc" value:&value],
              @"wrapper rejects trailing garbage");
        CHECK(![GPSLabLocalization parseNumber:@"nan" value:&value], @"wrapper rejects nan");

        // 5) Coordinates always use POSIX/LTR formatting.
        CHECK([[GPSLabLocalization decimalString:12.5 fractionDigits:1] isEqualToString:@"12.5"],
              @"decimalString uses '.'");
        CHECK([[GPSLabLocalization coordinateStringWithLatitude:1.5 longitude:2.25]
                  isEqualToString:@"1.50000, 2.25000"],
              @"coordinateString is POSIX readable");

        // 6) Identifier helpers.
        CHECK([[GPSLabLocalization identifierForLanguage:GPSLabLanguageArabic] isEqualToString:@"ar"],
              @"Arabic identifier is ar");
        CHECK([[GPSLabLocalization identifierForLanguage:GPSLabLanguageEnglish] isEqualToString:@"en"],
              @"English identifier is en");

        [defaults removePersistentDomainForName:suiteName];
    }

    if (gFailures == 0) {
        printf("GPSLabLocalizationTests: %d checks passed\n", gChecks);
        return 0;
    }
    fprintf(stderr, "GPSLabLocalizationTests: %d/%d checks failed\n", gFailures, gChecks);
    return 1;
}
