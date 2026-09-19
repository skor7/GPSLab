/*
 * GPSLab license policy tests (portable C).
 *
 * These exercise Source/GPSLabLicensePolicy.h directly, i.e. the exact inline policy
 * the dylib compiles in. They do not re-implement the logic.
 *
 * Build/run (Linux or macOS):
 *   cc -I../Source tests/license_policy_test.c -o policy_test && ./policy_test
 */

#include <stdio.h>
#include <string.h>

#include "GPSLabLicensePolicy.h"

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

static const long long kHour = 3600;
static const long long kDay = 24 * kHour;

static void test_time_states(void) {
    long long base = 1000 * kDay;
    long long expiry = base + kDay;
    CHECK(GPSLabLicenseStateForTime(base, expiry, 0, 604800) == GPSLabEntitlementStateActive,
          "before expiry is active");
    CHECK(GPSLabLicenseStateForTime(expiry, expiry, 0, 604800) == GPSLabEntitlementStateExpired,
          "exactly at expiry is expired");
    CHECK(GPSLabLicenseStateForTime(expiry + kHour, expiry, expiry + 12 * kHour, 604800) ==
              GPSLabEntitlementStateGrace,
          "inside grace window with cap is grace");
    CHECK(GPSLabLicenseStateForTime(expiry + 13 * kHour, expiry, expiry + 12 * kHour, 604800) ==
              GPSLabEntitlementStateExpired,
          "after grace is expired");
    CHECK(GPSLabLicenseStateForTime(expiry + 2 * kHour, expiry, expiry + 12 * kHour, kHour) ==
              GPSLabEntitlementStateExpired,
          "grace window larger than cap is rejected");
    CHECK(GPSLabLicenseStateForTime(base, expiry, expiry - kHour, 604800) == GPSLabEntitlementStateActive,
          "graceUntil before expiry is ignored while active");
    CHECK(GPSLabLicenseStateForTime(expiry + kHour, expiry, expiry - kHour, 604800) ==
              GPSLabEntitlementStateExpired,
          "graceUntil before expiry is rejected after expiry");
    CHECK(GPSLabLicenseStateForTime(base, 0, 0, 604800) == GPSLabEntitlementStateInvalid,
          "missing expiry is invalid");
}

static void test_resolve(void) {
    long long now = 1000 * kDay;
    long long expires = now + kDay;
    CHECK(GPSLabLicenseResolve(1, 1, 0, now, expires, 0, 604800) == GPSLabEntitlementStateInvalid,
          "revocation wins over active time");
    CHECK(GPSLabLicenseResolve(1, 0, 1, now, expires, 0, 604800) == GPSLabEntitlementStateExpired,
          "server expiry wins over active time");
    CHECK(GPSLabLicenseResolve(0, 0, 0, now, expires, 0, 604800) == GPSLabEntitlementStateUnknown,
          "no verified cache resolves to unknown");
    CHECK(GPSLabLicenseResolve(1, 0, 0, now, expires, 0, 604800) == GPSLabEntitlementStateActive,
          "verified cache before expiry is active");
    CHECK(GPSLabLicenseResolve(1, 0, 0, now, 0, 0, 604800) == GPSLabEntitlementStateInvalid,
          "verified cache with no expiry is invalid");
}

static void test_auth_status_preserved(void) {
    long long now = 1000 * kDay;
    long long expires = now + kDay;
    CHECK(GPSLabLicenseResolveAuth(1, GPSLabLicenseAuthStatusRevoked, now, expires, 0, 604800) ==
              GPSLabEntitlementStateInvalid,
          "authenticated revocation is preserved");
    CHECK(GPSLabLicenseResolveAuth(1, GPSLabLicenseAuthStatusInvalid, now, expires, 0, 604800) ==
              GPSLabEntitlementStateInvalid,
          "authenticated invalid is preserved");
    CHECK(GPSLabLicenseResolveAuth(0, GPSLabLicenseAuthStatusExpired, now, expires, 0, 604800) ==
              GPSLabEntitlementStateExpired,
          "authenticated expiry survives losing the token");
    CHECK(GPSLabLicenseResolveAuth(0, GPSLabLicenseAuthStatusNone, now, expires, 0, 604800) ==
              GPSLabEntitlementStateUnknown,
          "no token and no status is unknown");
    CHECK(GPSLabLicenseResolveAuth(1, GPSLabLicenseAuthStatusActive, now, expires, 0, 604800) ==
              GPSLabEntitlementStateActive,
          "active token before expiry is active");
    CHECK(GPSLabLicenseResolveAuth(1, GPSLabLicenseAuthStatusActive, now + kDay + 1, expires, 0, 604800) ==
              GPSLabEntitlementStateExpired,
          "time wins for an active status past expiry");
    CHECK(GPSLabLicenseResolveAuth(1, GPSLabLicenseAuthStatusGrace, now + kDay + 1, expires,
                                   expires + 12 * kHour, 604800) == GPSLabEntitlementStateGrace,
          "grace window still resolves grace");
}

static void test_issued_at_skew(void) {
    long long now = 1000 * kDay;
    CHECK(GPSLabLicenseIssuedAtAcceptable(now, now, 300) == 1, "issued now accepted");
    CHECK(GPSLabLicenseIssuedAtAcceptable(now + 300, now, 300) == 1, "issued within skew accepted");
    CHECK(GPSLabLicenseIssuedAtAcceptable(now + 301, now, 300) == 0, "issued beyond skew rejected");
    CHECK(GPSLabLicenseIssuedAtAcceptable(0, now, 300) == 0, "zero issued rejected");
    CHECK(GPSLabLicenseIssuedAtAcceptable(-5, now, 300) == 0, "negative issued rejected");
    CHECK(GPSLabLicenseIssuedAtAcceptable(GPSLAB_LICENSE_MAX_TIMESTAMP + 1, now, 300) == 0,
          "oversized issued rejected");
}

