//
//  GPSLabManualEntryViewController.m
//  GPSLab
//
//  Manual anchor entry. Validation is intentionally unchanged from the dashboard:
//  latitude must be -90..90 and longitude -180..180; altitude is clamped; a blank
//  course means "invalid" (-1).
//

#import "GPSLabManualEntryViewController.h"

#import "GPSLabGeodesy.h"
#import "GPSLabTypes.h"

@implementation GPSLabManualEntryViewController {
    UITextField *_latitudeField;
    UITextField *_longitudeField;
    UITextField *_altitudeField;
    UITextField *_headingField;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Manual coordinate";

    _latitudeField = [self decimalFieldWithPlaceholder:@"Latitude"];
    _longitudeField = [self decimalFieldWithPlaceholder:@"Longitude"];
    _altitudeField = [self decimalFieldWithPlaceholder:@"Altitude (m)"];
    _headingField = [self decimalFieldWithPlaceholder:@"Course (deg or -1)"];
    _latitudeField.text = [NSString stringWithFormat:@"%.6f", self.initialLatitude];
    _longitudeField.text = [NSString stringWithFormat:@"%.6f", self.initialLongitude];
    _altitudeField.text = [NSString stringWithFormat:@"%.1f", self.initialAltitude];
    _headingField.text = [NSString stringWithFormat:@"%.1f", self.initialHeading];

    UIButton *apply = [self actionButtonWithTitle:@"Apply" action:@selector(applyTapped)];

    UIStackView *content = self.contentStack;
    [content addArrangedSubview:[self sectionHeaderLabel:@"Anchor"]];
    [content addArrangedSubview:_latitudeField];
    [content addArrangedSubview:_longitudeField];
    [content addArrangedSubview:_altitudeField];
    [content addArrangedSubview:_headingField];
    [content addArrangedSubview:apply];
}

- (void)applyTapped {
    double latitude = [_latitudeField.text doubleValue];
    double longitude = [_longitudeField.text doubleValue];
    double altitude = [_altitudeField.text doubleValue];
    double heading = _headingField.text.length > 0 ? [_headingField.text doubleValue] : -1.0;

    if (!GPSLabIsValidCoordinate(latitude, longitude)) {
        [self showAlertWithTitle:@"Invalid coordinate"
                         message:@"Latitude must be -90..90 and longitude -180..180."];
        return;
    }

    double clampedAltitude = GPSLabClampDouble(altitude, -500.0, 100000.0);
    double normalizedHeading = GPSLabNormalizeHeading(heading);
    if (self.applyHandler != nil) {
        self.applyHandler(CLLocationCoordinate2DMake(latitude, longitude), clampedAltitude, normalizedHeading);
    }
    [self gpslab_dismissSheet];
}

@end
