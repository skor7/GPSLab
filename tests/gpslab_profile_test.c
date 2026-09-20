/*
 * GPSLab profile schema/validation tests (portable C).
 *
 * Exercises Source/GPSLabProfileCore.c directly — the exact validation compiled
 * into the dylib. No Foundation/UIKit dependency, so it runs on any CI runner.
 *
 * Build/run:
 *   cc -I Source tests/gpslab_profile_test.c Source/GPSLabProfileCore.c -o profile_test && ./profile_test
 */

#include <math.h>
#include <stdio.h>
#include <string.h>

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

static void test_coordinates(void) {
    CHECK(GPSLabProfileCoordinateValid(0.0, 0.0) == 1, "origin is valid");
    CHECK(GPSLabProfileCoordinateValid(90.0, 180.0) == 1, "positive bounds valid");
    CHECK(GPSLabProfileCoordinateValid(-90.0, -180.0) == 1, "negative bounds valid");
    CHECK(GPSLabProfileCoordinateValid(90.0001, 0.0) == 0, "latitude above 90 rejected");
    CHECK(GPSLabProfileCoordinateValid(-90.0001, 0.0) == 0, "latitude below -90 rejected");
    CHECK(GPSLabProfileCoordinateValid(0.0, 180.0001) == 0, "longitude above 180 rejected");
    CHECK(GPSLabProfileCoordinateValid(0.0, -180.0001) == 0, "longitude below -180 rejected");
    CHECK(GPSLabProfileCoordinateValid(NAN, 0.0) == 0, "NaN latitude rejected");
    CHECK(GPSLabProfileCoordinateValid(0.0, INFINITY) == 0, "infinite longitude rejected");

    int valid = 0;
    for (int lat = -100; lat <= 100; lat++) {
        if (GPSLabProfileCoordinateValid((double)lat, 0.0)) {
            valid++;
        }
    }
    CHECK(valid == 181, "only -90..90 latitudes are valid");
}

static void test_altitude_heading(void) {
    CHECK(GPSLabProfileAltitudeValid(-500.0) == 1, "min altitude valid");
    CHECK(GPSLabProfileAltitudeValid(100000.0) == 1, "max altitude valid");
    CHECK(GPSLabProfileAltitudeValid(-500.1) == 0, "below min altitude rejected");
    CHECK(GPSLabProfileAltitudeValid(100000.1) == 0, "above max altitude rejected");
    CHECK(GPSLabProfileAltitudeValid(NAN) == 0, "NaN altitude rejected");

    CHECK(GPSLabProfileHeadingValid(-1.0) == 1, "unknown course -1 valid");
    CHECK(GPSLabProfileHeadingValid(0.0) == 1, "0 heading valid");
    CHECK(GPSLabProfileHeadingValid(360.0) == 1, "360 heading valid");
    CHECK(GPSLabProfileHeadingValid(361.0) == 0, "above 360 heading rejected");
    CHECK(GPSLabProfileHeadingValid(-361.0) == 0, "below -360 heading rejected");
}

