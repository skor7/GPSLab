//
//  GPSLabSchedulerDefaultHost.m
//  GPSLab
//

#import "GPSLabSchedulerDefaultHost.h"

#import <UIKit/UIKit.h>

#import "GPSLabEngine.h"
#import "GPSLabLicenseManager.h"
#import "GPSLabProfileApplicationCoordinator.h"
#import "GPSLabSchedulerCore.h"

@implementation GPSLabSchedulerDefaultHost {
    dispatch_source_t _timer;
    NSUInteger _hostGeneration;
}

- (long long)schedulerNowSeconds {
    return (long long)[[NSDate date] timeIntervalSince1970];
}

- (BOOL)schedulerIsForeground {
    return UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
}

- (void)schedulerScheduleTimerAfterSeconds:(long long)seconds generation:(NSUInteger)generation {
    [self schedulerCancelTimer];
    long long bounded = seconds;
    if (bounded < 0) {
        bounded = 0;
    }
    if (bounded > GPSLAB_SCHEDULER_MAX_WAIT_SECONDS) {
        bounded = GPSLAB_SCHEDULER_MAX_WAIT_SECONDS;
    }
    _hostGeneration = generation;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                     dispatch_get_main_queue());
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, (uint64_t)bounded * NSEC_PER_SEC),
                              DISPATCH_TIME_FOREVER,
                              1 * NSEC_PER_SEC);
    GPSLabSchedulerDefaultHost *__weak weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        GPSLabSchedulerDefaultHost *strongSelf = weakSelf;
        if (strongSelf == nil || generation != strongSelf->_hostGeneration) {
            return; // a newer timer replaced this one
        }
        [strongSelf.scheduler handleTimerGeneration:generation];
    });
    _timer = timer;
    dispatch_resume(timer);
}

- (void)schedulerCancelTimer {
    if (_timer != nil) {
        dispatch_source_cancel(_timer);
        _timer = nil;
    }
    _hostGeneration = 0;
}

- (void)schedulerApplyProfile:(GPSLabProfile *)profile completion:(void (^)(BOOL applied))completion {
    [[GPSLabProfileApplicationCoordinator sharedCoordinator] applyProfile:profile
                                                               completion:^(GPSLabProfileApplicationResult *result) {
        if (completion != nil) {
            completion(result.applied);
        }
    }];
}

- (BOOL)schedulerIsEngineEnabled {
    return [GPSLabEngine sharedEngine].isEnabled;
}

- (BOOL)schedulerIsLicenseUnlocked {
    return [[GPSLabLicenseManager sharedManager] isUnlocked];
}

- (BOOL)schedulerOwnsProfileIdentifier:(NSString *)identifier {
    return [[[GPSLabProfileApplicationCoordinator sharedCoordinator] appliedProfileIdentifier]
        isEqualToString:identifier];
}

- (void)schedulerStopOwnedProfileIdentifier:(NSString *)identifier {
    GPSLabProfileApplicationCoordinator *coordinator = [GPSLabProfileApplicationCoordinator sharedCoordinator];
    if (![[coordinator appliedProfileIdentifier] isEqualToString:identifier]) {
        return; // ownership changed: never stop a user's manual route
    }
    [[GPSLabEngine sharedEngine] stopRoute];
    [[GPSLabEngine sharedEngine] setEnabledAndNotify:NO];
    [coordinator invalidateAppliedProfile];
}

- (void)schedulerInvalidateOwnedProfile {
    [[GPSLabProfileApplicationCoordinator sharedCoordinator] invalidateAppliedProfile];
}

- (void)schedulerCancelPendingApplication {
    [[GPSLabProfileApplicationCoordinator sharedCoordinator] cancelPendingApplication];
}

- (void)schedulerStartObserving {
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self
               selector:@selector(engineStateDidChange:)
                   name:GPSLabEngineStateDidChangeNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(licenseStateDidChange:)
                   name:GPSLabLicenseStateDidChangeNotification
                 object:nil];
}

- (void)engineStateDidChange:(NSNotification *)notification {
    (void)notification;
    [self.scheduler noteEngineStateChanged];
}

- (void)licenseStateDidChange:(NSNotification *)notification {
    (void)notification;
    [self.scheduler noteLicenseStateChanged];
}

@end
