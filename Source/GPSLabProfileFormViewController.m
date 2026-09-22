//
//  GPSLabProfileFormViewController.m
//  GPSLab
//

#import "GPSLabProfileFormViewController.h"

#import <CoreLocation/CoreLocation.h>

// UIButton.contentEdgeInsets is deprecated under UIButtonConfiguration (iOS 15)
// but remains the supported API for plain, configuration-less buttons. The
// deprecation is suppressed narrowly for this file; no configuration is used.
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

#import "GPSLabBluetoothSimulationModule.h"
#import "GPSLabGeodesy.h"
#import "GPSLabLocalization.h"
#import "GPSLabSimulationRegistry.h"
#import "GPSLabWiFiSimulationModule.h"

@interface GPSLabProfileFormViewController () <UITextFieldDelegate>

@property (nonatomic, strong) GPSLabProfile *source;

@property (nonatomic, strong) UITextField *nameField;
@property (nonatomic, strong) UISegmentedControl *locationSegment;

@property (nonatomic, strong) UIStackView *staticSection;
@property (nonatomic, strong) UIStackView *routeSection;

@property (nonatomic, strong) UITextField *staticLatField;
@property (nonatomic, strong) UITextField *staticLonField;
@property (nonatomic, strong) UITextField *staticAltField;
@property (nonatomic, strong) UITextField *staticHeadingField;

@property (nonatomic, strong) UITextField *routeStartLatField;
@property (nonatomic, strong) UITextField *routeStartLonField;
@property (nonatomic, strong) UITextField *routeEndLatField;
@property (nonatomic, strong) UITextField *routeEndLonField;
@property (nonatomic, strong) UITextField *routeAltField;
@property (nonatomic, strong) UITextField *routeHeadingField;
@property (nonatomic, strong) UISegmentedControl *routeModeSegment;
@property (nonatomic, strong) UITextField *routeSpeedField;

@property (nonatomic, strong) UILabel *driftHeader;
@property (nonatomic, strong) UISwitch *driftSwitch;
@property (nonatomic, strong) UITextField *driftRadiusField;
@property (nonatomic, strong) UILabel *driftLabel;

@property (nonatomic, strong) UILabel *wifiHeader;
@property (nonatomic, strong) UISwitch *wifiSwitch;
@property (nonatomic, strong) UILabel *wifiAttachLabel;
@property (nonatomic, strong) UIStackView *wifiSection;
@property (nonatomic, strong) UITextField *wifiNameField;
@property (nonatomic, strong) UITextField *wifiSSIDField;
@property (nonatomic, strong) UISegmentedControl *wifiSignalSegment;

@property (nonatomic, strong) UILabel *bleHeader;
@property (nonatomic, strong) UISwitch *bleSwitch;
@property (nonatomic, strong) UILabel *bleAttachLabel;
@property (nonatomic, strong) UIStackView *bleSection;
@property (nonatomic, strong) UITextField *bleNameField;
@property (nonatomic, strong) UITextField *bleDeviceField;
@property (nonatomic, strong) UISegmentedControl *bleRSSISegment;
@property (nonatomic, strong) UITextField *blePatternField;

@property (nonatomic, strong) UILabel *scheduleHeader;
@property (nonatomic, strong) UISwitch *scheduleSwitch;
@property (nonatomic, strong) UILabel *scheduleAttachLabel;
@property (nonatomic, strong) UIStackView *scheduleSection;
@property (nonatomic, strong) UISegmentedControl *scheduleModeSegment;
@property (nonatomic, strong) UIDatePicker *scheduleStartPicker;
@property (nonatomic, strong) UIDatePicker *scheduleEndPicker;
@property (nonatomic, strong) UILabel *scheduleNote;

@property (nonatomic, strong) UILabel *nameHeader;
@property (nonatomic, strong) UILabel *locationHeader;
@property (nonatomic, strong) UILabel *routeHeader;
@property (nonatomic, strong) UILabel *experimentalHeader;
@property (nonatomic, strong) UIButton *saveButton;
@property (nonatomic, strong) UIButton *deleteButton;

@end

@implementation GPSLabProfileFormViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.source = self.existingProfile ?: self.candidateProfile ?: [self defaultSource];
    [self buildForm];
    [self gpslab_applyLocalization];
    [self updateSectionVisibility];
}

