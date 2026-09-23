/*
 * GPSLab localization core tests (portable C).
 *
 * These exercise Source/GPSLabLocalizationCore.c directly: the exact catalog and
 * numeric normalization compiled into the dylib. They do not re-implement the
 * logic and have no UIKit/Foundation dependency, so they run on any CI runner.
 *
 * Build/run:
 *   cc -I Source tests/gpslab_localization_test.c Source/GPSLabLocalizationCore.c -o loc_test && ./loc_test
 */

#include <math.h>
#include <stdio.h>
#include <string.h>

#include "GPSLabLocalizationCore.h"

static int gFailures = 0;
static int gChecks = 0;

#define CHECK(condition, message)                                                \
    do {                                                                         \
        gChecks++;                                                               \
        if (!(condition)) {                                                      \
            gFailures++;                                                         \
            fprintf(stderr, "FAIL: %s (%s:%d)\n", (message), __FILE__, __LINE__); \
        }                                                                        \
    } while (0)

static int nearly(double a, double b) {
    return fabs(a - b) < 1e-9;
}

static void test_catalog_complete(void) {
    CHECK(kGPSLabLocalizationTableCount > 100, "catalog has a realistic number of entries");
    for (size_t i = 0; i < kGPSLabLocalizationTableCount; i++) {
        const GPSLabLocalizationEntry *entry = &kGPSLabLocalizationTable[i];
        CHECK(entry->key != NULL && entry->key[0] != '\0', "every entry has a key");
        CHECK(entry->arabic != NULL && entry->arabic[0] != '\0', "every entry has Arabic text");
        CHECK(entry->english != NULL && entry->english[0] != '\0', "every entry has English text");
        for (size_t j = i + 1; j < kGPSLabLocalizationTableCount; j++) {
            if (strcmp(entry->key, kGPSLabLocalizationTable[j].key) == 0) {
                CHECK(0, "catalog keys are unique");
            }
        }
    }
}

static void test_language_resolution(void) {
    CHECK(GPSLabLanguageResolve(NULL) == GPSLabLanguageArabic, "missing language resolves to Arabic");
    CHECK(GPSLabLanguageResolve("") == GPSLabLanguageArabic, "empty language resolves to Arabic");
    CHECK(GPSLabLanguageResolve("ar") == GPSLabLanguageArabic, "ar resolves to Arabic");
    CHECK(GPSLabLanguageResolve("ar-SA") == GPSLabLanguageArabic, "ar-SA resolves to Arabic");
    CHECK(GPSLabLanguageResolve("fr") == GPSLabLanguageArabic, "unknown language resolves to Arabic");
    CHECK(GPSLabLanguageResolve("english") == GPSLabLanguageArabic,
          "non-prefix 'english' does not resolve to English");
    CHECK(GPSLabLanguageResolve("en") == GPSLabLanguageEnglish, "en resolves to English");
    CHECK(GPSLabLanguageResolve("EN") == GPSLabLanguageEnglish, "EN resolves to English");
    CHECK(GPSLabLanguageResolve("en-US") == GPSLabLanguageEnglish, "en-US resolves to English");
    CHECK(GPSLabLanguageResolve("en_GB") == GPSLabLanguageEnglish, "en_GB resolves to English");
    CHECK(strcmp(GPSLabLanguageIdentifier(GPSLabLanguageArabic), "ar") == 0, "Arabic identifier");
    CHECK(strcmp(GPSLabLanguageIdentifier(GPSLabLanguageEnglish), "en") == 0, "English identifier");
}

static void test_lookup(void) {
    const char *arabic = GPSLabLocalizationLookup("common.ok", GPSLabLanguageArabic);
    const char *english = GPSLabLocalizationLookup("common.ok", GPSLabLanguageEnglish);
    CHECK(arabic != NULL && english != NULL, "known key resolves in both languages");
    CHECK(arabic != english && strcmp(arabic, english) != 0, "languages differ for common.ok");
    CHECK(GPSLabLocalizationLookup("does.not.exist", GPSLabLanguageArabic) == NULL,
          "unknown key resolves to NULL");
    CHECK(GPSLabLocalizationLookup(NULL, GPSLabLanguageArabic) == NULL, "NULL key resolves to NULL");
}

/** The compact overlay drift row requires this exact localized label text. */
static void test_drift_range_catalog(void) {
    const char *english = GPSLabLocalizationLookup("panel.drift.range", GPSLabLanguageEnglish);
    const char *arabic = GPSLabLocalizationLookup("panel.drift.range", GPSLabLanguageArabic);
    CHECK(english != NULL && strcmp(english, "Drift range") == 0,
          "panel.drift.range resolves to the exact English label");
    CHECK(arabic != NULL &&
              strcmp(arabic, "\u0645\u062f\u0649 \u0627\u0644\u062a\u0630\u0628\u0630\u0628") == 0,
          "panel.drift.range resolves to the exact Arabic label");
}

