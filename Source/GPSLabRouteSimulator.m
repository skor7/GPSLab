//
//  GPSLabRouteSimulator.m
//  GPSLab
//
//  Time-driven route simulation. All mutable state is guarded by a single lock.
//

#import "GPSLabRouteSimulator.h"

#import <MapKit/MapKit.h>
#import <math.h>
#import <os/lock.h>
#import <stdlib.h>
#import <string.h>

#import "GPSLabGeodesy.h"

static NSString * const kGPSLabRouteErrorDomain = @"com.gpslab.runtime.route";

@interface GPSLabRouteSimulator ()

- (void)handleDirectionsResponse:(nullable MKDirectionsResponse *)response
                           error:(nullable NSError *)error
                      directions:(MKDirections *)directions
                      generation:(NSUInteger)generation;
- (void)buildStraightLineRouteFrom:(CLLocationCoordinate2D)start
                                to:(CLLocationCoordinate2D)end
                        generation:(NSUInteger)generation;
- (void)installTickTimerLocked;
- (void)cancelTickTimerLocked;
- (void)tick;
- (double)elapsedLocked;
- (void)positionLockedAtDistance:(double)distance
                      coordinate:(CLLocationCoordinate2D *)coordinate
                          course:(double *)course;
- (void)setRouteCoordinatesLocked:(const CLLocationCoordinate2D *)coordinates count:(NSUInteger)count;
- (void)clearRouteArraysLocked;

@end

@implementation GPSLabRouteSimulator {
    os_unfair_lock _lock;

    GPSLabRouteState _state;
    BOOL _loading;
    BOOL _completed;
    BOOL _hasRoute;
    BOOL _hasLastCoordinate;
    NSUInteger _generation;

    CLLocationCoordinate2D _startCoordinate;
    CLLocationCoordinate2D _endCoordinate;
    CLLocationCoordinate2D _lastCoordinate;
    double _lastCourse;

    CLLocationCoordinate2D *_coordinates;
    double *_cumulative;
    NSUInteger _coordinateCount;
    double _totalDistanceMeters;
    double _speedMetersPerSecond;
    double _durationSeconds;

    double _startTime;
    double _pausedAccumulated;
    double _pauseStart;

    GPSLabRouteCompletion _completion;
    MKDirections *_directions;
    dispatch_source_t _tickTimer;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _state = GPSLabRouteStateIdle;
    }
    return self;
}

- (void)dealloc {
    if (_tickTimer != nil) {
        dispatch_source_cancel(_tickTimer);
        _tickTimer = nil;
    }
    if (_directions != nil) {
        [_directions cancel];
        _directions = nil;
    }
    if (_coordinates != NULL) {
        free(_coordinates);
        _coordinates = NULL;
    }
    if (_cumulative != NULL) {
        free(_cumulative);
        _cumulative = NULL;
    }
}

#pragma mark - Public state

- (GPSLabRouteState)state {
    os_unfair_lock_lock(&_lock);
    GPSLabRouteState state = _state;
    os_unfair_lock_unlock(&_lock);
    return state;
}

- (BOOL)isLoading {
    os_unfair_lock_lock(&_lock);
    BOOL loading = _loading;
    os_unfair_lock_unlock(&_lock);
    return loading;
}

- (BOOL)isActive {
    os_unfair_lock_lock(&_lock);
    BOOL active = (_state != GPSLabRouteStateIdle) || _loading;
    os_unfair_lock_unlock(&_lock);
    return active;
}

- (double)progress {
    os_unfair_lock_lock(&_lock);
    double progress = 0.0;
    if (_completed) {
        progress = 1.0;
    } else if (_totalDistanceMeters > 0.0 && _speedMetersPerSecond > 0.0) {
        double travelled = _speedMetersPerSecond * [self elapsedLocked];
        progress = travelled / _totalDistanceMeters;
    }
    os_unfair_lock_unlock(&_lock);
    return GPSLabClampDouble(progress, 0.0, 1.0);
}

- (double)totalDistanceMeters {
    os_unfair_lock_lock(&_lock);
    double distance = _totalDistanceMeters;
    os_unfair_lock_unlock(&_lock);
    return distance;
}

- (double)durationSeconds {
    os_unfair_lock_lock(&_lock);
    double duration = _durationSeconds;
    os_unfair_lock_unlock(&_lock);
    return duration;
}