static void test_bounds(void) {
    CHECK(GPSLabLicenseIsSaneTimestamp(0) == 0, "zero is not sane");
    CHECK(GPSLabLicenseIsSaneTimestamp(GPSLAB_LICENSE_MAX_TIMESTAMP) == 1, "max is sane");
    CHECK(GPSLabLicenseIsSaneTimestamp(GPSLAB_LICENSE_MAX_TIMESTAMP + 1) == 0, "above max is not sane");
    CHECK(GPSLabLicenseSaturatingAdd(GPSLAB_LICENSE_MAX_TIMESTAMP, 10) == GPSLAB_LICENSE_MAX_TIMESTAMP,
          "saturating add caps");
    CHECK(GPSLabLicenseClampTimestamp(-1) == 0, "clamp negative to zero");
    CHECK(GPSLabLicenseClampTimestamp(GPSLAB_LICENSE_MAX_TIMESTAMP + 5) == GPSLAB_LICENSE_MAX_TIMESTAMP,
          "clamp oversized to max");

    GPSLabLicenseClock clock;
    memset(&clock, 0, sizeof(clock));
    long long huge = GPSLabLicenseEffectiveNow(GPSLAB_LICENSE_MAX_TIMESTAMP,
                                               GPSLAB_LICENSE_MAX_TIMESTAMP,
                                               &clock,
                                               NULL);
    CHECK(huge <= GPSLAB_LICENSE_MAX_TIMESTAMP, "effective now is bounded");
    CHECK(huge > 0, "effective now is positive");

    // Sane token at the extreme boundary is still accepted, not treated as invalid.
    CHECK(GPSLabLicenseResolveAuth(1, GPSLabLicenseAuthStatusActive,
                                   1000 * kDay, GPSLAB_LICENSE_MAX_TIMESTAMP, 0, 604800) ==
              GPSLabEntitlementStateActive,
          "boundary expiry is active before it");
}

static void test_clock_rollback_cannot_extend(void) {
    GPSLabLicenseClock clock;
    memset(&clock, 0, sizeof(clock));

    long long t0 = 10000 * kDay;
    long long first = GPSLabLicenseEffectiveNow(t0, 5000, &clock, NULL);
    CHECK(first == t0, "first observation adopts wall time");

    // Wall clock jumps backwards by 10 days while uptime advances 1 hour.
    int rollback = 0;
    long long rolled = GPSLabLicenseEffectiveNow(t0 - 10 * kDay + kHour, 5000 + kHour, &clock, &rollback);
    CHECK(rollback == 1, "rollback detected");
    CHECK(rolled >= t0, "effective now cannot go back below the last seen time");
    CHECK(rolled >= t0 + kHour, "effective now follows monotonic uptime forward");

    // A token that expired between the rolled-back wall time and t0 must stay expired.
    long long expires = t0 + kHour / 2;
    CHECK(GPSLabLicenseStateForTime(rolled, expires, 0, 604800) == GPSLabEntitlementStateExpired,
          "rollback cannot revive an expired license");
}

static void test_clock_reboot_and_forward(void) {
    GPSLabLicenseClock clock;
    memset(&clock, 0, sizeof(clock));

    long long t0 = 20000 * kDay;
    GPSLabLicenseEffectiveNow(t0, 100000, &clock, NULL);

    // Reboot: uptime restarts and wall moved backwards.
    int rollback = 0;
    long long afterReboot = GPSLabLicenseEffectiveNow(t0 - 5 * kDay, 100, &clock, &rollback);
    CHECK(rollback == 1, "reboot with smaller wall clock counts as rollback");
    CHECK(afterReboot == t0, "reboot never trusts a smaller wall clock");

    // Forward wall time is accepted (it only ever shortens the license).
    long long forward = GPSLabLicenseEffectiveNow(t0 + 3 * kDay, 200000, &clock, &rollback);
    CHECK(forward == t0 + 3 * kDay, "forward wall time is accepted");
}

static void test_unlock_gate(void) {
    CHECK(GPSLabLicenseStateIsUnlocked(GPSLabEntitlementStateActive) == 1, "active is unlocked");
    CHECK(GPSLabLicenseStateIsUnlocked(GPSLabEntitlementStateGrace) == 1, "grace is unlocked");
    CHECK(GPSLabLicenseStateIsUnlocked(GPSLabEntitlementStateExpired) == 0, "expired is locked");
    CHECK(GPSLabLicenseStateIsUnlocked(GPSLabEntitlementStateInvalid) == 0, "invalid is locked");
    CHECK(GPSLabLicenseStateIsUnlocked(GPSLabEntitlementStateOffline) == 0, "offline is locked");
    CHECK(GPSLabLicenseStateIsUnlocked(GPSLabEntitlementStateChecking) == 0, "checking is locked");
    CHECK(GPSLabLicenseStateIsUnlocked(GPSLabEntitlementStateUnknown) == 0, "unknown is locked");
}

int main(void) {
    test_time_states();
    test_resolve();
    test_auth_status_preserved();
    test_issued_at_skew();
    test_bounds();
    test_clock_rollback_cannot_extend();
    test_clock_reboot_and_forward();
    test_unlock_gate();

    if (gFailures == 0) {
        printf("license_policy_test: %d checks passed\n", gChecks);
        return 0;
    }
    fprintf(stderr, "license_policy_test: %d/%d checks failed\n", gFailures, gChecks);
    return 1;
}
