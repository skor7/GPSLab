//
//  GPSLabSearchLayoutCore.c
//  GPSLab
//
//  Pure C search-session lifecycle and results-panel sizing. Compiled into the
//  dylib and into the portable CI test; no Foundation/UIKit dependency.
//

#include "GPSLabSearchLayoutCore.h"

#include <math.h>

/** Returns 1 for a finite double (NaN and infinities are not finite). */
static int GPSLabSearchIsFinite(double value) {
    return (isnan(value) || isinf(value)) ? 0 : 1;
}

/** NaN/infinite -> fallback, otherwise the value. */
static double GPSLabSearchSanitize(double value, double fallback) {
    return GPSLabSearchIsFinite(value) ? value : fallback;
}

void GPSLabSearchSessionBegin(GPSLabSearchSession *session) {
    if (session == NULL) {
        return;
    }
    session->phase = GPSLabSearchPhaseEditing;
    session->generation += 1;
}

void GPSLabSearchSessionCommit(GPSLabSearchSession *session) {
    if (session == NULL) {
        return;
    }
    // Only an actively editing session may commit; this makes a late
    // `textDidEndEditing`/query callback after a cancel a no-op.
    if (session->phase == GPSLabSearchPhaseEditing) {
        session->phase = GPSLabSearchPhaseResults;
    }
}

void GPSLabSearchSessionEnd(GPSLabSearchSession *session) {
    if (session == NULL) {
        return;
    }
    session->phase = GPSLabSearchPhaseInactive;
    session->generation += 1;
}

int GPSLabSearchSessionIsActive(const GPSLabSearchSession *session) {
    if (session == NULL) {
        return 0;
    }
    return session->phase != GPSLabSearchPhaseInactive ? 1 : 0;
}

GPSLabSearchPhase GPSLabSearchSessionPhase(const GPSLabSearchSession *session) {
    if (session == NULL) {
        return GPSLabSearchPhaseInactive;
    }
    return session->phase;
}

unsigned long GPSLabSearchSessionGeneration(const GPSLabSearchSession *session) {
    if (session == NULL) {
        return 0;
    }
    return session->generation;
}

int GPSLabSearchSessionIsCurrent(const GPSLabSearchSession *session, unsigned long generation) {
    if (session == NULL) {
        return 0;
    }
    if (session->phase == GPSLabSearchPhaseInactive) {
        return 0;
    }
    return session->generation == generation ? 1 : 0;
}

int GPSLabSearchSessionCanCommit(const GPSLabSearchSession *session) {
    if (session == NULL) {
        return 0;
    }
    return session->phase == GPSLabSearchPhaseEditing ? 1 : 0;
}

int GPSLabSearchQueryIsSearchable(size_t character_count) {
    return character_count >= 3 ? 1 : 0;
}

double GPSLabSearchBarHeight(double intrinsic_height, double minimum_height) {
    double floor_height = GPSLabSearchSanitize(minimum_height, 44.0);
    if (floor_height < 0.0) {
        floor_height = 0.0;
    }
    double height = GPSLabSearchSanitize(intrinsic_height, 0.0);
    if (height < floor_height) {
        height = floor_height;
    }
    return height;
}

double GPSLabSearchClampDimension(double value, double minimum, double maximum) {
    if (minimum > maximum) {
        double swap = minimum;
        minimum = maximum;
        maximum = swap;
    }
    if (isnan(value)) {
        // NaN resolves to the minimum bound; infinities fall through to the
        // ordinary comparisons (so +infinity clamps to the maximum).
        return minimum;
    }
    if (value < minimum) {
        return minimum;
    }
    if (value > maximum) {
        return maximum;
    }
    return value;
}

double GPSLabSearchAvailableHeight(double viewport_height, double top_offset, double bottom_boundary) {
    double viewport = GPSLabSearchSanitize(viewport_height, 0.0);
    double top = GPSLabSearchSanitize(top_offset, 0.0);
    double boundary = GPSLabSearchSanitize(bottom_boundary, 0.0);
    if (viewport < 0.0) {
        viewport = 0.0;
    }
    if (top < 0.0) {
        top = 0.0;
    }
    // The keyboard guide can never extend past the viewport bottom.
    if (boundary > viewport) {
        boundary = viewport;
    }
    double available = boundary - top;
    return available > 0.0 ? available : 0.0;
}

double GPSLabSearchResultsHeight(double available_height, double viewport_height,
                                 double content_height, int has_results,
                                 GPSLabSearchLayoutMetrics metrics) {
    double available = GPSLabSearchSanitize(available_height, 0.0);
    if (available < 0.0) {
        available = 0.0;
    }

    double viewport = GPSLabSearchSanitize(viewport_height, 0.0);
    if (viewport < 0.0) {
        viewport = 0.0;
    }

    double fraction = GPSLabSearchSanitize(metrics.max_viewport_fraction, 0.0);
    if (fraction < 0.0) {
        fraction = 0.0;
    }
    if (fraction > 1.0) {
        fraction = 1.0;
    }
    double cap = viewport * fraction;

    double max_height = GPSLabSearchSanitize(metrics.max_height, 0.0);
    if (max_height < 0.0) {
        max_height = 0.0;
    }
    if (max_height < cap) {
        cap = max_height;
    }

    double desired = has_results ? GPSLabSearchSanitize(content_height, 0.0)
                                 : GPSLabSearchSanitize(metrics.compact_height, 0.0);
    if (desired < 0.0) {
        desired = 0.0;
    }

    double floor_height = GPSLabSearchSanitize(metrics.min_height, 0.0);
    if (floor_height < 0.0) {
        floor_height = 0.0;
    }
    if (desired < floor_height) {
        desired = floor_height;
    }
    if (desired > cap) {
        desired = cap;
    }
    if (desired > available) {
        desired = available;
    }
    return desired > 0.0 ? desired : 0.0;
}
