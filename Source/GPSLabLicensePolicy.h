//
//  GPSLabLicensePolicy.h
//  GPSLab
//
//  Pure C license policy: entitlement states, authenticated server status, bounded
//  clock-rollback-resistant time, and time/grace/revocation resolution. No Foundation
//  dependency, so the dylib and the Linux policy tests compile the exact same code.
//
//  All time helpers are overflow-safe and reject out-of-range timestamps. Security
//  posture: fail-closed.
//

#ifndef GPSLAB_LICENSE_POLICY_H
#define GPSLAB_LICENSE_POLICY_H

#include <stddef.h>

/** Upper bound accepted for any wall/uptime timestamp (2100-01-01T00:00:00Z). */
#define GPSLAB_LICENSE_MAX_TIMESTAMP 4102444800LL

/** Exact entitlement states. Order is a stable diagnostic contract. */
typedef enum {
    GPSLabEntitlementStateUnknown = 0,
    GPSLabEntitlementStateChecking = 1,
    GPSLabEntitlementStateActive = 2,
    GPSLabEntitlementStateGrace = 3,
    GPSLabEntitlementStateExpired = 4,
    GPSLabEntitlementStateInvalid = 5,
    GPSLabEntitlementStateOffline = 6,
} GPSLabEntitlementState;

/** Authenticated server/verifier status carried across network failures. */
typedef enum {
    GPSLabLicenseAuthStatusNone = 0,
    GPSLabLicenseAuthStatusActive = 1,
    GPSLabLicenseAuthStatusGrace = 2,
    GPSLabLicenseAuthStatusExpired = 3,
    GPSLabLicenseAuthStatusRevoked = 4,
    GPSLabLicenseAuthStatusInvalid = 5,
} GPSLabLicenseAuthStatus;

/**
 * Best-effort clock observation. Persisted so a wall-clock rollback cannot silently
 * extend an entitlement. Documented as best-effort deterrence, not tamper-proof.
 */
typedef struct {
    long long verifiedAtWall;
    long long verifiedAtUptime;
    long long lastSeenWall;
    long long lastSeenUptime;
} GPSLabLicenseClock;

static inline int GPSLabLicenseIsSaneTimestamp(long long value) {
    return value > 0 && value <= GPSLAB_LICENSE_MAX_TIMESTAMP;
}

static inline int GPSLabLicenseIsSaneUptime(long long value) {
    return value >= 0 && value <= GPSLAB_LICENSE_MAX_TIMESTAMP;
}

static inline long long GPSLabLicenseSaturatingAdd(long long a, long long b) {
    if (b > 0 && a > GPSLAB_LICENSE_MAX_TIMESTAMP - b) {
        return GPSLAB_LICENSE_MAX_TIMESTAMP;
    }
    if (b < 0 && a < 0) {
        return 0;
    }
    return a + b;
}

/** Clamps an observation into the sane range. */
static inline long long GPSLabLicenseClampTimestamp(long long value) {
    if (value < 0) {
        return 0;
    }
    if (value > GPSLAB_LICENSE_MAX_TIMESTAMP) {
        return GPSLAB_LICENSE_MAX_TIMESTAMP;
    }
    return value;
}

/**
 * Returns an effective "now" that never advances slower than monotonic uptime and
 * never goes backwards across a rollback. Mutates `clock`. Sets `*rollbackDetected`
 * to 1 when a wall-clock rollback was detected. All arithmetic is saturating.
 */
static inline long long GPSLabLicenseEffectiveNow(long long wallNow,
                                                  long long uptimeNow,
                                                  GPSLabLicenseClock *clock,
                                                  int *rollbackDetected) {
    if (rollbackDetected != NULL) {
        *rollbackDetected = 0;
    }
    long long wall = GPSLabLicenseClampTimestamp(wallNow);
    long long uptime = GPSLabLicenseClampTimestamp(uptimeNow);
    if (clock == NULL) {
        return wall;
    }
    if (clock->lastSeenWall <= 0) {
        clock->lastSeenWall = wall;
        clock->lastSeenUptime = uptime;
        return wall;
    }

    long long effective = wall;
    if (uptime >= clock->lastSeenUptime) {
        long long monotonicFloor = GPSLabLicenseSaturatingAdd(clock->lastSeenWall,
                                                              uptime - clock->lastSeenUptime);
        if (wall < monotonicFloor) {
            effective = monotonicFloor;
            if (wall < clock->lastSeenWall && rollbackDetected != NULL) {
                *rollbackDetected = 1;
            }
        }
    } else {
        // Reboot: uptime restarted, so never trust a smaller wall clock.
        if (wall < clock->lastSeenWall) {
            effective = clock->lastSeenWall;
            if (rollbackDetected != NULL) {
                *rollbackDetected = 1;
            }
        }
    }

    if (effective > clock->lastSeenWall) {
        clock->lastSeenWall = effective;
    }
    clock->lastSeenUptime = uptime;
    return effective;
}

