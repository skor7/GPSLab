//
//  GPSLabSimulationModule.h
//  GPSLab
//
//  Independent GPSLab simulation/test modules. These modules model *test
//  settings* only: they never scan, pair, advertise, read or mutate any real
//  Wi-Fi/Bluetooth hardware, host network, identity or private API. They only
//  validate and normalize user-supplied synthetic strings and update the
//  in-memory GPSLab config.
//
//  An unavailable capability returns a typed `Unsupported` result and the UI
//  states the limitation; nothing is faked and nothing crashes.
//

#import <Foundation/Foundation.h>

#import "GPSLabProfile.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, GPSLabSimulationAvailability) {
    GPSLabSimulationAvailabilityAvailable = 0,
    GPSLabSimulationAvailabilityUnavailable,
    GPSLabSimulationAvailabilityUnsupported,
};

typedef NS_ENUM(NSInteger, GPSLabSimulationResultCode) {
    GPSLabSimulationResultOK = 0,
    GPSLabSimulationResultUnsupported,
    GPSLabSimulationResultInvalidInput,
};

/** A module's capability descriptor (localized through catalog keys). */
@interface GPSLabSimulationCapability : NSObject

@property (nonatomic, readonly, copy) NSString *identifier;
@property (nonatomic, readonly) GPSLabSimulationAvailability availability;
@property (nonatomic, readonly, copy) NSString *localizedTitleKey;
@property (nonatomic, readonly, copy, nullable) NSString *unavailableReasonKey;

+ (instancetype)capabilityWithIdentifier:(NSString *)identifier
                            availability:(GPSLabSimulationAvailability)availability
                                titleKey:(NSString *)titleKey
                             reasonKey:(nullable NSString *)reasonKey;

@end

/** Typed, harmless outcome of a validation/normalization attempt. */
@interface GPSLabSimulationModuleResult : NSObject

@property (nonatomic, readonly) GPSLabSimulationResultCode code;
@property (nonatomic, readonly, copy, nullable) NSString *messageKey;

+ (instancetype)okResult;
+ (instancetype)unsupportedResult;
+ (instancetype)invalidInputResultWithMessageKey:(nullable NSString *)messageKey;

@end

@protocol GPSLabSimulationModule <NSObject>

@property (nonatomic, readonly, copy) NSString *moduleIdentifier;
@property (nonatomic, readonly, strong) GPSLabSimulationCapability *capability;

@end

NS_ASSUME_NONNULL_END
