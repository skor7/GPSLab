//
//  GPSLabBluetoothSimulationModule.m
//  GPSLab
//

#import "GPSLabBluetoothSimulationModule.h"

@implementation GPSLabBluetoothSimulationModule

- (NSString *)moduleIdentifier {
    return @"com.gpslab.simulation.bluetooth";
}

- (GPSLabSimulationCapability *)capability {
    return [GPSLabSimulationCapability capabilityWithIdentifier:self.moduleIdentifier
                                                  availability:GPSLabSimulationAvailabilityAvailable
                                                      titleKey:@"sim.ble.title"
                                                   reasonKey:nil];
}

- (GPSLabSimulationModuleResult *)validateConfig:(GPSLabProfileBluetoothConfig *)config {
    if (config == nil) {
        return [GPSLabSimulationModuleResult invalidInputResultWithMessageKey:@"sim.error.required"];
    }
    NSString *profileName = [config.profileName stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *deviceName = [config.deviceName stringByTrimmingCharactersInSet:
                            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (profileName.length == 0 || deviceName.length == 0) {
        return [GPSLabSimulationModuleResult invalidInputResultWithMessageKey:@"sim.error.required"];
    }
    if (!GPSLabProfileRSSIValid((int)config.rssi)) {
        return [GPSLabSimulationModuleResult invalidInputResultWithMessageKey:@"sim.error.rssi"];
    }
    return [GPSLabSimulationModuleResult okResult];
}

- (nullable GPSLabProfileBluetoothConfig *)normalizedConfig:(GPSLabProfileBluetoothConfig *)config {
    GPSLabSimulationModuleResult *result = [self validateConfig:config];
    if (result.code != GPSLabSimulationResultOK) {
        return nil;
    }
    NSString *profileName = [config.profileName stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *deviceName = [config.deviceName stringByTrimmingCharactersInSet:
                            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *pattern = [config.pattern stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [[GPSLabProfileBluetoothConfig alloc] initWithProfileName:profileName
                                                         deviceName:deviceName
                                                               rssi:config.rssi
                                                            pattern:pattern];
}

@end