- (double)currentSpeedMetersPerSecond {
    os_unfair_lock_lock(&_lock);
    double speed = (_state == GPSLabRouteStatePlaying && _completed == NO) ? _speedMetersPerSecond : 0.0;
    os_unfair_lock_unlock(&_lock);
    return speed;
}

#pragma mark - Start / control

- (void)startRouteFrom:(CLLocationCoordinate2D)start
                    to:(CLLocationCoordinate2D)end
                  mode:(GPSLabRouteMode)mode
        customSpeedKmh:(double)customSpeedKmh
            completion:(nullable GPSLabRouteCompletion)completion {
    GPSLabRouteCompletion completionCopy = completion != nil ? [completion copy] : nil;

    os_unfair_lock_lock(&_lock);
    MKDirections *oldDirections = _directions;
    _directions = nil;
    [self cancelTickTimerLocked];
    [self clearRouteArraysLocked];

    _generation += 1;
    NSUInteger generation = _generation;

    _completion = completionCopy;
    _state = GPSLabRouteStateIdle;
    _loading = YES;
    _completed = NO;
    _hasRoute = YES;
    _hasLastCoordinate = YES;

    _startCoordinate = start;
    _endCoordinate = end;
    _lastCoordinate = start;
    _lastCourse = 0.0;

    _speedMetersPerSecond = GPSLabSpeedKmhForRouteMode(mode, GPSLabClampDouble(customSpeedKmh, 1.0, 300.0)) / 3.6;
    _durationSeconds = 0.0;
    _totalDistanceMeters = 0.0;

    _startTime = 0.0;
    _pausedAccumulated = 0.0;
    _pauseStart = 0.0;
    os_unfair_lock_unlock(&_lock);

    if (oldDirections != nil) {
        [oldDirections cancel];
    }

    if (mode == GPSLabRouteModeCustom) {
        [self buildStraightLineRouteFrom:start to:end generation:generation];
        return;
    }

    MKPlacemark *sourcePlacemark = [[MKPlacemark alloc] initWithCoordinate:start];
    MKPlacemark *destinationPlacemark = [[MKPlacemark alloc] initWithCoordinate:end];
    MKMapItem *sourceItem = [[MKMapItem alloc] initWithPlacemark:sourcePlacemark];
    MKMapItem *destinationItem = [[MKMapItem alloc] initWithPlacemark:destinationPlacemark];

    MKDirectionsRequest *request = [[MKDirectionsRequest alloc] init];
    request.source = sourceItem;
    request.destination = destinationItem;
    request.requestsAlternateRoutes = NO;
    // Cycling has no public transport type; the walking network is the closest
    // clean-room approximation. See the header for details.
    request.transportType = (mode == GPSLabRouteModeWalking || mode == GPSLabRouteModeCycling)
        ? MKDirectionsTransportTypeWalking
        : MKDirectionsTransportTypeAutomobile;

    MKDirections *directions = [[MKDirections alloc] initWithRequest:request];

    os_unfair_lock_lock(&_lock);
    if (_generation != generation || _loading == NO) {
        // Superseded between unlock and here.
        os_unfair_lock_unlock(&_lock);
        [directions cancel];
        return;
    }
    _directions = directions;
    os_unfair_lock_unlock(&_lock);

    [directions calculateDirectionsWithCompletionHandler:^(MKDirectionsResponse * _Nullable response,
                                                           NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self handleDirectionsResponse:response error:error directions:directions generation:generation];
        });
    }];
}

- (void)pause {
    os_unfair_lock_lock(&_lock);
    if (_state == GPSLabRouteStatePlaying) {
        _pauseStart = [NSDate timeIntervalSinceReferenceDate];
        _state = GPSLabRouteStatePaused;
    }
    os_unfair_lock_unlock(&_lock);
}

- (void)resume {
    os_unfair_lock_lock(&_lock);
    if (_state == GPSLabRouteStatePaused) {
        double now = [NSDate timeIntervalSinceReferenceDate];
        if (_pauseStart > 0.0) {
            _pausedAccumulated += (now - _pauseStart);
        }
        _pauseStart = 0.0;
        _state = GPSLabRouteStatePlaying;
    }
    os_unfair_lock_unlock(&_lock);
}