- (GPSLabProfile *)defaultSource {
    return [[GPSLabProfile alloc] initWithIdentifier:[[NSUUID UUID] UUIDString]
                                                name:@""
                                        locationMode:GPSLabProfileLocationStatic
                                           latitude:0.0
                                          longitude:0.0
                                           altitude:0.0
                                            heading:-1.0
                                       driftEnabled:NO
                                  driftRadiusMeters:GPSLabDefaultDriftRadiusMeters()
                                              route:nil
                                               wifi:nil
                                          bluetooth:nil
                                           schedule:nil];
}

#pragma mark - Construction

- (UIStackView *)verticalSectionWithViews:(NSArray<UIView *> *)views {
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:views];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 10.0;
    return stack;
}

- (UIStackView *)twoColumnRow:(UIView *)left right:(UIView *)right {
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[left, right]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.distribution = UIStackViewDistributionFillEqually;
    row.spacing = 8.0;
    return row;
}

- (UILabel *)fieldLabelWithKey:(NSString *)key {
    UILabel *label = [self sectionHeaderLabel:GPSLabLocalized(key)];
    label.textColor = GPSLabLocalized(key).length > 0 ? UIColor.secondaryLabelColor : label.textColor;
    return label;
}

- (UITextField *)plainFieldWithPlaceholder:(NSString *)placeholder {
    UITextField *field = [[UITextField alloc] initWithFrame:CGRectZero];
    field.placeholder = placeholder;
    field.borderStyle = UITextBorderStyleRoundedRect;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.autocapitalizationType = UITextAutocapitalizationTypeWords;
    field.delegate = self;
    return field;
}

- (UITextField *)numericFieldWithValue:(double)value {
    UITextField *field = [self decimalFieldWithPlaceholder:@""];
    field.text = [GPSLabLocalization decimalString:value fractionDigits:5];
    return field;
}

- (UISegmentedControl *)segmentedWithCount:(NSUInteger)count {
    NSMutableArray *items = [NSMutableArray array];
    for (NSUInteger index = 0; index < count; index++) {
        [items addObject:@""];
    }
    return [[UISegmentedControl alloc] initWithItems:items];
}

