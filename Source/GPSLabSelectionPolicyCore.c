//
//  GPSLabSelectionPolicyCore.c
//  GPSLab
//
//  Pure C policy for the pending-selection draft and the favorite-add decision.
//  Reuses the established profile ranges (single source of truth) and carries a
//  self-contained haversine so the portable tests exercise the exact runtime math.
//

#include "GPSLabSelectionPolicyCore.h"

#include "GPSLabProfileCore.h"

#include <math.h>
#include <string.h>

static const double kGPSLabSelectionEarthRadiusMeters = 6371008.8;

static int gpslab_selection_isfinite(double value) {
    return isfinite(value) ? 1 : 0;
}

static int gpslab_selection_is_zero(double latitude, double longitude) {
    return (latitude == 0.0 && longitude == 0.0) ? 1 : 0;
}

int GPSLabSelectionPointIsExactZero(double latitude, double longitude) {
    if (!gpslab_selection_isfinite(latitude) || !gpslab_selection_isfinite(longitude)) {
        return 0;
    }
    // Exact numeric comparison; -0.0 == 0.0 so signed zero is accepted.
    return (latitude == 0.0 && longitude == 0.0) ? 1 : 0;
}

int GPSLabSelectionFieldsValid(double latitude,
                               double longitude,
                               double altitude,
                               double heading) {
    if (!GPSLabProfileCoordinateValid(latitude, longitude)) {
        return 0;
    }
    if (!GPSLabProfileAltitudeValid(altitude)) {
        return 0;
    }
    return GPSLabProfileHeadingValid(heading);
}

int GPSLabSelectionProviderKeyKnown(const char *utf8, size_t length) {
    static const char * const kKnownProviders[] = {
        "search.source.google",
        "search.source.apple",
    };
    if (utf8 == NULL || length == 0) {
        return 0;
    }
    for (size_t index = 0; index < (sizeof(kKnownProviders) / sizeof(kKnownProviders[0])); index++) {
        const char *known = kKnownProviders[index];
        size_t knownLength = strlen(known);
        if (knownLength == length && memcmp(utf8, known, length) == 0) {
            return 1;
        }
    }
    return 0;
}

double GPSLabSelectionDistanceMeters(double fromLatitude,
                                     double fromLongitude,
                                     double toLatitude,
                                     double toLongitude) {
    if (!gpslab_selection_isfinite(fromLatitude) || !gpslab_selection_isfinite(fromLongitude) ||
        !gpslab_selection_isfinite(toLatitude) || !gpslab_selection_isfinite(toLongitude)) {
        return INFINITY;
    }

    double lat1 = fromLatitude * M_PI / 180.0;
    double lat2 = toLatitude * M_PI / 180.0;
    double deltaLat = lat2 - lat1;
    double deltaLon = (toLongitude - fromLongitude) * M_PI / 180.0;

    double sinHalfLat = sin(deltaLat / 2.0);
    double sinHalfLon = sin(deltaLon / 2.0);
    double h = (sinHalfLat * sinHalfLat) + (cos(lat1) * cos(lat2) * sinHalfLon * sinHalfLon);
    if (h > 1.0) {
        h = 1.0;
    }
    if (h < 0.0) {
        h = 0.0;
    }

    return 2.0 * kGPSLabSelectionEarthRadiusMeters * asin(sqrt(h));
}

int GPSLabSelectionMatchesAnyProof(double latitude,
                                   double longitude,
                                   const double *proofLatitudes,
                                   const double *proofLongitudes,
                                   size_t proofCount,
                                   double toleranceMeters) {
    if (!gpslab_selection_isfinite(latitude) || !gpslab_selection_isfinite(longitude)) {
        return 0;
    }
    if (proofLatitudes == NULL || proofLongitudes == NULL) {
        return 0;
    }
    if (!gpslab_selection_isfinite(toleranceMeters) || toleranceMeters < 0.0) {
        return 0;
    }
    for (size_t index = 0; index < proofCount; index++) {
        double distance = GPSLabSelectionDistanceMeters(latitude, longitude,
                                                        proofLatitudes[index],
                                                        proofLongitudes[index]);
        if (distance <= toleranceMeters) {
            return 1;
        }
    }
    return 0;
}

int GPSLabSelectionHasDuplicate(double latitude,
                                double longitude,
                                const double *existingLatitudes,
                                const double *existingLongitudes,
                                size_t existingCount,
                                double toleranceMeters) {
    return GPSLabSelectionMatchesAnyProof(latitude,
                                          longitude,
                                          existingLatitudes,
                                          existingLongitudes,
                                          existingCount,
                                          toleranceMeters);
}

void GPSLabFavoriteResolveShownSelection(int hasPending,
                                         double pendingLatitude,
                                         double pendingLongitude,
                                         double pendingAltitude,
                                         double committedLatitude,
                                         double committedLongitude,
                                         double committedAltitude,
                                         double *outLatitude,
                                         double *outLongitude,
                                         double *outAltitude) {
    double latitude = hasPending ? pendingLatitude : committedLatitude;
    double longitude = hasPending ? pendingLongitude : committedLongitude;
    double altitude = hasPending ? pendingAltitude : committedAltitude;
    if (outLatitude != NULL) {
        *outLatitude = latitude;
    }
    if (outLongitude != NULL) {
        *outLongitude = longitude;
    }
    if (outAltitude != NULL) {
        *outAltitude = altitude;
    }
}

int GPSLabFavoriteSelectionAllowed(int hasPending,
                                   double committedLatitude,
                                   double committedLongitude,
                                   int hasExactZeroProof) {
    // An active pending selection is an explicit user intent, including 0,0.
    if (hasPending) {
        return 1;
    }
    // A malformed committed coordinate can never be favorited.
    if (!GPSLabProfileCoordinateValid(committedLatitude, committedLongitude)) {
        return 0;
    }
    // Any valid non-zero committed coordinate is a meaningful selection.
    if (!gpslab_selection_is_zero(committedLatitude, committedLongitude)) {
        return 1;
    }
    // Exact (0,0): allowed only with an EXACT valid stored (0,0) proof. No
    // geodesic tolerance here: a near-origin nonzero selection (0.000001,0) must
    // never authorize a pristine reset-to-(0,0).
    return hasExactZeroProof ? 1 : 0;
}
