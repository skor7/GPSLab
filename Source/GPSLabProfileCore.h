//
//  GPSLabProfileCore.h
//  GPSLab
//
//  Pure C profile/schema/schedule boundary policy. No Foundation/UIKit
//  dependency, so the exact rules the dylib obeys at runtime are compiled both
//  into the dylib and into the portable CI tests.
//
//  This is a local, user-authored synthetic-state schema only: no host data, no
//  device identifiers, no network.
//

#ifndef GPSLAB_PROFILE_CORE_H
#define GPSLAB_PROFILE_CORE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/** Persisted schema revision. Bump only with a migration. */
#define GPSLAB_PROFILE_SCHEMA_VERSION 1

/** Hard limits (fail-closed: out-of-range values are rejected, never clamped silently). */
#define GPSLAB_PROFILE_MAX_COUNT 50
#define GPSLAB_PROFILE_MAX_NAME_BYTES 64
#define GPSLAB_PROFILE_MAX_TEXT_BYTES 128
#define GPSLAB_PROFILE_MAX_ARRAY_ITEMS 8
#define GPSLAB_PROFILE_MIN_SIGNAL 0
#define GPSLAB_PROFILE_MAX_SIGNAL 100
#define GPSLAB_PROFILE_MIN_RSSI (-100)
#define GPSLAB_PROFILE_MAX_RSSI 0

/** One-shot schedules that carry no explicit end fire within this grace window. */
#define GPSLAB_PROFILE_ONCE_WINDOW_SECONDS 300LL
/** Schedules beyond this horizon are rejected as invalid. */
#define GPSLAB_PROFILE_MAX_HORIZON_SECONDS (366LL * 24LL * 60LL * 60LL)
/** Upper bound for any epoch second (2100-01-01T00:00:00Z), mirrors the license guard. */
#define GPSLAB_PROFILE_MAX_TIMESTAMP 4102444800LL

typedef enum {
    GPSLabProfileLocationStatic = 0,
    GPSLabProfileLocationRoute = 1,
} GPSLabProfileLocationMode;

typedef enum {
    GPSLabProfileScheduleNone = 0,
    GPSLabProfileScheduleOnce = 1,
    GPSLabProfileScheduleWindow = 2,
} GPSLabProfileScheduleMode;

/** What the scheduler should do for a schedule at a given instant. */
typedef enum {
    GPSLabProfileScheduleActionWait = 0,
    GPSLabProfileScheduleActionApply = 1,
    GPSLabProfileScheduleActionExpired = 2,
} GPSLabProfileScheduleAction;

/** 1 when both coordinates are finite and in range. */
int GPSLabProfileCoordinateValid(double latitude, double longitude);
/** 1 when altitude is finite and within the engine's safe range. */
int GPSLabProfileAltitudeValid(double altitude);
/** 1 when heading is finite and within [-360, 360] (engine normalizes). */
int GPSLabProfileHeadingValid(double heading);
/** 1 when the route mode is one of the engine's four modes. */
int GPSLabProfileRouteModeValid(int mode);
/** 1 when custom speed is finite and inside the engine's clamped range. */
int GPSLabProfileCustomSpeedValid(double speed_kmh);
/** 1 when a UTF-8 name is non-empty (after trimming) and within the byte cap. */
int GPSLabProfileNameValid(const char *utf8, size_t length);
/** 1 when a UTF-8 free-text value is within the byte cap (empty allowed). */
int GPSLabProfileTextValid(const char *utf8, size_t length);
/** 1 when an identifier is non-empty and within the name byte cap. */
int GPSLabProfileIdentifierValid(const char *utf8, size_t length);
/** 1 when the profile count is within the store cap. */
int GPSLabProfileCountValid(size_t count);
/** 1 when the schedule mode constant is known. */
int GPSLabProfileScheduleModeValid(int mode);
/** 1 when the location mode constant is known. */
int GPSLabProfileLocationModeValid(int mode);
/** 1 when the signal strength is inside [0, 100]. */
int GPSLabProfileSignalValid(int signal);
/** 1 when the RSSI is inside [-100, 0]. */
int GPSLabProfileRSSIValid(int rssi);
/** 1 when the schema version is exactly the supported revision. */
int GPSLabProfileSchemaVersionValid(long long version);

/** Saturating add of two epoch seconds (never overflows). */
long long GPSLabProfileSaturatingAdd(long long base, long long delta);

/**
 * Validates a schedule window. `start` is the trigger instant; `end` may equal
 * `start` for a one-shot. Both are UTC epoch seconds. Returns 1 when sane.
 */
int GPSLabProfileScheduleValid(long long start, long long end);

/**
 * Deterministic schedule evaluation.
 *
 *   start <= 0 or now <= 0            -> Wait
 *   already_fired                     -> Wait
 *   now < start                       -> Wait
 *   now < (end > start ? end : start + once window) -> Apply
 *   otherwise                         -> Expired
 *
 * A one-shot (end <= start) uses GPSLAB_PROFILE_ONCE_WINDOW_SECONDS.
 */
GPSLabProfileScheduleAction GPSLabProfileScheduleEvaluate(long long start, long long end,
                                                          long long now, int already_fired);

/**
 * The scheduler may apply only when the synthetic engine is ALREADY enabled and
 * the license is unlocked, and the user has not manually disabled the engine.
 * This function never enables the engine; it is a pure gate.
 */
int GPSLabProfileScheduleShouldApply(int engine_enabled, int license_unlocked, int manually_disabled);

#ifdef __cplusplus
}
#endif

#endif /* GPSLAB_PROFILE_CORE_H */
