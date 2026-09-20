//
//  GPSLabWiFiSimulationModule.h
//  GPSLab
//
//  Wi-Fi *test profile* config. No Wi-Fi hardware API, scan, association or
//  host network change is ever performed; only user-supplied synthetic strings
//  are validated and normalized.
//

#import "GPSLabSimulationModule.h"

NS_ASSUME_NONNULL_BEGIN

@interface GPSLabWiFiSimulationModule : NSObject <GPSLabSimulationModule>

/** Validates a candidate test config (nil is invalid, not a crash). Never touches hardware. */
- (GPSLabSimulationModuleResult *)validateConfig:(nullable GPSLabProfileWiFiConfig *)config;

/** Returns a trimmed, bounded copy, or nil when the input is invalid/nil. */
- (nullable GPSLabProfileWiFiConfig *)normalizedConfig:(nullable GPSLabProfileWiFiConfig *)config;

@end

NS_ASSUME_NONNULL_END
