//
//  GPSLabSimulationSettingsViewController.m
//  GPSLab
//

#import "GPSLabSimulationSettingsViewController.h"

#import "GPSLabBluetoothSimulationModule.h"
#import "GPSLabLocalization.h"
#import "GPSLabSimulationRegistry.h"
#import "GPSLabWiFiSimulationModule.h"

@interface GPSLabSimulationSettingsViewController ()
@property (nonatomic, strong) UISegmentedControl *wifiSignalSegment;
@property (nonatomic, strong) UISegmentedControl *bleRSSISegment;
@property (nonatomic, strong) UITextField *nameField;
@property (nonatomic, strong) UITextField *ssidField;
@property (nonatomic, strong) UITextField *deviceField;
@property (nonatomic, strong) UITextField *patternField;
@property (nonatomic, strong) UILabel *noteLabel;
@end

@implementation GPSLabSimulationSettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    [self buildForm];
    [self gpslab_applyLocalization];
}

- (UILabel *)fieldLabelWithKey:(NSString *)key {
    return [self sectionHeaderLabel:GPSLabLocalized(key)];
}

- (UITextField *)plainFieldWithPlaceholder:(NSString *)placeholder text:(nullable NSString *)text {
    UITextField *field = [[UITextField alloc] initWithFrame:CGRectZero];
    field.placeholder = placeholder;
    field.text = text;
    field.borderStyle = UITextBorderStyleRoundedRect;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    return field;
}

- (void)buildForm {
    UIStackView *content = self.contentStack;
    self.noteLabel = [self bodyLabel:GPSLabLocalized(@"sim.note")];

    if (self.kind == GPSLabSimulationKindWiFi) {
        self.nameField = [self plainFieldWithPlaceholder:GPSLabLocalized(@"sim.wifi.profileName")
                                                    text:self.wifiConfig.profileName];
        self.ssidField = [self plainFieldWithPlaceholder:GPSLabLocalized(@"sim.wifi.ssid")
                                                    text:self.wifiConfig.ssid];
        self.wifiSignalSegment = [[UISegmentedControl alloc] initWithItems:@[@"", @"", @""]];
        self.wifiSignalSegment.selectedSegmentIndex =
            (self.wifiConfig.signal >= 75) ? 0 : ((self.wifiConfig.signal >= 45) ? 1 : 2);
        [content addArrangedSubview:[self fieldLabelWithKey:@"sim.wifi.profileName"]];
        [content addArrangedSubview:self.nameField];
        [content addArrangedSubview:[self fieldLabelWithKey:@"sim.wifi.ssid"]];
        [content addArrangedSubview:self.ssidField];
        [content addArrangedSubview:[self fieldLabelWithKey:@"sim.wifi.signal"]];
        [content addArrangedSubview:self.wifiSignalSegment];
    } else {
        self.nameField = [self plainFieldWithPlaceholder:GPSLabLocalized(@"sim.ble.profileName")
                                                    text:self.bluetoothConfig.profileName];
        self.deviceField = [self plainFieldWithPlaceholder:GPSLabLocalized(@"sim.ble.deviceName")
                                                      text:self.bluetoothConfig.deviceName];
        self.bleRSSISegment = [[UISegmentedControl alloc] initWithItems:@[@"-45 dBm", @"-60 dBm", @"-75 dBm"]];
        self.bleRSSISegment.selectedSegmentIndex =
            (self.bluetoothConfig.rssi >= -52) ? 0 : ((self.bluetoothConfig.rssi >= -67) ? 1 : 2);
        self.patternField = [self plainFieldWithPlaceholder:GPSLabLocalized(@"sim.ble.pattern")
                                                       text:self.bluetoothConfig.pattern];
        [content addArrangedSubview:[self fieldLabelWithKey:@"sim.ble.profileName"]];
        [content addArrangedSubview:self.nameField];
        [content addArrangedSubview:[self fieldLabelWithKey:@"sim.ble.deviceName"]];
        [content addArrangedSubview:self.deviceField];
        [content addArrangedSubview:[self fieldLabelWithKey:@"sim.ble.rssi"]];
        [content addArrangedSubview:self.bleRSSISegment];
        [content addArrangedSubview:[self fieldLabelWithKey:@"sim.ble.pattern"]];
        [content addArrangedSubview:self.patternField];
    }

    UIButton *save = [self actionButtonWithTitle:GPSLabLocalized(@"common.save")
                                          action:@selector(saveTapped)];
    [content addArrangedSubview:save];
    [content addArrangedSubview:self.noteLabel];
}

- (void)gpslab_applyLocalization {
    self.title = (self.kind == GPSLabSimulationKindWiFi)
        ? GPSLabLocalized(@"sim.wifi.title")
        : GPSLabLocalized(@"sim.ble.title");
    if (self.noteLabel != nil) {
        self.noteLabel.text = GPSLabLocalized(@"sim.note");
    }
    if (self.wifiSignalSegment != nil) {
        [self.wifiSignalSegment setTitle:GPSLabLocalized(@"sim.signal.strong") forSegmentAtIndex:0];
        [self.wifiSignalSegment setTitle:GPSLabLocalized(@"sim.signal.medium") forSegmentAtIndex:1];
        [self.wifiSignalSegment setTitle:GPSLabLocalized(@"sim.signal.weak") forSegmentAtIndex:2];
    }
}

- (NSInteger)signalValue {
    switch (self.wifiSignalSegment.selectedSegmentIndex) {
        case 0: return 90;
        case 1: return 60;
        default: return 30;
    }
}

- (NSInteger)rssiValue {
    switch (self.bleRSSISegment.selectedSegmentIndex) {
        case 0: return -45;
        case 1: return -60;
        default: return -75;
    }
}

- (void)saveTapped {
    if (self.kind == GPSLabSimulationKindWiFi) {
        GPSLabProfileWiFiConfig *candidate =
            [[GPSLabProfileWiFiConfig alloc] initWithProfileName:self.nameField.text ?: @""
                                                            ssid:self.ssidField.text ?: @""
                                                          signal:[self signalValue]];
        GPSLabProfileWiFiConfig *normalized =
            [[GPSLabSimulationRegistry wifiModule] normalizedConfig:candidate];
        if (normalized == nil) {
            [self showAlertWithTitle:GPSLabLocalized(@"sim.wifi.title")
                             message:GPSLabLocalized(@"sim.error.required")];
            return;
        }
        if (self.saveWiFiHandler == nil || !self.saveWiFiHandler(normalized)) {
            return; // keep the sheet open so the user's input is not lost
        }
    } else {
        GPSLabProfileBluetoothConfig *candidate =
            [[GPSLabProfileBluetoothConfig alloc] initWithProfileName:self.nameField.text ?: @""
                                                           deviceName:self.deviceField.text ?: @""
                                                                 rssi:[self rssiValue]
                                                              pattern:self.patternField.text ?: @""];
        GPSLabProfileBluetoothConfig *normalized =
            [[GPSLabSimulationRegistry bluetoothModule] normalizedConfig:candidate];
        if (normalized == nil) {
            [self showAlertWithTitle:GPSLabLocalized(@"sim.ble.title")
                             message:GPSLabLocalized(@"sim.error.required")];
            return;
        }
        if (self.saveBluetoothHandler == nil || !self.saveBluetoothHandler(normalized)) {
            return;
        }
    }
    [self gpslab_dismissSheet];
}

@end