static void test_enums_and_ranges(void) {
    for (int mode = 0; mode <= 3; mode++) {
        CHECK(GPSLabProfileRouteModeValid(mode) == 1, "route mode 0..3 valid");
    }
    CHECK(GPSLabProfileRouteModeValid(4) == 0, "route mode 4 rejected");
    CHECK(GPSLabProfileRouteModeValid(-1) == 0, "route mode -1 rejected");

    CHECK(GPSLabProfileCustomSpeedValid(1.0) == 1, "min custom speed valid");
    CHECK(GPSLabProfileCustomSpeedValid(300.0) == 1, "max custom speed valid");
    CHECK(GPSLabProfileCustomSpeedValid(0.9) == 0, "below min speed rejected");
    CHECK(GPSLabProfileCustomSpeedValid(300.1) == 0, "above max speed rejected");
    CHECK(GPSLabProfileCustomSpeedValid(NAN) == 0, "NaN speed rejected");

    CHECK(GPSLabProfileLocationModeValid(GPSLabProfileLocationStatic) == 1, "static mode valid");
    CHECK(GPSLabProfileLocationModeValid(GPSLabProfileLocationRoute) == 1, "route mode valid");
    CHECK(GPSLabProfileLocationModeValid(2) == 0, "unknown location mode rejected");

    CHECK(GPSLabProfileScheduleModeValid(GPSLabProfileScheduleNone) == 1, "none schedule valid");
    CHECK(GPSLabProfileScheduleModeValid(GPSLabProfileScheduleOnce) == 1, "once schedule valid");
    CHECK(GPSLabProfileScheduleModeValid(GPSLabProfileScheduleWindow) == 1, "window schedule valid");
    CHECK(GPSLabProfileScheduleModeValid(3) == 0, "unknown schedule mode rejected");

    CHECK(GPSLabProfileSchemaVersionValid(GPSLAB_PROFILE_SCHEMA_VERSION) == 1, "current schema valid");
    CHECK(GPSLabProfileSchemaVersionValid(0) == 0, "schema 0 rejected");
    CHECK(GPSLabProfileSchemaVersionValid(2) == 0, "future schema rejected");

    CHECK(GPSLabProfileCountValid(0) == 1, "zero profiles valid");
    CHECK(GPSLabProfileCountValid((size_t)GPSLAB_PROFILE_MAX_COUNT) == 1, "max profiles valid");
    CHECK(GPSLabProfileCountValid((size_t)GPSLAB_PROFILE_MAX_COUNT + 1) == 0, "over max rejected");

    int validSignals = 0;
    for (int signal = -10; signal <= 110; signal++) {
        if (GPSLabProfileSignalValid(signal)) {
            validSignals++;
        }
    }
    CHECK(validSignals == 101, "signal valid only in 0..100");

    int validRSSI = 0;
    for (int rssi = -110; rssi <= 10; rssi++) {
        if (GPSLabProfileRSSIValid(rssi)) {
            validRSSI++;
        }
    }
    CHECK(validRSSI == 101, "rssi valid only in -100..0");
}

static void test_text(void) {
    CHECK(GPSLabProfileNameValid("Home", 4) == 1, "plain name valid");
    CHECK(GPSLabProfileNameValid("   ", 3) == 0, "whitespace name rejected");
    CHECK(GPSLabProfileNameValid("", 0) == 0, "empty name rejected");
    CHECK(GPSLabProfileNameValid(NULL, 0) == 0, "NULL name rejected");
    char longName[GPSLAB_PROFILE_MAX_NAME_BYTES + 2];
    memset(longName, 'a', sizeof(longName));
    CHECK(GPSLabProfileNameValid(longName, GPSLAB_PROFILE_MAX_NAME_BYTES) == 1, "max name valid");
    CHECK(GPSLabProfileNameValid(longName, GPSLAB_PROFILE_MAX_NAME_BYTES + 1) == 0, "over max name rejected");

    CHECK(GPSLabProfileTextValid("", 0) == 1, "empty text valid");
    char longText[GPSLAB_PROFILE_MAX_TEXT_BYTES + 2];
    memset(longText, 'b', sizeof(longText));
    CHECK(GPSLabProfileTextValid(longText, GPSLAB_PROFILE_MAX_TEXT_BYTES) == 1, "max text valid");
    CHECK(GPSLabProfileTextValid(longText, GPSLAB_PROFILE_MAX_TEXT_BYTES + 1) == 0, "over max text rejected");

    CHECK(GPSLabProfileIdentifierValid("ABC-123", 7) == 1, "identifier valid");
    CHECK(GPSLabProfileIdentifierValid("", 0) == 0, "empty identifier rejected");
    CHECK(GPSLabProfileIdentifierValid(NULL, 0) == 0, "NULL identifier rejected");
}

static void test_saturating_add(void) {
    CHECK(GPSLabProfileSaturatingAdd(10, 5) == 15, "normal add");
    CHECK(GPSLabProfileSaturatingAdd(GPSLAB_PROFILE_MAX_TIMESTAMP, 10) == GPSLAB_PROFILE_MAX_TIMESTAMP,
          "positive overflow saturates");
    CHECK(GPSLabProfileSaturatingAdd(-GPSLAB_PROFILE_MAX_TIMESTAMP, -10) == -GPSLAB_PROFILE_MAX_TIMESTAMP,
          "negative overflow saturates");
}