- (void)buildForm {
    GPSLabProfile *source = self.source;

    // Name
    self.nameHeader = [self fieldLabelWithKey:@"profiles.field.name"];
    self.nameField = [self plainFieldWithPlaceholder:GPSLabLocalized(@"profiles.placeholder.name")];
    self.nameField.text = source.name;
    UIScrollView *suggestions = [[UIScrollView alloc] initWithFrame:CGRectZero];
    suggestions.showsHorizontalScrollIndicator = NO;
    UIStackView *suggestionRow = [[UIStackView alloc] initWithFrame:CGRectZero];
    suggestionRow.axis = UILayoutConstraintAxisHorizontal;
    suggestionRow.spacing = 8.0;
    NSArray<NSString *> *suggestionKeys = @[@"profiles.suggest.home", @"profiles.suggest.work",
                                            @"profiles.suggest.riyadh"];
    for (NSString *key in suggestionKeys) {
        UIButton *chip = [UIButton buttonWithType:UIButtonTypeSystem];
        [chip setTitle:GPSLabLocalized(key) forState:UIControlStateNormal];
        chip.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
        chip.backgroundColor = UIColor.tertiarySystemFillColor;
        chip.layer.cornerRadius = 12.0;
        chip.contentEdgeInsets = UIEdgeInsetsMake(5.0, 10.0, 5.0, 10.0);
        chip.accessibilityIdentifier = key;
        [chip addTarget:self action:@selector(suggestionTapped:) forControlEvents:UIControlEventTouchUpInside];
        [suggestionRow addArrangedSubview:chip];
    }
    [suggestions addSubview:suggestionRow];
    suggestionRow.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [suggestionRow.topAnchor constraintEqualToAnchor:suggestions.contentLayoutGuide.topAnchor],
        [suggestionRow.bottomAnchor constraintEqualToAnchor:suggestions.contentLayoutGuide.bottomAnchor],
        [suggestionRow.leadingAnchor constraintEqualToAnchor:suggestions.contentLayoutGuide.leadingAnchor],
        [suggestionRow.trailingAnchor constraintEqualToAnchor:suggestions.contentLayoutGuide.trailingAnchor],
        [suggestionRow.heightAnchor constraintEqualToAnchor:suggestions.frameLayoutGuide.heightAnchor],
        [suggestions.heightAnchor constraintEqualToConstant:38.0],
    ]];

    // Location mode
    self.locationHeader = [self fieldLabelWithKey:@"profiles.field.location"];
    self.locationSegment = [self segmentedWithCount:2];
    self.locationSegment.selectedSegmentIndex =
        (source.locationMode == GPSLabProfileLocationRoute) ? 1 : 0;
    [self.locationSegment addTarget:self
                             action:@selector(locationModeChanged)
                   forControlEvents:UIControlEventValueChanged];

    // Static fields
    self.staticLatField = [self numericFieldWithValue:source.latitude];
    self.staticLonField = [self numericFieldWithValue:source.longitude];
    self.staticAltField = [self numericFieldWithValue:source.altitude];
    self.staticHeadingField = [self numericFieldWithValue:source.heading];
    self.staticSection = [self verticalSectionWithViews:@[
        [self fieldLabelWithKey:@"manual.latitude"], self.staticLatField,
        [self fieldLabelWithKey:@"manual.longitude"], self.staticLonField,
        [self twoColumnRow:self.staticAltField right:self.staticHeadingField],
    ]];

    // Route fields
    self.routeStartLatField = [self numericFieldWithValue:source.route.startLatitude];
    self.routeStartLonField = [self numericFieldWithValue:source.route.startLongitude];
    self.routeEndLatField = [self numericFieldWithValue:source.route.endLatitude];
    self.routeEndLonField = [self numericFieldWithValue:source.route.endLongitude];
    self.routeAltField = [self numericFieldWithValue:source.altitude];
    self.routeHeadingField = [self numericFieldWithValue:source.heading];
    self.routeSpeedField = [self numericFieldWithValue:source.route.customSpeedKmh > 0.0
                                                       ? source.route.customSpeedKmh : 50.0];
    self.routeModeSegment = [self segmentedWithCount:4];
    self.routeModeSegment.selectedSegmentIndex = (NSInteger)(source.route ? source.route.mode
                                                                         : GPSLabRouteModeDriving);
    self.routeHeader = [self fieldLabelWithKey:@"route.section.endpoints"];
    self.routeSection = [self verticalSectionWithViews:@[
        self.routeHeader,
        [self fieldLabelWithKey:@"route.setStart"], [self twoColumnRow:self.routeStartLatField right:self.routeStartLonField],
        [self fieldLabelWithKey:@"route.setEnd"], [self twoColumnRow:self.routeEndLatField right:self.routeEndLonField],
        [self twoColumnRow:self.routeAltField right:self.routeHeadingField],
        [self fieldLabelWithKey:@"route.section.mode"], self.routeModeSegment,
        [self fieldLabelWithKey:@"route.customSpeed"], self.routeSpeedField,
    ]];

    // Drift
    self.driftHeader = [self fieldLabelWithKey:@"profiles.section.drift"];
    self.driftSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
    self.driftSwitch.on = source.driftEnabled;
    [self.driftSwitch addTarget:self action:@selector(toggleChanged) forControlEvents:UIControlEventValueChanged];
    self.driftLabel = [self bodyLabel:GPSLabLocalized(@"profiles.field.drift")];
    self.driftRadiusField = [self numericFieldWithValue:source.driftRadiusMeters];

    // Wi-Fi test config
    self.wifiHeader = [self fieldLabelWithKey:@"sim.wifi.title"];
    self.wifiSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
    self.wifiSwitch.on = source.wifi != nil;
    [self.wifiSwitch addTarget:self action:@selector(toggleChanged) forControlEvents:UIControlEventValueChanged];
    self.wifiAttachLabel = [self bodyLabel:GPSLabLocalized(@"profiles.attach.wifi")];
    self.wifiNameField = [self plainFieldWithPlaceholder:GPSLabLocalized(@"sim.wifi.profileName")];
    self.wifiNameField.text = source.wifi.profileName;
    self.wifiSSIDField = [self plainFieldWithPlaceholder:GPSLabLocalized(@"sim.wifi.ssid")];
    self.wifiSSIDField.text = source.wifi.ssid;
    self.wifiSignalSegment = [self segmentedWithCount:3];
    self.wifiSignalSegment.selectedSegmentIndex = [self signalIndexForValue:source.wifi.signal];
    self.wifiSection = [self verticalSectionWithViews:@[
        self.wifiNameField, self.wifiSSIDField,
        [self fieldLabelWithKey:@"sim.wifi.signal"], self.wifiSignalSegment,
    ]];

    // Bluetooth test config
    self.bleHeader = [self fieldLabelWithKey:@"sim.ble.title"];
    self.bleSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
    self.bleSwitch.on = source.bluetooth != nil;
    [self.bleSwitch addTarget:self action:@selector(toggleChanged) forControlEvents:UIControlEventValueChanged];
    self.bleAttachLabel = [self bodyLabel:GPSLabLocalized(@"profiles.attach.ble")];
    self.bleNameField = [self plainFieldWithPlaceholder:GPSLabLocalized(@"sim.ble.profileName")];
    self.bleNameField.text = source.bluetooth.profileName;
    self.bleDeviceField = [self plainFieldWithPlaceholder:GPSLabLocalized(@"sim.ble.deviceName")];
    self.bleDeviceField.text = source.bluetooth.deviceName;
    self.bleRSSISegment = [self segmentedWithCount:3];
    self.bleRSSISegment.selectedSegmentIndex = [self rssiIndexForValue:source.bluetooth.rssi];
    self.blePatternField = [self plainFieldWithPlaceholder:GPSLabLocalized(@"sim.ble.pattern")];
    self.blePatternField.text = source.bluetooth.pattern;
    self.bleSection = [self verticalSectionWithViews:@[
        self.bleNameField, self.bleDeviceField,
        [self fieldLabelWithKey:@"sim.ble.rssi"], self.bleRSSISegment,
        [self fieldLabelWithKey:@"sim.ble.pattern"], self.blePatternField,
    ]];

    // Schedule
    self.scheduleHeader = [self fieldLabelWithKey:@"profiles.section.schedule"];
    self.scheduleSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
    self.scheduleSwitch.on = source.schedule != nil;
    [self.scheduleSwitch addTarget:self action:@selector(toggleChanged) forControlEvents:UIControlEventValueChanged];
    self.scheduleAttachLabel = [self bodyLabel:GPSLabLocalized(@"profiles.attach.schedule")];
    self.scheduleModeSegment = [self segmentedWithCount:3];
    self.scheduleModeSegment.selectedSegmentIndex = (NSInteger)(source.schedule ? source.schedule.mode
                                                                               : GPSLabProfileScheduleOnce);
    [self.scheduleModeSegment addTarget:self action:@selector(scheduleModeChanged)
                       forControlEvents:UIControlEventValueChanged];
    NSDate *start = source.schedule != nil
        ? [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)source.schedule.startEpoch]
        : [NSDate dateWithTimeIntervalSinceNow:3600.0];
    NSDate *end = source.schedule != nil && source.schedule.endEpoch > source.schedule.startEpoch
        ? [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)source.schedule.endEpoch]
        : [start dateByAddingTimeInterval:3600.0];
    self.scheduleStartPicker = [self datePickerWithDate:start];
    self.scheduleEndPicker = [self datePickerWithDate:end];
    self.scheduleNote = [self bodyLabel:GPSLabLocalized(@"schedule.note")];
    self.scheduleSection = [self verticalSectionWithViews:@[
        [self fieldLabelWithKey:@"schedule.mode"], self.scheduleModeSegment,
        [self fieldLabelWithKey:@"schedule.start"], self.scheduleStartPicker,
        [self fieldLabelWithKey:@"schedule.end"], self.scheduleEndPicker,
        self.scheduleNote,
    ]];

    // Actions + note
    self.experimentalHeader = [self fieldLabelWithKey:@"profiles.section.experimental"];
    self.saveButton = [self actionButtonWithTitle:GPSLabLocalized(@"profiles.save")
                                           action:@selector(saveTapped)];
    self.deleteButton = [self actionButtonWithTitle:GPSLabLocalized(@"profiles.delete")
                                             action:@selector(deleteTapped)];
    UILabel *note = [self bodyLabel:GPSLabLocalized(@"profiles.note")];

    UIStackView *content = self.contentStack;
    [content addArrangedSubview:self.nameHeader];
    [content addArrangedSubview:self.nameField];
    [content addArrangedSubview:suggestions];
    [content addArrangedSubview:self.locationHeader];
    [content addArrangedSubview:self.locationSegment];
    [content addArrangedSubview:self.staticSection];
    [content addArrangedSubview:self.routeSection];
    [content addArrangedSubview:self.driftHeader];
    [content addArrangedSubview:[self rowWithTitle:GPSLabLocalized(@"profiles.field.drift")
                                          control:self.driftSwitch]];
    [content addArrangedSubview:[self rowWithTitle:GPSLabLocalized(@"fluctuation.radius")
                                          control:self.driftRadiusField]];
    [content addArrangedSubview:self.experimentalHeader];
    [content addArrangedSubview:self.wifiHeader];
    [content addArrangedSubview:[self rowWithTitle:GPSLabLocalized(@"profiles.attach.wifi")
                                          control:self.wifiSwitch]];
    [content addArrangedSubview:self.wifiSection];
    [content addArrangedSubview:self.bleHeader];
    [content addArrangedSubview:[self rowWithTitle:GPSLabLocalized(@"profiles.attach.ble")
                                          control:self.bleSwitch]];
    [content addArrangedSubview:self.bleSection];
    [content addArrangedSubview:self.scheduleHeader];
    [content addArrangedSubview:[self rowWithTitle:GPSLabLocalized(@"profiles.attach.schedule")
                                          control:self.scheduleSwitch]];
    [content addArrangedSubview:self.scheduleSection];
    [content addArrangedSubview:self.saveButton];
    if (self.existingProfile != nil) {
        [content addArrangedSubview:self.deleteButton];
    }
    [content addArrangedSubview:note];

    self.driftLabel.hidden = YES;
    self.wifiAttachLabel.hidden = YES;
    self.bleAttachLabel.hidden = YES;
    self.scheduleAttachLabel.hidden = YES;
}

