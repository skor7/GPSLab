//
//  GPSLabMasterIntentGuard.m
//  GPSLab
//

#import "GPSLabMasterIntentGuard.h"

@implementation GPSLabMasterIntentGuard {
    NSUInteger _generation;
}

- (NSUInteger)beginIntent {
    _generation += 1;
    return _generation;
}

- (void)invalidateIntents {
    _generation += 1;
}

- (BOOL)isCurrentIntent:(NSUInteger)token {
    return token != 0 && token == _generation;
}

- (GPSLabMasterIntentResolution)resolveIntent:(NSUInteger)token
                                      applied:(BOOL)applied
                           switchWasChanged:(BOOL)switchWasChanged {
    if (![self isCurrentIntent:token]) {
        return GPSLabMasterIntentResolutionIgnoreStale;
    }
    if (applied) {
        return GPSLabMasterIntentResolutionApplied;
    }
    return switchWasChanged ? GPSLabMasterIntentResolutionRollback
                            : GPSLabMasterIntentResolutionFailureNoChange;
}

@end
