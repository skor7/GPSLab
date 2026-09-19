//
//  GPSLabGeodesy.h
//  GPSLab
//
//  Clean-room geodesy helpers built on the local tangent-plane approximation and
//  the haversine distance formula. Pure math only.
//

#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

NS_ASSUME_NONNULL_BEGIN

/** Mean Earth radius used by the haversine distance, in meters. */
FOUNDATION_EXPORT double GPSLabEarthRadiusMeters(void);

/** Great-circle distance between two coordinates, in meters. */
FOUNDATION_EXPORT double GPSLabDistanceMeters(CLLocationCoordinate2D from,
                                              CLLocationCoordinate2D to);

/** Initial bearing from `from` to `to` in degrees [0, 360). */
FOUNDATION_EXPORT double GPSLabBearingDegrees(CLLocationCoordinate2D from,
                                              CLLocationCoordinate2D to);

/**
 * Converts a small local offset (north/east meters) around a base coordinate into a
 * concrete coordinate. Latitude is clamped to [-90, 90] and longitude is wrapped.
 */
FOUNDATION_EXPORT CLLocationCoordinate2D GPSLabCoordinateFromOffset(CLLocationCoordinate2D base,
                                                                    double northMeters,
                                                                    double eastMeters);

/** Linear interpolation between two coordinates; fraction is clamped to [0, 1]. */
FOUNDATION_EXPORT CLLocationCoordinate2D GPSLabInterpolateCoordinate(CLLocationCoordinate2D from,
                                                                    CLLocationCoordinate2D to,
                                                                    double fraction);

/**
 * Normalizes a heading to either a valid course in [0, 360) or -1 for "invalid".
 * Any value below 0 is treated as invalid.
 */
FOUNDATION_EXPORT double GPSLabNormalizeHeading(double heading);

NS_ASSUME_NONNULL_END