- (void)stop {
    os_unfair_lock_lock(&_lock);
    [self cancelTickTimerLocked];
    _state = GPSLabRouteStateIdle;
    _loading = NO;
    _completion = nil;
    MKDirections *directions = _directions;
    _directions = nil;
    os_unfair_lock_unlock(&_lock);

    if (directions != nil) {
        [directions cancel];
    }
}

#pragma mark - Position queries

- (BOOL)currentCoordinate:(CLLocationCoordinate2D *)coordinate course:(double *)course {
    os_unfair_lock_lock(&_lock);

    if (_hasRoute == NO || _coordinateCount == 0) {
        BOOL hasFallback = _hasLastCoordinate;
        CLLocationCoordinate2D fallbackCoordinate = _lastCoordinate;
        double fallbackCourse = _lastCourse;
        os_unfair_lock_unlock(&_lock);
        if (hasFallback) {
            if (coordinate != NULL) {
                *coordinate = fallbackCoordinate;
            }
            if (course != NULL) {
                *course = fallbackCourse;
            }
        }
        return hasFallback;
    }

    double travelled = _speedMetersPerSecond * [self elapsedLocked];
    travelled = GPSLabClampDouble(travelled, 0.0, _totalDistanceMeters);

    CLLocationCoordinate2D position = _coordinates[0];
    double positionCourse = _lastCourse;
    [self positionLockedAtDistance:travelled
                        coordinate:&position
                            course:&positionCourse];

    _lastCoordinate = position;
    _lastCourse = positionCourse;
    _hasLastCoordinate = YES;

    if (coordinate != NULL) {
        *coordinate = position;
    }
    if (course != NULL) {
        *course = positionCourse;
    }

    os_unfair_lock_unlock(&_lock);
    return YES;
}

- (BOOL)lastCoordinate:(CLLocationCoordinate2D *)coordinate {
    os_unfair_lock_lock(&_lock);
    BOOL has = _hasLastCoordinate;
    CLLocationCoordinate2D stored = _lastCoordinate;
    os_unfair_lock_unlock(&_lock);
    if (has && coordinate != NULL) {
        *coordinate = stored;
    }
    return has;
}

- (BOOL)routeStartCoordinate:(CLLocationCoordinate2D *)coordinate {
    os_unfair_lock_lock(&_lock);
    BOOL has = _hasRoute;
    CLLocationCoordinate2D stored = _startCoordinate;
    os_unfair_lock_unlock(&_lock);
    if (has && coordinate != NULL) {
        *coordinate = stored;
    }
    return has;
}

#pragma mark - Directions handling