- (UIDatePicker *)datePickerWithDate:(NSDate *)date {
    UIDatePicker *picker = [[UIDatePicker alloc] initWithFrame:CGRectZero];
    picker.datePickerMode = UIDatePickerModeDateAndTime;
    picker.preferredDatePickerStyle = UIDatePickerStyleCompact;
    picker.date = date;
    return picker;
}

- (NSInteger)signalIndexForValue:(NSInteger)value {
    if (value >= 75) {
        return 0;
    }
    if (value >= 45) {
        return 1;
    }
    return 2;
}

- (NSInteger)signalValueForIndex:(NSInteger)index {
    switch (index) {
        case 0: return 90;
        case 1: return 60;
        default: return 30;
    }
}

- (NSInteger)rssiIndexForValue:(NSInteger)value {
    if (value >= -52) {
        return 0;
    }
    if (value >= -67) {
        return 1;
    }
    return 2;
}

- (NSInteger)rssiValueForIndex:(NSInteger)index {
    switch (index) {
        case 0: return -45;
        case 1: return -60;
        default: return -75;
    }
}

#pragma mark - Localization

- (void)gpslab_applyLocalization {
    self.title = GPSLabLocalized(@"profiles.newTitle");
    if (self.nameHeader != nil) {
        self.nameHeader.text = GPSLabLocalized(@"profiles.field.name");
        self.nameField.placeholder = GPSLabLocalized(@"profiles.placeholder.name");
        self.locationHeader.text = GPSLabLocalized(@"profiles.field.location");
        self.routeHeader.text = GPSLabLocalized(@"route.section.endpoints");
        self.experimentalHeader.text = GPSLabLocalized(@"profiles.section.experimental");
        self.driftHeader.text = GPSLabLocalized(@"profiles.section.drift");
        self.wifiHeader.text = GPSLabLocalized(@"sim.wifi.title");
        self.bleHeader.text = GPSLabLocalized(@"sim.ble.title");
        self.scheduleHeader.text = GPSLabLocalized(@"profiles.section.schedule");
        self.wifiAttachLabel.text = GPSLabLocalized(@"profiles.attach.wifi");
        self.bleAttachLabel.text = GPSLabLocalized(@"profiles.attach.ble");
        self.scheduleAttachLabel.text = GPSLabLocalized(@"profiles.attach.schedule");
        self.scheduleNote.text = GPSLabLocalized(@"schedule.note");
        self.driftLabel.text = GPSLabLocalized(@"profiles.field.drift");
        [self.saveButton setTitle:GPSLabLocalized(@"profiles.save") forState:UIControlStateNormal];
        [self.deleteButton setTitle:GPSLabLocalized(@"profiles.delete") forState:UIControlStateNormal];
    }
    if (self.locationSegment != nil) {
        [self.locationSegment setTitle:GPSLabLocalized(@"profiles.mode.static") forSegmentAtIndex:0];
        [self.locationSegment setTitle:GPSLabLocalized(@"profiles.mode.route") forSegmentAtIndex:1];
    }
    if (self.routeModeSegment != nil) {
        [self.routeModeSegment setTitle:GPSLabLocalized(@"route.mode.driving") forSegmentAtIndex:0];
        [self.routeModeSegment setTitle:GPSLabLocalized(@"route.mode.walking") forSegmentAtIndex:1];
        [self.routeModeSegment setTitle:GPSLabLocalized(@"route.mode.cycling") forSegmentAtIndex:2];
        [self.routeModeSegment setTitle:GPSLabLocalized(@"route.mode.custom") forSegmentAtIndex:3];
    }
    if (self.wifiSignalSegment != nil) {
        [self.wifiSignalSegment setTitle:GPSLabLocalized(@"sim.signal.strong") forSegmentAtIndex:0];
        [self.wifiSignalSegment setTitle:GPSLabLocalized(@"sim.signal.medium") forSegmentAtIndex:1];
        [self.wifiSignalSegment setTitle:GPSLabLocalized(@"sim.signal.weak") forSegmentAtIndex:2];
    }
    if (self.bleRSSISegment != nil) {
        [self.bleRSSISegment setTitle:@"-45 dBm" forSegmentAtIndex:0];
        [self.bleRSSISegment setTitle:@"-60 dBm" forSegmentAtIndex:1];
        [self.bleRSSISegment setTitle:@"-75 dBm" forSegmentAtIndex:2];
    }
    if (self.scheduleModeSegment != nil) {
        [self.scheduleModeSegment setTitle:GPSLabLocalized(@"schedule.mode.none") forSegmentAtIndex:0];
        [self.scheduleModeSegment setTitle:GPSLabLocalized(@"schedule.mode.once") forSegmentAtIndex:1];
        [self.scheduleModeSegment setTitle:GPSLabLocalized(@"schedule.mode.window") forSegmentAtIndex:2];
    }
}

