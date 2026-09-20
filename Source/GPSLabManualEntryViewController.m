//
//  GPSLabManualEntryViewController.m
//  GPSLab
//
//  Manual anchor entry. Validation is intentionally unchanged from the dashboard:
//  latitude must be -90..90 and longitude -180..180; altitude is clamped; a blank
//  course means "invalid" (-1). Numeric fields accept Arabic-Indic digits and the
//  Arabic decimal separator because they are normalized before parsing; valid
//  ASCII input is preserved. Full consumption is required (no trailing garbage).
//

#import "GPSLabManualEntryViewController.h"

#import "GPSLabGeodesy.h"
#import "GPSLabLocalization.h"
#import "GPSLabTypes.h"

@implementation GPSLabManualEntryViewController {
    UITextField *_latitudeField;
    UITextField *_longitudeField;
    UITextField *_altitudeField;
    UITextField *_headingField;
    UIButton *_applyButton;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    _latitudeField = [self decimalFieldWithPlaceholder:@""];
    _longitudeField = [self decimalFieldWithPlaceholder:@""];
    _altitudeField = [self decimalFieldWithPlaceholder:@""];
    _headingField = [self decimalFieldWithPlaceholder:@""];
    _latitudeField.text = [NSString stringWithFormat:@"%.6f", self.initialLatitude];
    _longitudeField.text = [NSString stringWithFormat:@"%.6f", self.initialLongitude];
    _altitudeField.text = [NSString stringWithFormat:@"%.1f", self.initialAltitude];
    _headingField.text = [NSString stringWithFormat:@"%.1f", self.initialHeading];

    _applyButton = [self actionButtonWithTitle:@"" action:@selector(applyTapped)];

    UIStackView *content = self.contentStack;
    [content addArrangedSubview:[self sectionHeaderLabel:GPSLabLocalized(@"options.section.anchor")]];
    [content addArrangedSubview:_latitudeField];
    [content addArrangedSubview:_longitudeField];
    [content addArrangedSubview:_altitudeField];
    [content addArrangedSubview:_headingField];
    [content addArrangedSubview:_applyButton];

    [self gpslab_applyLocalization];
}

#pragma mark - Localization

- (void)gpslab_applyLocalization {
    self.title = GPSLabLocalized(@"manual.title");
    _latitudeField.placeholder = GPSLabLocalized(@"manual.latitude");
    _longitudeField.placeholder = GPSLabLocalized(@"manual.longitude");
    _altitudeField.placeholder = GPSLabLocalized(@"manual.altitude");
    _headingField.placeholder = GPSLabLocalized(@"manual.heading");
    [_applyButton setTitle:GPSLabLocalized(@"common.apply") forState:UIControlStateNormal];
    [GPSLabLocalization applyLanguageAttributesToView:self.view];
}

#pragma mark - Actions

- (void)applyTapped {
    double latitude = 0.0;
    double longitude = 0.0;
    double altitude = 0.0;
    double heading = -1.0;

    if (![GPSLabLocalization parseNumber:_latitudeField.text value:&latitude] ||
        ![GPSLabLocalization parseNumber:_longitudeField.text value:&longitude]) {
        [self showAlertWithTitle:GPSLabLocalized(@"manual.invalid.title")
                         message:GPSLabLocalized(@"manual.invalid.number")];
        return;
    }
    if (_altitudeField.text.length > 0 &&
        ![GPSLabLocalization parseNumber:_altitudeField.text value:&altitude]) {
        [self showAlertWithTitle:GPSLabLocalized(@"manual.invalid.title")
                         message:GPSLabLocalized(@"manual.invalid.number")];
        return;
    }
    if (_headingField.text.length > 0 &&
        ![GPSLabLocalization parseNumber:_headingField.text value:&heading]) {
        [self showAlertWithTitle:GPSLabLocalized(@"manual.invalid.title")
                         message:GPSLabLocalized(@"manual.invalid.number")];
        return;
    }

    if (!GPSLabIsValidCoordinate(latitude, longitude)) {
        [self showAlertWithTitle:GPSLabLocalized(@"manual.invalid.title")
                         message:GPSLabLocalized(@"manual.invalid.message")];
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
