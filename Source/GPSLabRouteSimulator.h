//
//  GPSLabRouteSimulator.h
//  GPSLab
//
//  Time-driven route simulation.
//
//  * Driving/Walking use MapKit directions (MKDirections) for the polyline.
//  * Cycling is approximated with the walking pedestrian network because the
//    public MKDirectionsTransportType has no cycling constant; the configured
//    cycling speed (15 km/h default) is still applied. No private API is used.
//  * Custom does not call MapKit at all: it interpolates a straight line between
//    the start and end coordinates at the configured speed.
//
//  The simulator never starts hardware location updates. It only produces
//  coordinates; GPSLabEngine is responsible for turning those into CLLocations.
//

#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

#import "GPSLabTypes.h"

NS_ASSUME_NONNULL_BEGIN

typedef void (^GPSLabRouteCompletion)(NSError * _Nullable error);

@interface GPSLabRouteSimulator : NSObject

- (GPSLabRouteState)state;
- (BOOL)isLoading;
- (BOOL)isActive;

/** Progress in [0, 1]. 1 once the route has been completed. */
- (double)progress;
- (double)totalDistanceMeters;
- (double)durationSeconds;
- (double)currentSpeedMetersPerSecond;

/**
 * Starts a new route. Any previous route is cancelled first. `completion` is
 * invoked on the main queue when the route finishes or fails, never on manual stop.
 */
- (void)startRouteFrom:(CLLocationCoordinate2D)start
                    to:(CLLocationCoordinate2D)end
                  mode:(GPSLabRouteMode)mode
        customSpeedKmh:(double)customSpeedKmh
            completion:(nullable GPSLabRouteCompletion)completion;

- (void)pause;
- (void)resume;
- (void)stop;

/** Current interpolated position. Returns NO when no route has been started yet. */
- (BOOL)currentCoordinate:(CLLocationCoordinate2D *)coordinate course:(double *)course;

/** Last known route coordinate (used for the "stay at current" stop behavior). */
- (BOOL)lastCoordinate:(CLLocationCoordinate2D *)coordinate;

/** The start coordinate of the active/last route (used for "return to start"). */
- (BOOL)routeStartCoordinate:(CLLocationCoordinate2D *)coordinate;

@end

NS_ASSUME_NONNULL_END