#pragma mark - Actions

- (void)suggestionTapped:(UIButton *)sender {
    self.nameField.text = GPSLabLocalized(sender.accessibilityIdentifier);
}

- (void)locationModeChanged {
    [self updateSectionVisibility];
}

- (void)toggleChanged {
    [self updateSectionVisibility];
}

- (void)scheduleModeChanged {
    [self updateSectionVisibility];
}

- (void)updateSectionVisibility {
    BOOL route = self.locationSegment.selectedSegmentIndex == 1;
    self.staticSection.hidden = route;
    self.routeSection.hidden = !route;
    self.wifiSection.hidden = !self.wifiSwitch.on;
    self.bleSection.hidden = !self.bleSwitch.on;
    BOOL scheduleOn = self.scheduleSwitch.on;
    self.scheduleSection.hidden = !scheduleOn;
    BOOL window = scheduleOn && self.scheduleModeSegment.selectedSegmentIndex == 2;
    self.scheduleStartPicker.hidden = !scheduleOn;
    self.scheduleEndPicker.hidden = !window;
}

#pragma mark - Save

- (BOOL)readNumber:(UITextField *)field into:(double *)outValue {
    double value = 0.0;
    if (![GPSLabLocalization parseNumber:field.text value:&value]) {
        return NO;
    }
    *outValue = value;
    return YES;
}

