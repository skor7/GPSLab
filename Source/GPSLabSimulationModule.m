//
//  GPSLabSimulationModule.m
//  GPSLab
//

#import "GPSLabSimulationModule.h"

@implementation GPSLabSimulationCapability

+ (instancetype)capabilityWithIdentifier:(NSString *)identifier
                            availability:(GPSLabSimulationAvailability)availability
                                titleKey:(NSString *)titleKey
                             reasonKey:(nullable NSString *)reasonKey {
    GPSLabSimulationCapability *capability = [[GPSLabSimulationCapability alloc] init];
    capability->_identifier = [identifier copy];
    capability->_availability = availability;
    capability->_localizedTitleKey = [titleKey copy];
    capability->_unavailableReasonKey = [reasonKey copy];
    return capability;
}

@end

@implementation GPSLabSimulationModuleResult

+ (instancetype)okResult {
    return [self resultWithCode:GPSLabSimulationResultOK messageKey:nil];
}

+ (instancetype)unsupportedResult {
    return [self resultWithCode:GPSLabSimulationResultUnsupported messageKey:nil];
}

+ (instancetype)invalidInputResultWithMessageKey:(nullable NSString *)messageKey {
    return [self resultWithCode:GPSLabSimulationResultInvalidInput messageKey:messageKey];
}

+ (instancetype)resultWithCode:(GPSLabSimulationResultCode)code
                    messageKey:(nullable NSString *)messageKey {
    GPSLabSimulationModuleResult *result = [[GPSLabSimulationModuleResult alloc] init];
    result->_code = code;
    result->_messageKey = [messageKey copy];
    return result;
}

@end