static void test_schedule_valid(void) {
    CHECK(GPSLabProfileScheduleValid(1000, 1000) == 1, "one-shot window valid");
    CHECK(GPSLabProfileScheduleValid(1000, 2000) == 1, "forward window valid");
    CHECK(GPSLabProfileScheduleValid(2000, 1000) == 0, "reverse window rejected");
    CHECK(GPSLabProfileScheduleValid(0, 1000) == 0, "zero start rejected");
    CHECK(GPSLabProfileScheduleValid(-5, 1000) == 0, "negative start rejected");
    CHECK(GPSLabProfileScheduleValid(1000, -1) == 0, "negative end rejected");
    CHECK(GPSLabProfileScheduleValid(1000, 1000 + GPSLAB_PROFILE_MAX_HORIZON_SECONDS + 1) == 0,
          "beyond horizon rejected");
}

static void test_schedule_evaluate(void) {
    // one-shot
    CHECK(GPSLabProfileScheduleEvaluate(0, 0, 100, 0) == GPSLabProfileScheduleActionWait,
          "no schedule waits");
    CHECK(GPSLabProfileScheduleEvaluate(1000, 1000, 500, 0) == GPSLabProfileScheduleActionWait,
          "before start waits");
    CHECK(GPSLabProfileScheduleEvaluate(1000, 1000, 1000, 0) == GPSLabProfileScheduleActionApply,
          "at start applies");
    CHECK(GPSLabProfileScheduleEvaluate(1000, 1000, 1000 + GPSLAB_PROFILE_ONCE_WINDOW_SECONDS - 1, 0)
              == GPSLabProfileScheduleActionApply,
          "inside once window applies");
    CHECK(GPSLabProfileScheduleEvaluate(1000, 1000, 1000 + GPSLAB_PROFILE_ONCE_WINDOW_SECONDS, 0)
              == GPSLabProfileScheduleActionExpired,
          "past once window expires");
    CHECK(GPSLabProfileScheduleEvaluate(1000, 1000, 1000, 1) == GPSLabProfileScheduleActionWait,
          "already-fired waits");
    // window
    CHECK(GPSLabProfileScheduleEvaluate(1000, 5000, 4000, 0) == GPSLabProfileScheduleActionApply,
          "inside window applies");
    CHECK(GPSLabProfileScheduleEvaluate(1000, 5000, 5000, 0) == GPSLabProfileScheduleActionExpired,
          "window end expires");

    int applies = 0, expires = 0, waits = 0;
    for (long long now = 0; now <= 2000; now += 100) {
        GPSLabProfileScheduleAction action = GPSLabProfileScheduleEvaluate(1000, 1500, now, 0);
        if (action == GPSLabProfileScheduleActionApply) {
            applies++;
        } else if (action == GPSLabProfileScheduleActionExpired) {
            expires++;
        } else {
            waits++;
        }
    }
    CHECK(applies == 5, "window applies exactly across its span");
    CHECK(expires == 6, "window expires after its span");
    CHECK(waits == 10, "window waits before its start");
}

static void test_should_apply(void) {
    CHECK(GPSLabProfileScheduleShouldApply(1, 1, 0) == 1, "enabled+unlocked+not-disabled applies");
    CHECK(GPSLabProfileScheduleShouldApply(0, 1, 0) == 0, "engine off never applies");
    CHECK(GPSLabProfileScheduleShouldApply(1, 0, 0) == 0, "locked never applies");
    CHECK(GPSLabProfileScheduleShouldApply(1, 1, 1) == 0, "manual disable never applies");
}

int main(void) {
    test_coordinates();
    test_altitude_heading();
    test_enums_and_ranges();
    test_text();
    test_saturating_add();
    test_schedule_valid();
    test_schedule_evaluate();
    test_should_apply();

    if (gFailures == 0) {
        printf("gpslab_profile_test: %d checks passed\n", gChecks);
        return 0;
    }
    fprintf(stderr, "gpslab_profile_test: %d/%d checks failed\n", gFailures, gChecks);
    return 1;
}
