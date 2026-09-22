//
//  GPSLabSelectionPolicyCore.h
//  GPSLab
//
//  Pure C policy for the pending-selection draft and the favorite-add decision.
//  No Foundation/UIKit/private frameworks, so the exact rules the dylib obeys at
//  runtime are compiled both into the dylib and into the portable CI tests.
//
//  This is local synthetic-state policy only: no host data, no device identity,
//  no real-device location.
//

#ifndef GPSLAB_SELECTION_POLICY_CORE_H
#define GPSLAB_SELECTION_POLICY_CORE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/** Geodesic duplicate tolerance shared with the recents dedupe policy. */
#define GPSLAB_SELECTION_DUPLICATE_TOLERANCE_METERS 5.0

/**
 * 1 when (latitude, longitude) is finite and EXACTLY the origin (0,0), including
 * signed zero. This is the only proof that authorizes a favorite at the exact
 * committed origin: a near-origin nonzero selection (e.g. 0.000001,0) must not,
 * because the user can intentionally enter it and later reset to 0,0 with
 * keep-last off.
 */
int GPSLabSelectionPointIsExactZero(double latitude, double longitude);

/** 1 when lat/lon/alt/heading are finite and inside the established ranges. */
int GPSLabSelectionFieldsValid(double latitude,
                               double longitude,
                               double altitude,
                               double heading);

/** 1 when the optional provider key is one of the known provider strings. */
int GPSLabSelectionProviderKeyKnown(const char *utf8, size_t length);

/** Great-circle distance in meters (self-contained policy copy). */
double GPSLabSelectionDistanceMeters(double fromLatitude,
                                     double fromLongitude,
                                     double toLatitude,
                                     double toLongitude);

/** 1 when (latitude, longitude) is within tolerance of any proof point. */
int GPSLabSelectionMatchesAnyProof(double latitude,
                                   double longitude,
                                   const double *proofLatitudes,
                                   const double *proofLongitudes,
                                   size_t proofCount,
                                   double toleranceMeters);

/** 1 when (latitude, longitude) is within tolerance of any existing point. */
int GPSLabSelectionHasDuplicate(double latitude,
                                double longitude,
                                const double *existingLatitudes,
                                const double *existingLongitudes,
                                size_t existingCount,
                                double toleranceMeters);

/**
 * Decides whether a favorite may be created at the resolved coordinate.
 *  - an active pending selection is always allowed (explicit user intent);
 *  - a valid non-zero committed coordinate is allowed;
 *  - an exact (0,0) committed coordinate is allowed only when an EXACT valid
 *    stored (0,0) proof exists (receipt or legacy recent/bookmark), so a
 *    pristine default or an unrelated enable/drift persistence write is refused
 *    without banning an intentional or legacy persisted 0,0. `hasExactZeroProof`
 *    must be computed with GPSLabSelectionPointIsExactZero, never a geodesic
 *    tolerance.
 * Returns 1 to allow, 0 to refuse.
 */
int GPSLabFavoriteSelectionAllowed(int hasPending,
                                   double committedLatitude,
                                   double committedLongitude,
                                   int hasExactZeroProof);

/**
 * Resolves the favorite coordinate the heart must capture: the active pending
 * preview (with its matching altitude) when one exists, otherwise the committed
 * anchor. Out-pointers may be NULL individually.
 */
void GPSLabFavoriteResolveShownSelection(int hasPending,
                                         double pendingLatitude,
                                         double pendingLongitude,
                                         double pendingAltitude,
                                         double committedLatitude,
                                         double committedLongitude,
                                         double committedAltitude,
                                         double *outLatitude,
                                         double *outLongitude,
                                         double *outAltitude);

#ifdef __cplusplus
}
#endif

#endif
