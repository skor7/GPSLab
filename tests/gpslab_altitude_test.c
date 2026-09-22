/*
 * GPSLab altitude field tests (portable C).
 *
 * The altitude editor reuses the shared numeric parser
 * (GPSLabLocalizationParseNumber) and the shared range policy
 * (GPSLabProfileAltitudeValid). These tests pin the exact behaviour the editor
 * relies on: signed/zero/fractional input, Arabic-Indic digits, rejection of
 * empty/partial/non-finite input, and NO clamping at parse time.
 *
 * Build/run:
 *   cc -I Source tests/gpslab_altitude_test.c Source/GPSLabLocalizationCore.c \
 *     Source/GPSLabProfileCore.c -o /tmp/gpslab_altitude_test && /tmp/gpslab_altitude_test
 */

#include <math.h>
#include <stdio.h>
#include <string.h>

#include "GPSLabLocalizationCore.h"
#include "GPSLabProfileCore.h"

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

static void test_parse(void) {
    double value = 0.0;
    CHECK(GPSLabLocalizationParseNumber("736", &value) && value == 736.0, "positive integer");
    CHECK(GPSLabLocalizationParseNumber("-12.5", &value) && value == -12.5, "negative fraction");
    CHECK(GPSLabLocalizationParseNumber("0", &value) && value == 0.0, "zero");
    CHECK(GPSLabLocalizationParseNumber("+42", &value) && value == 42.0, "explicit plus sign");
    // Arabic-Indic digits and the Unicode minus normalise to ASCII.
    CHECK(GPSLabLocalizationParseNumber("\u0664\u0662", &value) && value == 42.0,
          "Arabic-Indic digits");
    CHECK(GPSLabLocalizationParseNumber("\u2212\u0667\u0663\u0666", &value) && value == -736.0,
          "Unicode minus with Arabic-Indic digits");
}

static void test_reject(void) {
    double value = 0.0;
    CHECK(!GPSLabLocalizationParseNumber("", &value), "empty rejected");
    CHECK(!GPSLabLocalizationParseNumber("   ", &value), "whitespace rejected");
    CHECK(!GPSLabLocalizationParseNumber("abc", &value), "text rejected");
    CHECK(!GPSLabLocalizationParseNumber("12abc", &value), "trailing garbage rejected");
    CHECK(!GPSLabLocalizationParseNumber("nan", &value), "nan rejected");
    CHECK(!GPSLabLocalizationParseNumber("inf", &value), "inf rejected");
    CHECK(!GPSLabLocalizationParseNumber("-inf", &value), "-inf rejected");
    CHECK(!GPSLabLocalizationParseNumber("0x10", &value), "hex rejected");
}

static void test_no_clamp_at_parse(void) {
    // The parser does not clamp: range policy is owned by the engine/profile
    // path (GPSLabProfileAltitudeValid), not silently applied while typing.
    double value = 0.0;
    CHECK(GPSLabLocalizationParseNumber("999999", &value) && value == 999999.0,
          "large finite value parses unclamped");
    CHECK(GPSLabProfileAltitudeValid(999999.0) == 0, "range policy still rejects 999999");
}

static void test_range_policy(void) {
    CHECK(GPSLabProfileAltitudeValid(0.0) == 1, "zero valid");
    CHECK(GPSLabProfileAltitudeValid(612.0) == 1, "positive valid");
    CHECK(GPSLabProfileAltitudeValid(-500.0) == 1, "minimum valid");
    CHECK(GPSLabProfileAltitudeValid(100000.0) == 1, "maximum valid");
    CHECK(GPSLabProfileAltitudeValid(-500.1) == 0, "below minimum rejected");
    CHECK(GPSLabProfileAltitudeValid(100000.1) == 0, "above maximum rejected");
    CHECK(GPSLabProfileAltitudeValid(NAN) == 0, "NaN rejected");
    CHECK(GPSLabProfileAltitudeValid(INFINITY) == 0, "infinite rejected");
}

int main(void) {
    test_parse();
    test_reject();
    test_no_clamp_at_parse();
    test_range_policy();

    if (gFailures == 0) {
        printf("gpslab_altitude_test: %d checks passed\n", gChecks);
        return 0;
    }
    fprintf(stderr, "gpslab_altitude_test: %d/%d checks failed\n", gFailures, gChecks);
    return 1;
}
