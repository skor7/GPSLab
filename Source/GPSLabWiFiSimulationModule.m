//
//  GPSLabWiFiSimulationModule.m
//  GPSLab
//

#import "GPSLabWiFiSimulationModule.h"

@implementation GPSLabWiFiSimulationModule

- (NSString *)moduleIdentifier {
    return @"com.gpslab.simulation.wifi";
}

- (GPSLabSimulationCapability *)capability {
    // The module is a pure config: no hardware capability is required, so it is
    // always available and clearly labelled as a test setting in the UI.
    return [GPSLabSimulationCapability capabilityWithIdentifier:self.moduleIdentifier
                                                  availability:GPSLabSimulationAvailabilityAvailable
                                                      titleKey:@"sim.wifi.title"
                                                   reasonKey:nil];
}

- (GPSLabSimulationModuleResult *)validateConfig:(GPSLabProfileWiFiConfig *)config {
    if (config == nil) {
        return [GPSLabSimulationModuleResult invalidInputResultWithMessageKey:@"sim.error.required"];
    }
    NSString *profileName = [config.profileName stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *ssid = [config.ssid stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (profileName.length == 0 || ssid.length == 0) {
        return [GPSLabSimulationModuleResult invalidInputResultWithMessageKey:@"sim.error.required"];
    }
    if (!GPSLabProfileSignalValid((int)config.signal)) {
        return [GPSLabSimulationModuleResult invalidInputResultWithMessageKey:@"sim.error.signal"];
    }
    return [GPSLabSimulationModuleResult okResult];
}

- (nullable GPSLabProfileWiFiConfig *)normalizedConfig:(GPSLabProfileWiFiConfig *)config {
    GPSLabSimulationModuleResult *result = [self validateConfig:config];
    if (result.code != GPSLabSimulationResultOK) {
        return nil;
    }
    NSString *profileName = [config.profileName stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *ssid = [config.ssid stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [[GPSLabProfileWiFiConfig alloc] initWithProfileName:profileName
                                                           ssid:ssid
                                                         signal:config.signal];
}

@end
