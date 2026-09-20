//
//  GPSLabProfileCore.c
//  GPSLab
//

#include "GPSLabProfileCore.h"

#include <math.h>
#include <stdint.h>
#include <string.h>

static int gpslab_profile_isfinite(double value) {
    return isfinite(value) ? 1 : 0;
}

int GPSLabProfileCoordinateValid(double latitude, double longitude) {
    if (!gpslab_profile_isfinite(latitude) || !gpslab_profile_isfinite(longitude)) {
        return 0;
    }
    return (latitude >= -90.0 && latitude <= 90.0 &&
            longitude >= -180.0 && longitude <= 180.0) ? 1 : 0;
}

int GPSLabProfileAltitudeValid(double altitude) {
    if (!gpslab_profile_isfinite(altitude)) {
        return 0;
    }
    return (altitude >= -500.0 && altitude <= 100000.0) ? 1 : 0;
}

int GPSLabProfileHeadingValid(double heading) {
    if (!gpslab_profile_isfinite(heading)) {
        return 0;
    }
    return (heading >= -360.0 && heading <= 360.0) ? 1 : 0;
}

int GPSLabProfileRouteModeValid(int mode) {
    return (mode >= 0 && mode <= 3) ? 1 : 0;
}

int GPSLabProfileCustomSpeedValid(double speed_kmh) {
    if (!gpslab_profile_isfinite(speed_kmh)) {
        return 0;
    }
    return (speed_kmh >= 1.0 && speed_kmh <= 300.0) ? 1 : 0;
}

static size_t gpslab_profile_trimmed_length(const char *utf8, size_t length) {
    if (utf8 == NULL) {
        return 0;
    }
    size_t start = 0;
    while (start < length && (utf8[start] == ' ' || utf8[start] == '\t' ||
                              utf8[start] == '\n' || utf8[start] == '\r')) {
        start += 1;
    }
    size_t end = length;
    while (end > start && (utf8[end - 1] == ' ' || utf8[end - 1] == '\t' ||
                           utf8[end - 1] == '\n' || utf8[end - 1] == '\r')) {
        end -= 1;
    }
    return end - start;
}

int GPSLabProfileNameValid(const char *utf8, size_t length) {
    if (utf8 == NULL || length == 0) {
        return 0;
    }
    if (length > GPSLAB_PROFILE_MAX_NAME_BYTES) {
        return 0;
    }
    return gpslab_profile_trimmed_length(utf8, length) > 0 ? 1 : 0;
}

int GPSLabProfileTextValid(const char *utf8, size_t length) {
    if (length > GPSLAB_PROFILE_MAX_TEXT_BYTES) {
        return 0;
    }
    if (length == 0) {
        return 1;
    }
    return utf8 != NULL ? 1 : 0;
}

int GPSLabProfileIdentifierValid(const char *utf8, size_t length) {
    if (utf8 == NULL || length == 0) {
        return 0;
    }
    return length <= GPSLAB_PROFILE_MAX_NAME_BYTES ? 1 : 0;
}

int GPSLabProfileCountValid(size_t count) {
    return count <= (size_t)GPSLAB_PROFILE_MAX_COUNT ? 1 : 0;
}

int GPSLabProfileScheduleModeValid(int mode) {
    return (mode >= GPSLabProfileScheduleNone && mode <= GPSLabProfileScheduleWindow) ? 1 : 0;
}

int GPSLabProfileLocationModeValid(int mode) {
    return (mode == GPSLabProfileLocationStatic || mode == GPSLabProfileLocationRoute) ? 1 : 0;
}

int GPSLabProfileSignalValid(int signal) {
    return (signal >= GPSLAB_PROFILE_MIN_SIGNAL && signal <= GPSLAB_PROFILE_MAX_SIGNAL) ? 1 : 0;
}

int GPSLabProfileRSSIValid(int rssi) {
    return (rssi >= GPSLAB_PROFILE_MIN_RSSI && rssi <= GPSLAB_PROFILE_MAX_RSSI) ? 1 : 0;
}

int GPSLabProfileSchemaVersionValid(long long version) {
    return version == (long long)GPSLAB_PROFILE_SCHEMA_VERSION ? 1 : 0;
}

long long GPSLabProfileSaturatingAdd(long long base, long long delta) {
    if (delta > 0 && base > GPSLAB_PROFILE_MAX_TIMESTAMP - delta) {
        return GPSLAB_PROFILE_MAX_TIMESTAMP;
    }
    if (delta < 0 && base < -GPSLAB_PROFILE_MAX_TIMESTAMP - delta) {
        return -GPSLAB_PROFILE_MAX_TIMESTAMP;
    }
    return base + delta;
}

int GPSLabProfileScheduleValid(long long start, long long end) {
    if (start <= 0 || start > GPSLAB_PROFILE_MAX_TIMESTAMP) {
        return 0;
    }
    if (end < 0 || end > GPSLAB_PROFILE_MAX_TIMESTAMP) {
        return 0;
    }
    if (end > start && (end - start) > GPSLAB_PROFILE_MAX_HORIZON_SECONDS) {
        return 0;
    }
    if (end < start) {
        return 0;
    }
    return 1;
}

GPSLabProfileScheduleAction GPSLabProfileScheduleEvaluate(long long start, long long end,
                                                          long long now, int already_fired) {
    if (start <= 0 || now <= 0) {
        return GPSLabProfileScheduleActionWait;
    }
    if (already_fired) {
        return GPSLabProfileScheduleActionWait;
    }
    if (now < start) {
        return GPSLabProfileScheduleActionWait;
    }

    long long window_end = (end > start)
        ? end
        : GPSLabProfileSaturatingAdd(start, GPSLAB_PROFILE_ONCE_WINDOW_SECONDS);

    if (now < window_end) {
        return GPSLabProfileScheduleActionApply;
    }
    return GPSLabProfileScheduleActionExpired;
}

int GPSLabProfileScheduleShouldApply(int engine_enabled, int license_unlocked, int manually_disabled) {
    if (!engine_enabled || !license_unlocked || manually_disabled) {
        return 0;
    }
    return 1;
}
