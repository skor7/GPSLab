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
@property (nonatomic, strong) UISwitch *simulationSwitch;
@property (nonatomic, strong) UILabel *simulationStateLabel;
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

- (NSString *)simulationTitleKey {
    switch (self.kind) {
        case GPSLabSimulationKindWiFi: return @"sim.wifi.title";
        case GPSLabSimulationKindBluetooth: return @"sim.ble.title";
        case GPSLabSimulationKindVPN: return @"sim.vpn.title";
    }
    return @"sim.title";
}

- (NSString *)simulationNoteKey {
    return (self.kind == GPSLabSimulationKindVPN) ? @"sim.vpn.note" : @"sim.note";
}

- (BOOL)simulationEnabledForCurrentKind {
    switch (self.kind) {
        case GPSLabSimulationKindWiFi: return [GPSLabSimulationRegistry isWiFiEnabled];
        case GPSLabSimulationKindBluetooth: return [GPSLabSimulationRegistry isBluetoothEnabled];
        case GPSLabSimulationKindVPN: return [GPSLabSimulationRegistry isVPNEnabled];
    }
    return NO;
}

- (UIView *)simulationControlRow {
    UIView *row = [[UIView alloc] initWithFrame:CGRectZero];
    self.simulationSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
    self.simulationSwitch.on = [self simulationEnabledForCurrentKind];
    [self.simulationSwitch addTarget:self
                              action:@selector(simulationSwitchChanged)
                    forControlEvents:UIControlEventValueChanged];

    self.simulationStateLabel = [self bodyLabel:@""];
    self.simulationStateLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.simulationSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:self.simulationStateLabel];
    [row addSubview:self.simulationSwitch];
    [NSLayoutConstraint activateConstraints:@[
        [self.simulationStateLabel.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [self.simulationStateLabel.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [self.simulationSwitch.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [self.simulationSwitch.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.simulationStateLabel.trailingAnchor constant:12.0],
        [self.simulationSwitch.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [row.heightAnchor constraintGreaterThanOrEqualToConstant:44.0],
    ]];
    [self updateSimulationStateLabel];
    return row;
}

- (void)simulationSwitchChanged {
    // VPN is the enable/disable-only section: it auto-saves and refreshes the
    // runtime hook immediately (no Save). Wi-Fi/Bluetooth persist on Save.
    if (self.kind == GPSLabSimulationKindVPN) {
        [GPSLabSimulationRegistry setVPNEnabled:self.simulationSwitch.on];
    }
    [self updateSimulationStateLabel];
}

- (void)updateSimulationStateLabel {
    NSString *state = GPSLabLocalized(self.simulationSwitch.on ? @"profiles.value.on" : @"profiles.value.off");
    NSString *title = GPSLabLocalized([self simulationTitleKey]);
    self.simulationStateLabel.text = [NSString stringWithFormat:@"%@ — %@", title, state];
}

- (void)buildForm {
    UIStackView *content = self.contentStack;
    self.noteLabel = [self bodyLabel:GPSLabLocalized([self simulationNoteKey])];

    [content addArrangedSubview:[self simulationControlRow]];

    if (self.kind == GPSLabSimulationKindWiFi) {
        self.nameField = [self plainFieldWithPlaceholder:GPSLabLocalized(@"sim.wifi.profileName")
                                                    text:self.wifiConfig.profileName];
        self.ssidField = [self plainFieldWithPlaceholder:GPSLabLocalized(@"sim.wifi.ssid")
                                                    text:self.wifiConfig.ssid];
        self.wifiSignalSegment = [[UISegmentedControl alloc] initWithItems:@[@"", @"", @""]];
        NSInteger signal = self.wifiConfig != nil ? self.wifiConfig.signal : 90;
        self.wifiSignalSegment.selectedSegmentIndex =
            (signal >= 75) ? 0 : ((signal >= 45) ? 1 : 2);
        [content addArrangedSubview:[self fieldLabelWithKey:@"sim.wifi.profileName"]];
        [content addArrangedSubview:self.nameField];
        [content addArrangedSubview:[self fieldLabelWithKey:@"sim.wifi.ssid"]];
        [content addArrangedSubview:self.ssidField];
        [content addArrangedSubview:[self fieldLabelWithKey:@"sim.wifi.signal"]];
        [content addArrangedSubview:self.wifiSignalSegment];
    } else if (self.kind == GPSLabSimulationKindBluetooth) {
        self.nameField = [self plainFieldWithPlaceholder:GPSLabLocalized(@"sim.ble.profileName")
                                                    text:self.bluetoothConfig.profileName];
        self.deviceField = [self plainFieldWithPlaceholder:GPSLabLocalized(@"sim.ble.deviceName")
                                                      text:self.bluetoothConfig.deviceName];
        self.bleRSSISegment = [[UISegmentedControl alloc] initWithItems:@[@"-45 dBm", @"-60 dBm", @"-75 dBm"]];
        NSInteger rssi = self.bluetoothConfig != nil ? self.bluetoothConfig.rssi : -60;
        self.bleRSSISegment.selectedSegmentIndex =
            (rssi >= -52) ? 0 : ((rssi >= -67) ? 1 : 2);
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
    // VPN has no config fields: the toggle auto-saves, so no Save button is shown.

    if (self.kind != GPSLabSimulationKindVPN) {
        UIButton *save = [self actionButtonWithTitle:GPSLabLocalized(@"common.save")
                                              action:@selector(saveTapped)];
        [content addArrangedSubview:save];
    }
    [content addArrangedSubview:self.noteLabel];
}

- (void)gpslab_applyLocalization {
    self.title = GPSLabLocalized([self simulationTitleKey]);
    if (self.noteLabel != nil) {
        self.noteLabel.text = GPSLabLocalized([self simulationNoteKey]);
    }
    if (self.wifiSignalSegment != nil) {
        [self.wifiSignalSegment setTitle:GPSLabLocalized(@"sim.signal.strong") forSegmentAtIndex:0];
        [self.wifiSignalSegment setTitle:GPSLabLocalized(@"sim.signal.medium") forSegmentAtIndex:1];
        [self.wifiSignalSegment setTitle:GPSLabLocalized(@"sim.signal.weak") forSegmentAtIndex:2];
    }
    [self updateSimulationStateLabel];
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
    if (self.kind == GPSLabSimulationKindVPN) {
        // No Save button is shown for VPN, but keep the action safe if reached.
        [GPSLabSimulationRegistry setVPNEnabled:self.simulationSwitch.on];
        [self gpslab_dismissSheet];
        return;
    }
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
            return;
        }
        [GPSLabSimulationRegistry setWiFiEnabled:self.simulationSwitch.on];
        [GPSLabSimulationRegistry activateWiFiConfig:normalized];
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
        [GPSLabSimulationRegistry setBluetoothEnabled:self.simulationSwitch.on];
        [GPSLabSimulationRegistry activateBluetoothConfig:normalized];
    }
    [self gpslab_dismissSheet];
}

@end
