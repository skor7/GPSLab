//
//  GPSLabDriftModel.m
//  GPSLab
//
//  Bounded correlated random walk. The internal state is a 2D tangent-plane offset
//  plus a heading; each step turns by a small random angle and moves 0.15..1x the
//  step length, which keeps consecutive points correlated (a smooth-looking path)
//  instead of pure white noise.
//
//  Bounds are enforced twice against the BASE coordinate: the tangent-plane offset
//  is clamped to the radius, then the emitted coordinate is checked with the
//  geodesic distance and scaled back onto the boundary. The state is never allowed
//  to accumulate past the radius, and radius 0 is an exact base fix.
//

#import "GPSLabDriftModel.h"

#import <math.h>
#import <stdint.h>
#import <stdlib.h>

#import "GPSLabGeodesy.h"
#import "GPSLabTypes.h"

static const double kGPSLabMaxTurnRadians = 0.6;      // ~34 degrees per step
static const double kGPSLabMinStepFactor = 0.15;
static const int kGPSLabMaxClampIterations = 8;

// Definitions at the bottom of this file.
static double GPSLabRandomUnitDefault(void);

@interface GPSLabDriftModel ()
@property (nonatomic, copy) GPSLabDriftRandomUnitProvider randomSource;
@end

@implementation GPSLabDriftModel {
    double _northMeters;
    double _eastMeters;
    double _headingRadians;
}

- (instancetype)init {
    return [self initWithRandomUnitProvider:nil];
}

- (instancetype)initWithRandomUnitProvider:(nullable GPSLabDriftRandomUnitProvider)provider {
    self = [super init];
    if (self) {
        if (provider != nil) {
            _randomSource = [provider copy];
        } else {
            _randomSource = ^double(void) { return GPSLabRandomUnitDefault(); };
        }
        _northMeters = 0.0;
        _eastMeters = 0.0;
        _headingRadians = 0.0;
    }
    return self;
}

#pragma mark - Random source

- (GPSLabDriftRandomUnitProvider)randomUnitProvider {
    return _randomSource;
}

- (void)setRandomUnitProvider:(nullable GPSLabDriftRandomUnitProvider)randomUnitProvider {
    if (randomUnitProvider != nil) {
        _randomSource = [randomUnitProvider copy];
    } else {
        _randomSource = ^double(void) { return GPSLabRandomUnitDefault(); };
    }
}

- (double)randomInRangeMin:(double)minValue max:(double)maxValue {
    double unit = self.randomSource();
    if (!(unit >= 0.0)) { // also rejects NaN
        unit = 0.0;
    } else if (unit > 1.0) {
        unit = 1.0;
    }
    return minValue + ((maxValue - minValue) * unit);
}

#pragma mark - Walk

- (void)reset {
    _northMeters = 0.0;
    _eastMeters = 0.0;
    _headingRadians = 0.0;
}

- (CLLocationCoordinate2D)currentAroundAnchor:(CLLocationCoordinate2D)anchor {
    return GPSLabCoordinateFromOffset(anchor, _northMeters, _eastMeters);
}

- (CLLocationCoordinate2D)advanceAroundAnchor:(CLLocationCoordinate2D)anchor
                                       radius:(double)radius
                                   stepMeters:(double)stepMeters {
    double safeRadius = GPSLabClampDriftRadiusMeters(radius);
    if (safeRadius <= 0.0) {
        // Radius 0 is the exact base: no displacement, and no stale offset may leak
        // into a later radius change.
        [self reset];
        return anchor;
    }

    double safeStep = GPSLabClampDouble(stepMeters, 0.0001, safeRadius);
    if (safeStep > safeRadius) {
        safeStep = safeRadius;
    }

    double turn = [self randomInRangeMin:-kGPSLabMaxTurnRadians max:kGPSLabMaxTurnRadians];
    _headingRadians += turn;

    double distance = [self randomInRangeMin:(kGPSLabMinStepFactor * safeStep) max:safeStep];
    double candidateNorth = _northMeters + (cos(_headingRadians) * distance);
    double candidateEast = _eastMeters + (sin(_headingRadians) * distance);

    double candidateRadius = hypot(candidateNorth, candidateEast);
    if (candidateRadius > safeRadius && candidateRadius > 0.0) {
        // Clamp back onto the boundary and aim the heading toward the anchor so the
        // walk does not stick to the edge in a straight line.
        double scale = safeRadius / candidateRadius;
        candidateNorth *= scale;
        candidateEast *= scale;
        _headingRadians = atan2(-candidateEast, -candidateNorth);
    }

    _northMeters = candidateNorth;
    _eastMeters = candidateEast;

    return [self clampedCoordinateAroundAnchor:anchor radius:safeRadius];
}

// The tangent-plane clamp above is not exactly the geodesic distance, so pull the
// offset in until the emitted coordinate really is within `radius` meters. Scaling
// (never snapping to the anchor) keeps the path continuous.
- (CLLocationCoordinate2D)clampedCoordinateAroundAnchor:(CLLocationCoordinate2D)anchor
                                                 radius:(double)radius {
    CLLocationCoordinate2D coordinate = GPSLabCoordinateFromOffset(anchor,
                                                                   _northMeters,
                                                                   _eastMeters);
    if (radius <= 0.0) {
        return anchor;
    }
    for (int iteration = 0; iteration < kGPSLabMaxClampIterations; iteration++) {
        double distance = GPSLabDistanceMeters(anchor, coordinate);
        if (distance <= radius || distance <= 0.0) {
            break;
        }
        // Scale exactly onto the boundary; the conversion is only very slightly
        // non-linear at these ranges, so at most a couple of iterations converge.
        double scale = radius / distance;
        _northMeters *= scale;
        _eastMeters *= scale;
        coordinate = GPSLabCoordinateFromOffset(anchor, _northMeters, _eastMeters);
    }
    return coordinate;
}

@end

#pragma mark - Random helpers

static double GPSLabRandomUnitDefault(void) {
    return (double)arc4random() / (double)UINT32_MAX;
}
