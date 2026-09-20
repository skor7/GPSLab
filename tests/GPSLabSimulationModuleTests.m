//
//  GPSLabSimulationModuleTests.m
//  GPSLab
//
//  Foundation tests for the Wi-Fi / Bluetooth *test* modules: capability
//  descriptors, validation bounds and normalization. No hardware API exists in
//  these modules, so the tests assert config-only behaviour and typed results.
//
//  Build/run (macOS):
//    clang -fobjc-arc -fmodules -framework Foundation -framework CoreLocation \
//      -ISource tests/GPSLabSimulationModuleTests.m Source/GPSLabSimulationModule.m \
//      Source/GPSLabWiFiSimulationModule.m Source/GPSLabBluetoothSimulationModule.m \
//      Source/GPSLabSimulationRegistry.m Source/GPSLabProfile.m Source/GPSLabProfileCore.c \
//      -o /tmp/gpslab-simulation-tests
//    /tmp/gpslab-simulation-tests
//

#import <Foundation/Foundation.h>

#import "GPSLabSimulationRegistry.h"

static int gFailures = 0;
static int gChecks = 0;

#define CHECK(condition, message)                                  \
    do {                                                           \
        gChecks++;                                                 \
        if (!(condition)) {                                        \
            gFailures++;                                           \
            fprintf(stderr, "FAIL: %s\n", [(message) UTF8String]); \
        }                                                          \
    } while (0)

static void test_capabilities(void) {
    NSArray<GPSLabSimulationCapability *> *capabilities = [GPSLabSimulationRegistry capabilities];
    CHECK(capabilities.count == 2, @"two simulation capabilities registered");
    CHECK([capabilities[0].identifier isEqualToString:@"com.gpslab.simulation.wifi"],
          @"wifi capability identifier");
    CHECK([capabilities[1].identifier isEqualToString:@"com.gpslab.simulation.bluetooth"],
          @"bluetooth capability identifier");
    for (GPSLabSimulationCapability *capability in capabilities) {
        CHECK(capability.availability == GPSLabSimulationAvailabilityAvailable,
              @"config-only modules are available");
        CHECK(capability.localizedTitleKey.length > 0, @"capability has a title key");
    }
}

static void test_wifi_validation(void) {
    GPSLabWiFiSimulationModule *module = [GPSLabSimulationRegistry wifiModule];
    GPSLabProfileWiFiConfig *valid = [[GPSLabProfileWiFiConfig alloc] initWithProfileName:@"Home net"
                                                                                    ssid:@"GPSLab-Test"
                                                                                  signal:80];
    CHECK([module validateConfig:valid].code == GPSLabSimulationResultOK, @"valid wifi accepted");

    GPSLabProfileWiFiConfig *emptyName = [[GPSLabProfileWiFiConfig alloc] initWithProfileName:@"  "
                                                                                        ssid:@"x"
                                                                                      signal:80];
    CHECK([module validateConfig:emptyName].code == GPSLabSimulationResultInvalidInput,
          @"blank wifi profile name rejected");

    GPSLabProfileWiFiConfig *badSignal = [[GPSLabProfileWiFiConfig alloc] initWithProfileName:@"a"
                                                                                        ssid:@"b"
                                                                                      signal:500];
    CHECK([module validateConfig:badSignal].code == GPSLabSimulationResultInvalidInput,
          @"out-of-range signal rejected");

    CHECK([module validateConfig:nil].code == GPSLabSimulationResultInvalidInput,
          @"nil wifi config rejected");

    GPSLabProfileWiFiConfig *normalized = [module normalizedConfig:valid];
    CHECK(normalized != nil, @"valid wifi normalizes");
    CHECK([normalized.profileName isEqualToString:@"Home net"], @"normalized name preserved");
    CHECK([module normalizedConfig:badSignal] == nil, @"invalid wifi normalizes to nil");
}

static void test_bluetooth_validation(void) {
    GPSLabBluetoothSimulationModule *module = [GPSLabSimulationRegistry bluetoothModule];
    GPSLabProfileBluetoothConfig *valid =
        [[GPSLabProfileBluetoothConfig alloc] initWithProfileName:@"BLE test"
                                                       deviceName:@"GPSLab BLE"
                                                             rssi:-60
                                                          pattern:@"public"];
    CHECK([module validateConfig:valid].code == GPSLabSimulationResultOK, @"valid ble accepted");

    GPSLabProfileBluetoothConfig *badRSSI =
        [[GPSLabProfileBluetoothConfig alloc] initWithProfileName:@"a"
                                                       deviceName:@"b"
                                                             rssi:10
                                                          pattern:@"c"];
    CHECK([module validateConfig:badRSSI].code == GPSLabSimulationResultInvalidInput,
          @"positive rssi rejected");

    GPSLabProfileBluetoothConfig *emptyDevice =
        [[GPSLabProfileBluetoothConfig alloc] initWithProfileName:@"a"
                                                       deviceName:@"   "
                                                             rssi:-60
                                                          pattern:@"c"];
    CHECK([module validateConfig:emptyDevice].code == GPSLabSimulationResultInvalidInput,
          @"blank device name rejected");

    CHECK([module validateConfig:nil].code == GPSLabSimulationResultInvalidInput,
          @"nil ble config rejected");

    GPSLabProfileBluetoothConfig *normalized = [module normalizedConfig:valid];
    CHECK(normalized != nil, @"valid ble normalizes");
    CHECK([normalized.pattern isEqualToString:@"public"], @"pattern metadata preserved");
}

int main(void) {
    @autoreleasepool {
        test_capabilities();
        test_wifi_validation();
        test_bluetooth_validation();
    }

    if (gFailures == 0) {
        printf("GPSLabSimulationModuleTests: %d checks passed\n", gChecks);
        return 0;
    }
    fprintf(stderr, "GPSLabSimulationModuleTests: %d/%d checks failed\n", gFailures, gChecks);
    return 1;
}