- (BOOL)readOptionalNumber:(UITextField *)field fallback:(double)fallback into:(double *)outValue {
    if (field.text.length == 0) {
        *outValue = fallback;
        return YES;
    }
    double value = 0.0;
    if (![GPSLabLocalization parseNumber:field.text value:&value]) {
        return NO;
    }
    *outValue = value;
    return YES;
}

- (void)saveTapped {
    NSString *name = [self.nameField.text stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (name.length == 0) {
        [self showAlertWithTitle:GPSLabLocalized(@"profiles.newTitle")
                         message:GPSLabLocalized(@"profiles.error.name")];
        return;
    }

    BOOL route = self.locationSegment.selectedSegmentIndex == 1;
    double latitude = 0.0, longitude = 0.0, altitude = 0.0, heading = -1.0;
    GPSLabProfileRoute *routeValue = nil;

    if (route) {
        double startLat = 0.0, startLon = 0.0, endLat = 0.0, endLon = 0.0;
        double routeAlt = 0.0, routeHeading = -1.0, speed = 50.0;
        if (![self readNumber:self.routeStartLatField into:&startLat] ||
            ![self readNumber:self.routeStartLonField into:&startLon] ||
            ![self readNumber:self.routeEndLatField into:&endLat] ||
            ![self readNumber:self.routeEndLonField into:&endLon] ||
            ![self readOptionalNumber:self.routeAltField fallback:0.0 into:&routeAlt] ||
            ![self readOptionalNumber:self.routeHeadingField fallback:-1.0 into:&routeHeading]) {
            [self showAlertWithTitle:GPSLabLocalized(@"profiles.newTitle")
                             message:GPSLabLocalized(@"profiles.error.coordinates")];
            return;
        }
        GPSLabRouteMode mode = (GPSLabRouteMode)self.routeModeSegment.selectedSegmentIndex;
        if (mode == GPSLabRouteModeCustom) {
            if (![self readNumber:self.routeSpeedField into:&speed]) {
                [self showAlertWithTitle:GPSLabLocalized(@"profiles.newTitle")
                                 message:GPSLabLocalized(@"profiles.error.route")];
                return;
            }
        }
        if (!GPSLabProfileCoordinateValid(startLat, startLon) ||
            !GPSLabProfileCoordinateValid(endLat, endLon) ||
            !GPSLabProfileAltitudeValid(routeAlt) ||
            !GPSLabProfileHeadingValid(routeHeading) ||
            !GPSLabProfileRouteModeValid((int)mode) ||
            !GPSLabProfileCustomSpeedValid(speed)) {
            [self showAlertWithTitle:GPSLabLocalized(@"profiles.newTitle")
                             message:GPSLabLocalized(@"profiles.error.route")];
            return;
        }
        routeValue = [[GPSLabProfileRoute alloc] initWithStartLatitude:startLat
                                                        startLongitude:startLon
                                                          endLatitude:endLat
                                                        endLongitude:endLon
                                                              altitude:routeAlt
                                                               heading:routeHeading
                                                                  mode:mode
                                                        customSpeedKmh:speed];
        latitude = startLat;
        longitude = startLon;
        altitude = routeAlt;
        heading = routeHeading;
    } else {
        double staticAlt = 0.0, staticHeading = -1.0;
        if (![self readNumber:self.staticLatField into:&latitude] ||
            ![self readNumber:self.staticLonField into:&longitude] ||
            ![self readOptionalNumber:self.staticAltField fallback:0.0 into:&staticAlt] ||
            ![self readOptionalNumber:self.staticHeadingField fallback:-1.0 into:&staticHeading]) {
            [self showAlertWithTitle:GPSLabLocalized(@"profiles.newTitle")
                             message:GPSLabLocalized(@"profiles.error.coordinates")];
            return;
        }
        if (!GPSLabProfileCoordinateValid(latitude, longitude) ||
            !GPSLabProfileAltitudeValid(staticAlt) ||
            !GPSLabProfileHeadingValid(staticHeading)) {
            [self showAlertWithTitle:GPSLabLocalized(@"profiles.newTitle")
                             message:GPSLabLocalized(@"profiles.error.coordinates")];
            return;
        }
        altitude = staticAlt;
        heading = staticHeading;
    }

    double radius = self.source.driftRadiusMeters;
    if (![self readOptionalNumber:self.driftRadiusField
                         fallback:self.source.driftRadiusMeters
                             into:&radius] ||
        !(radius >= 1.0 && radius <= 500.0)) {
        [self showAlertWithTitle:GPSLabLocalized(@"profiles.newTitle")
                         message:GPSLabLocalized(@"profiles.error.name")];
        return;
    }

    GPSLabProfileWiFiConfig *wifi = nil;
    if (self.wifiSwitch.on) {
        GPSLabProfileWiFiConfig *candidate =
            [[GPSLabProfileWiFiConfig alloc] initWithProfileName:self.wifiNameField.text ?: @""
                                                            ssid:self.wifiSSIDField.text ?: @""
                                                          signal:[self signalValueForIndex:self.wifiSignalSegment.selectedSegmentIndex]];
        wifi = [[GPSLabSimulationRegistry wifiModule] normalizedConfig:candidate];
        if (wifi == nil) {
            [self showAlertWithTitle:GPSLabLocalized(@"sim.wifi.title")
                             message:GPSLabLocalized(@"sim.error.required")];
            return;
        }
    }

    GPSLabProfileBluetoothConfig *bluetooth = nil;
    if (self.bleSwitch.on) {
        GPSLabProfileBluetoothConfig *candidate =
            [[GPSLabProfileBluetoothConfig alloc] initWithProfileName:self.bleNameField.text ?: @""
                                                           deviceName:self.bleDeviceField.text ?: @""
                                                                 rssi:[self rssiValueForIndex:self.bleRSSISegment.selectedSegmentIndex]
                                                              pattern:self.blePatternField.text ?: @""];
        bluetooth = [[GPSLabSimulationRegistry bluetoothModule] normalizedConfig:candidate];
        if (bluetooth == nil) {
            [self showAlertWithTitle:GPSLabLocalized(@"sim.ble.title")
                             message:GPSLabLocalized(@"sim.error.required")];
            return;
        }
    }

    GPSLabProfileSchedule *schedule = nil;
    if (self.scheduleSwitch.on) {
        NSInteger modeIndex = self.scheduleModeSegment.selectedSegmentIndex;
        if (modeIndex != 0) {
            long long startEpoch = (long long)[self.scheduleStartPicker.date timeIntervalSince1970];
            long long endEpoch = (modeIndex == 2)
                ? (long long)[self.scheduleEndPicker.date timeIntervalSince1970]
                : startEpoch;
            if (!GPSLabProfileScheduleValid(startEpoch, endEpoch) ||
                (modeIndex == 2 && endEpoch <= startEpoch)) {
                [self showAlertWithTitle:GPSLabLocalized(@"schedule.title")
                                 message:GPSLabLocalized(@"schedule.note")];
                return;
            }
            NSInteger offset = (NSInteger)[NSTimeZone.localTimeZone
                secondsFromGMTForDate:self.scheduleStartPicker.date];
            GPSLabProfileScheduleMode mode = (modeIndex == 2)
                ? GPSLabProfileScheduleWindow : GPSLabProfileScheduleOnce;
            schedule = [[GPSLabProfileSchedule alloc] initWithMode:mode
                                                        startEpoch:startEpoch
                                                          endEpoch:endEpoch
                                            timeZoneOffsetSeconds:offset];
        }
    }

    NSString *identifier = self.existingProfile.identifier ?: self.source.identifier;
    if (identifier.length == 0) {
        identifier = [[NSUUID UUID] UUIDString];
    }

    GPSLabProfile *profile =
        [[GPSLabProfile alloc] initWithIdentifier:identifier
                                             name:name
                                     locationMode:(route ? GPSLabProfileLocationRoute
                                                         : GPSLabProfileLocationStatic)
                                        latitude:latitude
                                       longitude:longitude
                                        altitude:altitude
                                         heading:heading
                                    driftEnabled:self.driftSwitch.on
                               driftRadiusMeters:radius
                                           route:routeValue
                                            wifi:wifi
                                       bluetooth:bluetooth
                                        schedule:schedule];

    // Preserve the optional, backward-compatible enabled preference across an edit
    // (the typed initializer cannot carry it; the new-profile default is decided by
    // the caller, which never overwrites an existing preference).
    if (self.existingProfile.hasEnabledPreference) {
        profile = [profile profileWithEnabledPreference:self.existingProfile.enabled];
    }

    if (self.saveHandler != nil && self.saveHandler(profile)) {
        [self gpslab_dismissSheet];
    }
}

- (void)deleteTapped {
    if (self.deleteHandler != nil) {
        self.deleteHandler();
    }
}

#pragma mark - UITextFieldDelegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

@end
