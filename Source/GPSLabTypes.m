//
//  GPSLabTypes.m
//  GPSLab
//
//  Small pure helpers shared across the dylib. No state, no I/O.
//

#import "GPSLabTypes.h"

#import <math.h>

double GPSLabClampDouble(double value, double minimum, double maximum) {
    if (isnan(value)) {
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

BOOL GPSLabIsValidLatitude(double latitude) {
    return isfinite(latitude) && latitude >= -90.0 && latitude <= 90.0;
}

BOOL GPSLabIsValidLongitude(double longitude) {
    return isfinite(longitude) && longitude >= -180.0 && longitude <= 180.0;
}

BOOL GPSLabIsValidCoordinate(double latitude, double longitude) {
    return GPSLabIsValidLatitude(latitude) && GPSLabIsValidLongitude(longitude);
}

double GPSLabMinDriftRadiusMeters(void) {
    return 0.0;
}

double GPSLabMaxDriftRadiusMeters(void) {
    return 50.0;
}

double GPSLabDefaultDriftRadiusMeters(void) {
    return 5.0;
}

double GPSLabClampDriftRadiusMeters(double radius) {
    return GPSLabClampDouble(radius, GPSLabMinDriftRadiusMeters(), GPSLabMaxDriftRadiusMeters());
}

double GPSLabSpeedKmhForRouteMode(GPSLabRouteMode mode, double customSpeedKmh) {
    switch (mode) {
        case GPSLabRouteModeWalking:
            return 5.0;
        case GPSLabRouteModeCycling:
            return 15.0;
        case GPSLabRouteModeDriving:
            return 50.0;
        case GPSLabRouteModeCustom:
            return GPSLabClampDouble(customSpeedKmh, 1.0, 300.0);
    }
    return 50.0;
}

NSString *GPSLabRouteModeName(GPSLabRouteMode mode) {
    switch (mode) {
        case GPSLabRouteModeDriving:
            return @"Driving";
        case GPSLabRouteModeWalking:
            return @"Walking";
        case GPSLabRouteModeCycling:
            return @"Cycling";
        case GPSLabRouteModeCustom:
            return @"Custom";
    }
    return @"Driving";
}

NSString *GPSLabStopBehaviorName(GPSLabStopBehavior behavior) {
    switch (behavior) {
        case GPSLabStopBehaviorStayAtCurrent:
            return @"Stay";
        case GPSLabStopBehaviorReturnToStart:
            return @"Return";
    }
    return @"Stay";
}