- (void)handleDirectionsResponse:(MKDirectionsResponse * _Nullable)response
                           error:(NSError * _Nullable)error
                      directions:(MKDirections *)directions
                      generation:(NSUInteger)generation {
    os_unfair_lock_lock(&_lock);

    if (_generation != generation || _directions != directions) {
        // A newer route superseded this request.
        os_unfair_lock_unlock(&_lock);
        return;
    }
    _directions = nil;
    _loading = NO;

    MKRoute *route = response.routes.firstObject;
    if (error != nil || route == nil) {
        _state = GPSLabRouteStateIdle;
        _hasRoute = NO;
        GPSLabRouteCompletion completion = _completion;
        _completion = nil;
        os_unfair_lock_unlock(&_lock);

        NSError *routeError = error;
        if (routeError == nil) {
            routeError = [NSError errorWithDomain:kGPSLabRouteErrorDomain
                                             code:-1
                                         userInfo:@{NSLocalizedDescriptionKey: @"No route available"}];
        }
        if (completion != nil) {
            completion(routeError);
        }
        return;
    }

    MKPolyline *polyline = route.polyline;
    NSUInteger pointCount = polyline.pointCount;
    if (pointCount == 0) {
        _state = GPSLabRouteStateIdle;
        _hasRoute = NO;
        GPSLabRouteCompletion completion = _completion;
        _completion = nil;
        os_unfair_lock_unlock(&_lock);

        NSError *routeError = [NSError errorWithDomain:kGPSLabRouteErrorDomain
                                                  code:-2
                                              userInfo:@{NSLocalizedDescriptionKey: @"Empty route geometry"}];
        if (completion != nil) {
            completion(routeError);
        }
        return;
    }

    MKMapPoint *mapPoints = polyline.points;
    CLLocationCoordinate2D *coordinates = malloc(pointCount * sizeof(CLLocationCoordinate2D));
    if (coordinates == NULL) {
        _state = GPSLabRouteStateIdle;
        _hasRoute = NO;
        GPSLabRouteCompletion completion = _completion;
        _completion = nil;
        os_unfair_lock_unlock(&_lock);

        NSError *routeError = [NSError errorWithDomain:kGPSLabRouteErrorDomain
                                                  code:-3
                                              userInfo:@{NSLocalizedDescriptionKey: @"Out of memory"}];
        if (completion != nil) {
            completion(routeError);
        }
        return;
    }
    for (NSUInteger index = 0; index < pointCount; index++) {
        coordinates[index] = MKCoordinateForMapPoint(mapPoints[index]);
    }

    [self setRouteCoordinatesLocked:coordinates count:pointCount];
    free(coordinates);

    if (_coordinateCount == 0) {
        _state = GPSLabRouteStateIdle;
        _hasRoute = NO;
        GPSLabRouteCompletion completion = _completion;
        _completion = nil;
        os_unfair_lock_unlock(&_lock);

        NSError *routeError = [NSError errorWithDomain:kGPSLabRouteErrorDomain
                                                  code:-4
                                              userInfo:@{NSLocalizedDescriptionKey: @"Route geometry unavailable"}];
        if (completion != nil) {
            completion(routeError);
        }
        return;
    }

    _startCoordinate = _coordinates[0];
    _endCoordinate = _coordinates[_coordinateCount - 1];
    _lastCoordinate = _startCoordinate;
    _lastCourse = (_coordinateCount > 1)
        ? GPSLabBearingDegrees(_coordinates[0], _coordinates[1])
        : 0.0;
    _hasLastCoordinate = YES;

    _durationSeconds = (_speedMetersPerSecond > 0.0) ? (_totalDistanceMeters / _speedMetersPerSecond) : 0.0;
    _startTime = [NSDate timeIntervalSinceReferenceDate];
    _pausedAccumulated = 0.0;
    _pauseStart = 0.0;
    _completed = NO;
    _state = GPSLabRouteStatePlaying;
    [self installTickTimerLocked];

    os_unfair_lock_unlock(&_lock);
}

- (void)buildStraightLineRouteFrom:(CLLocationCoordinate2D)start
                                to:(CLLocationCoordinate2D)end
                        generation:(NSUInteger)generation {
    os_unfair_lock_lock(&_lock);
    if (_loading == NO || _generation != generation) {
        os_unfair_lock_unlock(&_lock);
        return;
    }

    CLLocationCoordinate2D coordinates[2];
    coordinates[0] = start;
    coordinates[1] = end;
    [self setRouteCoordinatesLocked:coordinates count:2];

    if (_coordinateCount == 0) {
        // Degenerate start == end: still report a valid, completed-looking route.
        _state = GPSLabRouteStatePlaying;
        _loading = NO;
        _hasRoute = YES;
        _completed = NO;
        _durationSeconds = 1.0;
        _totalDistanceMeters = 0.0;
        _startTime = [NSDate timeIntervalSinceReferenceDate];
        _pausedAccumulated = 0.0;
        _pauseStart = 0.0;
        _lastCoordinate = start;
        _lastCourse = 0.0;
        _hasLastCoordinate = YES;
        [self installTickTimerLocked];
        os_unfair_lock_unlock(&_lock);
        return;
    }

    _startCoordinate = start;
    _endCoordinate = end;
    _lastCoordinate = start;
    _lastCourse = GPSLabBearingDegrees(start, end);
    _hasLastCoordinate = YES;
    _durationSeconds = (_speedMetersPerSecond > 0.0) ? (_totalDistanceMeters / _speedMetersPerSecond) : 0.0;
    _startTime = [NSDate timeIntervalSinceReferenceDate];
    _pausedAccumulated = 0.0;
    _pauseStart = 0.0;
    _completed = NO;
    _state = GPSLabRouteStatePlaying;
    _loading = NO;
    [self installTickTimerLocked];

    os_unfair_lock_unlock(&_lock);
}

#pragma mark - Timer

- (void)installTickTimerLocked {
    [self cancelTickTimerLocked];
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,
                                                     0,
                                                     0,
                                                     dispatch_get_main_queue());
    if (timer == NULL) {
        return;
    }
    uint64_t interval = (uint64_t)(0.25 * (double)NSEC_PER_SEC);
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)interval),
                              interval,
                              (uint64_t)(0.05 * (double)NSEC_PER_SEC));

    __weak GPSLabRouteSimulator *weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        GPSLabRouteSimulator *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        [strongSelf tick];
    });

    _tickTimer = timer;
    dispatch_resume(timer);
}