static void test_normalization(void) {
    char buffer[64];

    CHECK(GPSLabLocalizationNormalizeNumeric("\u0661\u0662\u0663", buffer, sizeof(buffer)) == 3 &&
              strcmp(buffer, "123") == 0,
          "Arabic-Indic digits normalize to ASCII");
    CHECK(GPSLabLocalizationNormalizeNumeric("\u06F1\u06F2\u06F3", buffer, sizeof(buffer)) == 3 &&
              strcmp(buffer, "123") == 0,
          "Extended Arabic-Indic digits normalize to ASCII");
    CHECK(GPSLabLocalizationNormalizeNumeric("\u0661\u0662\u066B\u0665", buffer, sizeof(buffer)) == 4 &&
              strcmp(buffer, "12.5") == 0,
          "Arabic decimal separator normalizes to '.'");
    CHECK(GPSLabLocalizationNormalizeNumeric("\u0661\u066C\u0662\u0663\u0664", buffer, sizeof(buffer)) == 4 &&
              strcmp(buffer, "1234") == 0,
          "Arabic thousands separator is dropped");
    CHECK(GPSLabLocalizationNormalizeNumeric("\u200F12\u200E", buffer, sizeof(buffer)) == 2 &&
              strcmp(buffer, "12") == 0,
          "bidi control characters are removed");
    CHECK(GPSLabLocalizationNormalizeNumeric("\u22125", buffer, sizeof(buffer)) == 2 &&
              strcmp(buffer, "-5") == 0,
          "Unicode minus normalizes to '-'");
    CHECK(GPSLabLocalizationNormalizeNumeric("12.5", buffer, sizeof(buffer)) == 4 &&
              strcmp(buffer, "12.5") == 0,
          "valid ASCII is preserved");
    CHECK(GPSLabLocalizationNormalizeNumeric("1234567890", buffer, 4) == (size_t)-1,
          "overflow reports failure instead of truncating");
}

static void test_parse(void) {
    double value = 0.0;

    CHECK(GPSLabLocalizationParseNumber("12.5", &value) == 1 && nearly(value, 12.5),
          "plain decimal parses");
    CHECK(GPSLabLocalizationParseNumber("  -3.25  ", &value) == 1 && nearly(value, -3.25),
          "signed decimal with whitespace parses");
    CHECK(GPSLabLocalizationParseNumber("\u0661\u0662\u066B\u0665", &value) == 1 && nearly(value, 12.5),
          "Arabic-Indic decimal parses");
    CHECK(GPSLabLocalizationParseNumber("\u22125", &value) == 1 && nearly(value, -5.0),
          "Unicode minus parses");
    CHECK(GPSLabLocalizationParseNumber("1e3", &value) == 1 && nearly(value, 1000.0),
          "exponent parses");
    CHECK(GPSLabLocalizationParseNumber("12.", &value) == 1 && nearly(value, 12.0),
          "trailing decimal point parses");
    CHECK(GPSLabLocalizationParseNumber(".5", &value) == 1 && nearly(value, 0.5),
          "leading decimal point parses");

    CHECK(GPSLabLocalizationParseNumber("", &value) == 0, "empty input rejected");
    CHECK(GPSLabLocalizationParseNumber("   ", &value) == 0, "whitespace input rejected");
    CHECK(GPSLabLocalizationParseNumber("12abc", &value) == 0, "trailing garbage rejected");
    CHECK(GPSLabLocalizationParseNumber("abc", &value) == 0, "non-numeric rejected");
    CHECK(GPSLabLocalizationParseNumber("nan", &value) == 0, "nan rejected");
    CHECK(GPSLabLocalizationParseNumber("inf", &value) == 0, "inf rejected");
    CHECK(GPSLabLocalizationParseNumber("0x10", &value) == 0, "hex rejected");
    CHECK(GPSLabLocalizationParseNumber(".", &value) == 0, "lone decimal point rejected");
    CHECK(GPSLabLocalizationParseNumber("-", &value) == 0, "lone sign rejected");
    CHECK(GPSLabLocalizationParseNumber("1e400", &value) == 0, "overflow rejected");
    CHECK(GPSLabLocalizationParseNumber(NULL, &value) == 0, "NULL input rejected");
    CHECK(GPSLabLocalizationParseNumber("1", NULL) == 0, "NULL output rejected");
}

int main(void) {
    test_catalog_complete();
    test_language_resolution();
    test_lookup();
    test_drift_range_catalog();
    test_normalization();
    test_parse();

    if (gFailures == 0) {
        printf("gpslab_localization_test: %d checks passed\n", gChecks);
        return 0;
    }
    fprintf(stderr, "gpslab_localization_test: %d/%d checks failed\n", gFailures, gChecks);
    return 1;
}