/** Guards against tokens issued in the future beyond a bounded clock skew. */
static inline int GPSLabLicenseIssuedAtAcceptable(long long issuedAt, long long now, long long skewSeconds) {
    if (!GPSLabLicenseIsSaneTimestamp(issuedAt)) {
        return 0;
    }
    long long limit = GPSLabLicenseSaturatingAdd(GPSLabLicenseClampTimestamp(now),
                                                 skewSeconds > 0 ? skewSeconds : 0);
    return issuedAt <= limit;
}

/** Time-only resolution for a verified, bound token. */
static inline GPSLabEntitlementState GPSLabLicenseStateForTime(long long now,
                                                               long long expiresAt,
                                                               long long graceUntil,
                                                               long long graceCapSeconds) {
    if (!GPSLabLicenseIsSaneTimestamp(expiresAt)) {
        return GPSLabEntitlementStateInvalid;
    }
    if (now < expiresAt) {
        return GPSLabEntitlementStateActive;
    }
    if (graceUntil > expiresAt && graceCapSeconds >= 0) {
        long long window = graceUntil - expiresAt;
        if (window <= graceCapSeconds && now < graceUntil) {
            return GPSLabEntitlementStateGrace;
        }
    }
    return GPSLabEntitlementStateExpired;
}

/**
 * Resolves using the authenticated server status first (so a signed revocation or an
 * already-authenticated expiry is never lost to a later offline failure), then the
 * verified token's own time.
 */
static inline GPSLabEntitlementState GPSLabLicenseResolveAuth(int hasVerifiedToken,
                                                              GPSLabLicenseAuthStatus authStatus,
                                                              long long now,
                                                              long long expiresAt,
                                                              long long graceUntil,
                                                              long long graceCapSeconds) {
    if (authStatus == GPSLabLicenseAuthStatusRevoked || authStatus == GPSLabLicenseAuthStatusInvalid) {
        return GPSLabEntitlementStateInvalid;
    }
    if (authStatus == GPSLabLicenseAuthStatusExpired) {
        return GPSLabEntitlementStateExpired;
    }
    if (!hasVerifiedToken) {
        return GPSLabEntitlementStateUnknown;
    }
    return GPSLabLicenseStateForTime(now, expiresAt, graceUntil, graceCapSeconds);
}

/** Back-compat wrapper over the older boolean flags. */
static inline GPSLabEntitlementState GPSLabLicenseResolve(int hasVerifiedCache,
                                                          int serverRevoked,
                                                          int serverExpired,
                                                          long long now,
                                                          long long expiresAt,
                                                          long long graceUntil,
                                                          long long graceCapSeconds) {
    GPSLabLicenseAuthStatus status = GPSLabLicenseAuthStatusNone;
    if (serverRevoked) {
        status = GPSLabLicenseAuthStatusRevoked;
    } else if (serverExpired) {
        status = GPSLabLicenseAuthStatusExpired;
    }
    return GPSLabLicenseResolveAuth(hasVerifiedCache, status, now, expiresAt, graceUntil, graceCapSeconds);
}

/** YES for the two states that may enable the synthetic engine. */
static inline int GPSLabLicenseStateIsUnlocked(GPSLabEntitlementState state) {
    return state == GPSLabEntitlementStateActive || state == GPSLabEntitlementStateGrace;
}

static inline const char *GPSLabLicenseStateToken(GPSLabEntitlementState state) {
    switch (state) {
        case GPSLabEntitlementStateUnknown:  return "unknown";
        case GPSLabEntitlementStateChecking: return "checking";
        case GPSLabEntitlementStateActive:   return "active";
        case GPSLabEntitlementStateGrace:    return "grace";
        case GPSLabEntitlementStateExpired:  return "expired";
        case GPSLabEntitlementStateInvalid:  return "invalid";
        case GPSLabEntitlementStateOffline:  return "offline";
    }
    return "unknown";
}

#endif /* GPSLAB_LICENSE_POLICY_H */