- (void)cancelTickTimerLocked {
    if (_tickTimer != nil) {
        dispatch_source_cancel(_tickTimer);
        _tickTimer = nil;
    }
}

- (void)tick {
    GPSLabRouteCompletion completion = nil;

    os_unfair_lock_lock(&_lock);
    if (_state == GPSLabRouteStatePlaying) {
        double elapsed = [self elapsedLocked];
        if (_durationSeconds <= 0.0 || elapsed >= _durationSeconds) {
            if (_coordinateCount > 0) {
                _lastCoordinate = _coordinates[_coordinateCount - 1];
                _lastCourse = (_coordinateCount > 1)
                    ? GPSLabBearingDegrees(_coordinates[_coordinateCount - 2], _coordinates[_coordinateCount - 1])
                    : _lastCourse;
                _hasLastCoordinate = YES;
            }
            _state = GPSLabRouteStateIdle;
            _loading = NO;
            _completed = YES;
            [self cancelTickTimerLocked];
            completion = _completion;
            _completion = nil;
        }
    }
    os_unfair_lock_unlock(&_lock);

    if (completion != nil) {
        completion(nil);
    }
}

#pragma mark - Locked helpers (caller holds the lock)

- (double)elapsedLocked {
    if (_startTime <= 0.0) {
        return 0.0;
    }
    double reference = (_state == GPSLabRouteStatePaused && _pauseStart > 0.0)
        ? _pauseStart
        : [NSDate timeIntervalSinceReferenceDate];
    double elapsed = reference - _startTime - _pausedAccumulated;
    return elapsed > 0.0 ? elapsed : 0.0;
}

- (void)positionLockedAtDistance:(double)distance
                      coordinate:(CLLocationCoordinate2D *)coordinate
                          course:(double *)course {
    if (_coordinateCount == 0) {
        return;
    }
    if (_coordinateCount == 1) {        *coordinate = _coordinates[0];
        *course = _lastCourse;
        return;
    }

    NSUInteger index = 0;
    while ((index + 2) < _coordinateCount && _cumulative[index + 1] < distance) {
        index++;
    }
    if ((index + 1) >= _coordinateCount) {
        index = _coordinateCount - 2;
    }

    double segmentStart = _cumulative[index];
    double segmentEnd = _cumulative[index + 1];
    double segmentLength = segmentEnd - segmentStart;
    double fraction = (segmentLength > 0.0) ? ((distance - segmentStart) / segmentLength) : 0.0;

    *coordinate = GPSLabInterpolateCoordinate(_coordinates[index], _coordinates[index + 1], fraction);
    *course = GPSLabBearingDegrees(_coordinates[index], _coordinates[index + 1]);
}

- (void)setRouteCoordinatesLocked:(const CLLocationCoordinate2D *)coordinates count:(NSUInteger)count {
    [self clearRouteArraysLocked];
    if (count == 0 || coordinates == NULL) {
        return;
    }

    CLLocationCoordinate2D *newCoordinates = malloc(count * sizeof(CLLocationCoordinate2D));
    double *newCumulative = malloc(count * sizeof(double));
    if (newCoordinates == NULL || newCumulative == NULL) {
        if (newCoordinates != NULL) {
            free(newCoordinates);
        }
        if (newCumulative != NULL) {
            free(newCumulative);
        }
        return;
    }

    memcpy(newCoordinates, coordinates, count * sizeof(CLLocationCoordinate2D));
    newCumulative[0] = 0.0;
    for (NSUInteger index = 1; index < count; index++) {
        newCumulative[index] = newCumulative[index - 1] +
            GPSLabDistanceMeters(newCoordinates[index - 1], newCoordinates[index]);
    }

    _coordinates = newCoordinates;
    _cumulative = newCumulative;
    _coordinateCount = count;
    _totalDistanceMeters = newCumulative[count - 1];
}

- (void)clearRouteArraysLocked {
    if (_coordinates != NULL) {
        free(_coordinates);
        _coordinates = NULL;
    }
    if (_cumulative != NULL) {
        free(_cumulative);
        _cumulative = NULL;
    }
    _coordinateCount = 0;
    _totalDistanceMeters = 0.0;
}

@end
