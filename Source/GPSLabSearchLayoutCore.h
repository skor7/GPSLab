//
//  GPSLabSearchLayoutCore.h
//  GPSLab
//
//  Pure C search-session lifecycle and results-panel layout policy. This file
//  has no Foundation/UIKit dependency so the exact rules the overlay obeys at
//  runtime are compiled both into the dylib and into the portable CI test.
//
//  The Objective-C overlay maps live UIKit state (editing, query updates, the
//  keyboard layout guide frame) into these functions. The search bar itself is
//  a standalone UISearchBar owned by the fixed GPSLab container; the results
//  controller is a GPSLab-owned child, so no UISearchController presentation
//  layer is involved.
//

#ifndef GPSLAB_SEARCH_LAYOUT_CORE_H
#define GPSLAB_SEARCH_LAYOUT_CORE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Search session phase.
 *
 *   Inactive -> Editing -> Results -> Inactive
 *
 * `Commit` only promotes Editing -> Results. Only an active (Editing) phase may
 * commit, so a late `textDidEndEditing`/query callback after a cancel can never
 * resurrect the session.
 */
typedef enum {
    GPSLabSearchPhaseInactive = 0,
    GPSLabSearchPhaseEditing = 1,
    GPSLabSearchPhaseResults = 2,
} GPSLabSearchPhase;

/** Session state. `generation` invalidates in-flight work started by an older session. */
typedef struct {
    GPSLabSearchPhase phase;
    unsigned long generation;
} GPSLabSearchSession;

/** Starts a new editing session and advances the generation. Idempotent-safe. */
void GPSLabSearchSessionBegin(GPSLabSearchSession *session);

/** Promotes Editing -> Results. No-op unless the session is actively editing. */
void GPSLabSearchSessionCommit(GPSLabSearchSession *session);

/** Ends the session (any phase -> Inactive) and advances the generation. */
void GPSLabSearchSessionEnd(GPSLabSearchSession *session);

/** 1 while the phase is Editing or Results. */
int GPSLabSearchSessionIsActive(const GPSLabSearchSession *session);

/** Current phase; Inactive for a NULL session. */
GPSLabSearchPhase GPSLabSearchSessionPhase(const GPSLabSearchSession *session);

/** Current generation; 0 for a NULL session. */
unsigned long GPSLabSearchSessionGeneration(const GPSLabSearchSession *session);

/**
 * 1 when the session is active and still on the given generation, so a result
 * that was started during this session is safe to apply.
 */
int GPSLabSearchSessionIsCurrent(const GPSLabSearchSession *session, unsigned long generation);

/** 1 only in the Editing phase: the sole state allowed to commit a query. */
int GPSLabSearchSessionCanCommit(const GPSLabSearchSession *session);

/** Query threshold: 1 when the (NSString) character count reaches 3. */
int GPSLabSearchQueryIsSearchable(size_t character_count);

/**
 * Stable standalone search-bar height: max(intrinsic_height, minimum_height).
 * A non-finite or non-positive intrinsic height collapses to the minimum, so a
 * bar measured before layout never forces a negative/zero height. This value
 * depends only on the bar's intrinsic size and the floor: it is deliberately
 * independent of the viewport, the keyboard and the search phase, so the bar
 * cannot be stretched by the results panel's constraints.
 */
double GPSLabSearchBarHeight(double intrinsic_height, double minimum_height);

/** Layout bounds for the bounded results panel. */
typedef struct {
    /** Compact floor for the empty/short-query message (points). */
    double min_height;
    /** Preferred compact height for the empty/short-query message (points). */
    double compact_height;
    /** Absolute cap for the results panel (points). */
    double max_height;
    /** Fraction of the viewport the panel may use (0..1, e.g. 0.45). */
    double max_viewport_fraction;
} GPSLabSearchLayoutMetrics;

/**
 * Clamps a dimension into [minimum, maximum]. NaN returns `minimum`, infinities
 * return the nearest bound. Swaps bounds when minimum > maximum.
 */
double GPSLabSearchClampDimension(double value, double minimum, double maximum);

/**
 * Usable height for the results panel: the distance from `top_offset` down to
 * the effective bottom boundary (the keyboard layout guide top in view
 * coordinates, already not below the viewport). Never negative; NaN/infinite
 * inputs collapse to 0.
 */
double GPSLabSearchAvailableHeight(double viewport_height, double top_offset, double bottom_boundary);

/**
 * Chooses the results-panel height:
 *
 *   has_results: min(content_height, viewport * max_viewport_fraction,
 *                    max_height, available_height), floored at min_height;
 *   otherwise:   min(compact_height, viewport * max_viewport_fraction,
 *                    max_height, available_height), floored at min_height.
 *
 * The result is always within [0, available] and is never negative.
 */
double GPSLabSearchResultsHeight(double available_height, double viewport_height,
                                 double content_height, int has_results,
                                 GPSLabSearchLayoutMetrics metrics);

#ifdef __cplusplus
}
#endif

#endif /* GPSLAB_SEARCH_LAYOUT_CORE_H */
