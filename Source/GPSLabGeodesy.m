//
//  GPSLabGeodesy.m
//  GPSLab
//
//  Clean-room geodesy helpers. Pure math only.
//

#import "GPSLabGeodesy.h"
#import "GPSLabTypes.h"

#import <math.h>

static const double kGPSLabMetersPerDegreeLatitude = 111320.0;
static const double kGPSLabMinCosLatitude = 0.01; // keeps longitude math finite at the poles

double GPSLabEarthRadiusMeters(void) {
    return 6371008.8;
}

double GPSLabDistanceMeters(CLLocationCoordinate2D from, CLLocationCoordinate2D to) {
    double lat1 = from.latitude * M_PI / 180.0;
    double lat2 = to.latitude * M_PI / 180.0;
    double deltaLat = lat2 - lat1;
    double deltaLon = (to.longitude - from.longitude) * M_PI / 180.0;

    double sinHalfLat = sin(deltaLat / 2.0);
    double sinHalfLon = sin(deltaLon / 2.0);
    double h = (sinHalfLat * sinHalfLat) + (cos(lat1) * cos(lat2) * sinHalfLon * sinHalfLon);
    if (h > 1.0) {
        h = 1.0;
    }

    return 2.0 * GPSLabEarthRadiusMeters() * asin(sqrt(h));
}

double GPSLabBearingDegrees(CLLocationCoordinate2D from, CLLocationCoordinate2D to) {
    double lat1 = from.latitude * M_PI / 180.0;
    double lat2 = to.latitude * M_PI / 180.0;
    double deltaLon = (to.longitude - from.longitude) * M_PI / 180.0;

    double y = sin(deltaLon) * cos(lat2);
    double x = (cos(lat1) * sin(lat2)) - (sin(lat1) * cos(lat2) * cos(deltaLon));
    double bearing = atan2(y, x) * 180.0 / M_PI;
    if (bearing < 0.0) {
        bearing += 360.0;
    }
    return bearing;
}

CLLocationCoordinate2D GPSLabCoordinateFromOffset(CLLocationCoordinate2D base,
                                                  double northMeters,
                                                  double eastMeters) {
    double latitude = base.latitude + (northMeters / kGPSLabMetersPerDegreeLatitude);
    latitude = GPSLabClampDouble(latitude, -90.0, 90.0);

    double cosLatitude = cos(latitude * M_PI / 180.0);
    if (fabs(cosLatitude) < kGPSLabMinCosLatitude) {
        cosLatitude = (cosLatitude < 0.0) ? -kGPSLabMinCosLatitude : kGPSLabMinCosLatitude;
    }

    double longitude = base.longitude +
        (eastMeters / (kGPSLabMetersPerDegreeLatitude * cosLatitude));
    longitude = fmod(longitude + 540.0, 360.0) - 180.0;

    return CLLocationCoordinate2DMake(latitude, longitude);
}

CLLocationCoordinate2D GPSLabInterpolateCoordinate(CLLocationCoordinate2D from,
                                                  CLLocationCoordinate2D to,
                                                  double fraction) {
    double t = GPSLabClampDouble(fraction, 0.0, 1.0);
    double latitude = from.latitude + ((to.latitude - from.latitude) * t);
    double longitude = from.longitude + ((to.longitude - from.longitude) * t);
    return CLLocationCoordinate2DMake(latitude, longitude);
}

double GPSLabNormalizeHeading(double heading) {
    if (!isfinite(heading) || heading < 0.0) {
        return -1.0;
    }
    double wrapped = fmod(heading, 360.0);
    if (wrapped < 0.0) {
        wrapped += 360.0;
    }
    return wrapped;
}
