//
//  GPSLabScheduler.m
//  GPSLab
//

#import "GPSLabScheduler.h"

#import "GPSLabProfileCore.h"
#import "GPSLabSchedulerCore.h"

/** Back-reference protocol the production host implements (avoids importing it). */
@protocol GPSLabSchedulerHostBackreference <NSObject>
- (void)setScheduler:(GPSLabScheduler *)scheduler;
@end

#pragma mark - Scheduler

@implementation GPSLabScheduler {
    id<GPSLabSchedulerHost> _host;
    GPSLabProfile *_scheduledProfile;
    NSString *_ownedProfileIdentifier;
    BOOL _manuallyDisabled;
    BOOL _fired;
    BOOL _observing;
    NSUInteger _timerGeneration;
    NSUInteger _fireToken;
}

+ (instancetype)sharedScheduler {
    static GPSLabScheduler *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[GPSLabScheduler alloc] init];
    });
    return instance;
}

- (instancetype)init {
    Class hostClass = NSClassFromString(@"GPSLabSchedulerDefaultHost");
    id<GPSLabSchedulerHost> host = hostClass != Nil ? [[hostClass alloc] init] : nil;
    self = [self initWithHost:host];
    if (self && host != nil) {
        // The production host needs a back-reference to call back on a wake.
        id<GPSLabSchedulerHostBackreference> backreference =
            (id<GPSLabSchedulerHostBackreference>)host;
        [backreference setScheduler:self];
    }
    return self;
}

- (instancetype)initWithHost:(id<GPSLabSchedulerHost>)host {
    self = [super init];
    if (self) {
        _host = host;
        _timerGeneration = 0;
    }
    return self;
}

- (NSString *)ownedProfileIdentifier {
    return _ownedProfileIdentifier;
}

- (BOOL)isFired {
    return _fired;
}

#pragma mark - Observing

- (void)startObserving {
    if (_observing) {
        return;
    }
    _observing = YES;
    // ALL platform/engine/license observation lives in the injected host, so this
    // Foundation-only core has no UIKit or engine/license dependency.
    [_host schedulerStartObserving];
}

- (void)noteForegroundChanged {
    [self evaluate];
}

- (void)noteEngineStateChanged {
    [self evaluate];
}

- (void)noteLicenseStateChanged {
    [self evaluate];
}

#pragma mark - Arming

- (void)armWithProfile:(nullable GPSLabProfile *)profile {
    [self cancelTimer];
    _fireToken += 1; // invalidate any in-flight fire completion
    _ownedProfileIdentifier = nil;
    _fired = NO;

    if (profile == nil || profile.schedule == nil) {
        _scheduledProfile = nil;
        return;
    }
    // An EXPLICIT user apply clears the manual-disable latch. Automatic license
    // or foreground re-evaluations never do.
    _manuallyDisabled = NO;
    _scheduledProfile = profile;
    [self evaluate];
}

- (void)cancelPending {
    [self cancelTimer];
    _fireToken += 1; // invalidate any in-flight fire completion
    _scheduledProfile = nil;
    _ownedProfileIdentifier = nil;
    _fired = NO;
}

- (void)noteManualEngineDisable {
    _manuallyDisabled = YES;
    [self cancelPending];
    // Invalidate the scheduler's owned state and any pending application,
    // including an asynchronous route preparation.
    [_host schedulerInvalidateOwnedProfile];
    [_host schedulerCancelPendingApplication];
}

#pragma mark - Evaluation

