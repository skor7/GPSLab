//
//  GPSLabDriftModel.m
//  GPSLab
//
//  Bounded correlated random walk. The internal state is a 2D tangent-plane offset
//  plus a heading; each step turns by a small random angle and moves 0.15..1x the
//  step length, which keeps consecutive points correlated (a smooth-looking path)
//  instead of pure white noise.
//

#import "GPSLabDriftModel.h"

#import <math.h>

#import "GPSLabGeodesy.h"
#import "GPSLabTypes.h"

static const double kGPSLabMaxTurnRadians = 0.6;      // ~34 degrees per step
static const double kGPSLabMinStepFactor = 0.15;

// Definitions at the bottom of this file.
static double GPSLabRandomUnit(void);
static double GPSLabRandomInRange(double minValue, double maxValue);

@implementation GPSLabDriftModel {
    double _northMeters;
    double _eastMeters;
    double _headingRadians;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _northMeters = 0.0;
        _eastMeters = 0.0;
        _headingRadians = 0.0;
    }
    return self;
}

- (void)reset {
    _northMeters = 0.0;
    _eastMeters = 0.0;
    _headingRadians = 0.0;
}

- (BOOL)hasOffset {
    return hypot(_northMeters, _eastMeters) > 0.0001;
}

- (CLLocationCoordinate2D)currentAroundAnchor:(CLLocationCoordinate2D)anchor {
    return GPSLabCoordinateFromOffset(anchor, _northMeters, _eastMeters);
}

- (CLLocationCoordinate2D)advanceAroundAnchor:(CLLocationCoordinate2D)anchor
                                      radius:(double)radius
                                  stepMeters:(double)stepMeters {
    double safeRadius = GPSLabClampDouble(radius, 1.0, 500.0);
    double safeStep = GPSLabClampDouble(stepMeters, 0.05, safeRadius);
    if (safeStep > safeRadius) {
        safeStep = safeRadius;
    }

    double turn = GPSLabRandomInRange(-kGPSLabMaxTurnRadians, kGPSLabMaxTurnRadians);
    _headingRadians += turn;

    double distance = GPSLabRandomInRange(kGPSLabMinStepFactor * safeStep, safeStep);
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

    return GPSLabCoordinateFromOffset(anchor, _northMeters, _eastMeters);
}

@end

#pragma mark - Random helpers

static double GPSLabRandomUnit(void) {
    return (double)arc4random() / (double)UINT32_MAX;
}

static double GPSLabRandomInRange(double minValue, double maxValue) {
    return minValue + ((maxValue - minValue) * GPSLabRandomUnit());
}
