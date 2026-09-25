//
//  GPSLabSimulationSettingsViewController.h
//  GPSLab
//
//  Native editor for the Wi-Fi / Bluetooth *test* profiles. It only edits
//  synthetic, user-supplied strings; no hardware API is called.
//

#import "GPSLabSheetViewController.h"

#import "GPSLabProfile.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, GPSLabSimulationKind) {
    GPSLabSimulationKindWiFi = 0,
    GPSLabSimulationKindBluetooth,
    /** Enable/disable-only section: auto-saved on toggle, no Save button. */
    GPSLabSimulationKindVPN,
};

@interface GPSLabSimulationSettingsViewController : GPSLabSheetViewController

@property (nonatomic, assign) GPSLabSimulationKind kind;

@property (nonatomic, copy, nullable) GPSLabProfileWiFiConfig *wifiConfig;
@property (nonatomic, copy, nullable) GPSLabProfileBluetoothConfig *bluetoothConfig;

/** Return YES when persisted; the sheet dismisses only then. */
@property (nonatomic, copy, nullable) BOOL (^saveWiFiHandler)(GPSLabProfileWiFiConfig *config);
@property (nonatomic, copy, nullable) BOOL (^saveBluetoothHandler)(GPSLabProfileBluetoothConfig *config);

@end

NS_ASSUME_NONNULL_END