- (void)evaluate {
    GPSLabProfile *profile = _scheduledProfile;
    if (profile == nil || profile.schedule == nil) {
        [self cancelTimer];
        return;
    }

    GPSLabSchedulerState state;
    state.mode = (int)profile.schedule.mode;
    state.startEpoch = profile.schedule.startEpoch;
    state.endEpoch = profile.schedule.endEpoch;
    state.now = [_host schedulerNowSeconds];
    state.fired = _fired ? 1 : 0;
    state.foreground = [_host schedulerIsForeground] ? 1 : 0;
    state.engineEnabled = [_host schedulerIsEngineEnabled] ? 1 : 0;
    state.licenseUnlocked = [_host schedulerIsLicenseUnlocked] ? 1 : 0;
    state.manuallyDisabled = _manuallyDisabled ? 1 : 0;
    state.ownerValid = [self ownerIsValid] ? 1 : 0;

    long long delay = 0;
    switch (GPSLabSchedulerNextAction(state, &delay)) {
        case GPSLabSchedulerActionNone:
            [self cancelTimer];
            break;
        case GPSLabSchedulerActionWait:
            [self scheduleWaitSeconds:delay];
            break;
        case GPSLabSchedulerActionFire:
            [self performFire];
            break;
        case GPSLabSchedulerActionWindowEnd:
            [self performWindowEnd];
            break;
        case GPSLabSchedulerActionCancel:
            [self cancelPending];
            break;
    }
}

- (BOOL)ownerIsValid {
    return _ownedProfileIdentifier != nil &&
           [_host schedulerOwnsProfileIdentifier:_ownedProfileIdentifier];
}

- (void)performFire {
    GPSLabProfile *profile = _scheduledProfile;
    if (profile == nil || _fired) {
        return;
    }
    // Re-check the gate at the moment of firing.
    if (![_host schedulerIsForeground] || _manuallyDisabled ||
        ![_host schedulerIsEngineEnabled] || ![_host schedulerIsLicenseUnlocked]) {
        [self evaluate];
        return;
    }

    _fired = YES;
    _fireToken += 1;
    NSUInteger token = _fireToken;
    _ownedProfileIdentifier = profile.identifier;
    GPSLabScheduler *__weak weakSelf = self;
    [_host schedulerApplyProfile:profile completion:^(BOOL applied) {
        // The apply may be asynchronous (a route). Ownership is only real once
        // the host/coordinator reports it, so re-evaluate AFTER the result so
        // the true window end is armed on success (and cleaned on failure).
        void (^resume)(void) = ^{
            GPSLabScheduler *strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }
            // A newer arm or a disable supersedes this completion: never rearm or
            // cancel the newer schedule from a stale callback.
            if (token != strongSelf->_fireToken) {
                return;
            }
            if (!applied && [strongSelf->_ownedProfileIdentifier isEqualToString:profile.identifier]) {
                strongSelf->_ownedProfileIdentifier = nil;
            }
            [strongSelf evaluate];
        };
        if ([NSThread isMainThread]) {
            resume();
        } else {
            dispatch_async(dispatch_get_main_queue(), resume);
        }
    }];
    [self evaluate]; // idempotent; arms the end immediately for synchronous applies
}

- (void)performWindowEnd {
    NSString *owned = _ownedProfileIdentifier;
    _ownedProfileIdentifier = nil;
    if (owned == nil) {
        return;
    }
    // Ownership token: stop only GPSLab's own scheduled profile. A user's manual
    // profile (ownership invalidated) is never stopped.
    if (![_host schedulerOwnsProfileIdentifier:owned]) {
        return;
    }
    [_host schedulerStopOwnedProfileIdentifier:owned];
    _scheduledProfile = nil;
    [self cancelTimer];
}

#pragma mark - Timer

- (void)scheduleWaitSeconds:(long long)seconds {
    _timerGeneration += 1;
    [_host schedulerScheduleTimerAfterSeconds:seconds generation:_timerGeneration];
}

- (void)cancelTimer {
    _timerGeneration += 1;
    [_host schedulerCancelTimer];
}

- (void)handleTimerGeneration:(NSUInteger)generation {
    if (generation != _timerGeneration) {
        return; // stale wake from a replaced timer
    }
    [self cancelTimer];
    [self evaluate];
}

@end
