//
//  LocationStream.m
//  GPSLab
//
//  Per-manager synthetic location streams with intent tracking.
//

#import "LocationStream.h"

#import <objc/runtime.h>

#import "GPSLabEngine.h"
#import "GPSLabStore.h"

// Standard updates are delivered every second; significant-change updates are
// intentionally much slower (real significant-change monitoring is throttled by
// distance/time, so 30 seconds is a reasonable synthetic stand-in).
static const double kGPSLabStandardIntervalSeconds = 1.0;
static const double kGPSLabSignificantIntervalSeconds = 30.0;

static char kGPSLabManagerStateKey;
static void *kGPSLabRegistryQueueKey = &kGPSLabRegistryQueueKey;

// Created suspended; the caller resumes it once configured.
static dispatch_source_t GPSLabCreateTimer(double intervalSeconds, dispatch_block_t handler);

@interface GPSLabLocationStream ()
+ (void)deliverUpdateToManager:(CLLocationManager *)manager;
@end

#pragma mark - Per-manager state

@interface GPSLabManagerState : NSObject

@property (nonatomic, weak, nullable) CLLocationManager *manager;

// Intent: what the host asked for. Survives suspend/background/disable.
@property (atomic, assign) BOOL standardRequested;
@property (atomic, assign) BOOL significantRequested;

// Running: whether a synthetic timer is currently installed.
@property (atomic, assign) BOOL standardRunning;
@property (atomic, assign) BOOL significantRunning;

@property (nonatomic, strong, nullable) dispatch_source_t standardTimer;
@property (nonatomic, strong, nullable) dispatch_source_t significantTimer;

- (void)cancelStandardTimer;
- (void)cancelSignificantTimer;
- (void)deliverStandardLocationUpdate;
- (void)deliverSignificantLocationUpdate;

@end

@implementation GPSLabManagerState

- (void)cancelStandardTimer {
    if (self.standardTimer != nil) {
        dispatch_source_cancel(self.standardTimer);
        self.standardTimer = nil;
    }
    self.standardRunning = NO;
}

- (void)cancelSignificantTimer {
    if (self.significantTimer != nil) {
        dispatch_source_cancel(self.significantTimer);
        self.significantTimer = nil;
    }
    self.significantRunning = NO;
}

// ARC-managed cleanup: a dispatch source must be cancelled before its last
// reference is released. When the weak-keyed registry drops this state because
// its manager was deallocated, cancel both timers here.
- (void)dealloc {
    dispatch_source_t standardTimer = _standardTimer;
    if (standardTimer != nil) {
        dispatch_source_cancel(standardTimer);
        _standardTimer = nil;
    }
    dispatch_source_t significantTimer = _significantTimer;
    if (significantTimer != nil) {
        dispatch_source_cancel(significantTimer);
        _significantTimer = nil;
    }
}

- (void)deliverStandardLocationUpdate {
    if (!self.standardRunning) {
        return;
    }
    CLLocationManager *manager = self.manager;
    if (manager == nil) {
        return;
    }
    [GPSLabLocationStream deliverUpdateToManager:manager];
}

- (void)deliverSignificantLocationUpdate {
    if (!self.significantRunning) {
        return;
    }
    CLLocationManager *manager = self.manager;
    if (manager == nil) {
        return;
    }
    [GPSLabLocationStream deliverUpdateToManager:manager];
}

@end

#pragma mark - Stream registry

@implementation GPSLabLocationStream {
    NSMapTable<CLLocationManager *, GPSLabManagerState *> *_states;
    dispatch_queue_t _registryQueue;
}

+ (instancetype)sharedStream {
    static GPSLabLocationStream *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[GPSLabLocationStream alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _states = [NSMapTable weakToStrongObjectsMapTable];
        _registryQueue = dispatch_queue_create("com.gpslab.runtime.stream", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(_registryQueue,
                                    kGPSLabRegistryQueueKey,
                                    kGPSLabRegistryQueueKey,
                                    NULL);
    }
    return self;
}

#pragma mark - Synthetic control

- (void)requestStandardForManager:(CLLocationManager *)manager {
    if (manager == nil) {
        return;
    }
    if ([GPSLabCoreLocationHooks isBypassedManager:manager]) {
        return;
    }

    // The intent is recorded even while the engine is disabled: the hook layer is
    // still forwarding the call to the original implementation, and the request must
    // survive until the engine (or the app) becomes active again.
    BOOL enabled = [[GPSLabEngine sharedEngine] isEnabled];

    __block GPSLabManagerState *state = nil;
    __block BOOL started = NO;

    CLLocationManager *managerForLock = manager;
    [self performLocked:^{
        GPSLabManagerState *existing = [self stateLockedForManager:managerForLock create:YES];
        state = existing;
        existing.standardRequested = YES;
        if (!enabled || existing.standardRunning) {
            return;
        }
        if ([self startStandardTimerLocked:existing]) {
            started = YES;
        }
    }];

    if (started) {
        GPSLabManagerState *capturedState = state;
        dispatch_async(dispatch_get_main_queue(), ^{
            [capturedState deliverStandardLocationUpdate];
        });
    }
}

- (void)cancelStandardForManager:(CLLocationManager *)manager {
    if (manager == nil) {
        return;
    }
    CLLocationManager *managerForLock = manager;
    [self performLocked:^{
        GPSLabManagerState *state = [self stateLockedForManager:managerForLock create:NO];
        if (state == nil) {
            return;
        }
        state.standardRequested = NO;
        [state cancelStandardTimer];
        [self pruneStateLocked:state forManager:managerForLock];
    }];
}

- (void)requestSignificantForManager:(CLLocationManager *)manager {
    if (manager == nil) {
        return;
    }
    if ([GPSLabCoreLocationHooks isBypassedManager:manager]) {
        return;
    }

    // Intent survives a disabled engine exactly like the standard path above.
    BOOL enabled = [[GPSLabEngine sharedEngine] isEnabled];

    __block GPSLabManagerState *state = nil;
    __block BOOL started = NO;

    CLLocationManager *managerForLock = manager;
    [self performLocked:^{
        GPSLabManagerState *existing = [self stateLockedForManager:managerForLock create:YES];
        state = existing;
        existing.significantRequested = YES;
        if (!enabled || existing.significantRunning) {
            return;
        }
        if ([self startSignificantTimerLocked:existing]) {
            started = YES;
        }
    }];

    if (started) {
        GPSLabManagerState *capturedState = state;
        dispatch_async(dispatch_get_main_queue(), ^{
            [capturedState deliverSignificantLocationUpdate];
        });
    }
}

- (void)cancelSignificantForManager:(CLLocationManager *)manager {
    if (manager == nil) {
        return;
    }
    CLLocationManager *managerForLock = manager;
    [self performLocked:^{
        GPSLabManagerState *state = [self stateLockedForManager:managerForLock create:NO];
        if (state == nil) {
            return;
        }
        state.significantRequested = NO;
        [state cancelSignificantTimer];
        [self pruneStateLocked:state forManager:managerForLock];
    }];
}

- (void)deliverSingleUpdateForManager:(CLLocationManager *)manager {
    if (manager == nil) {
        return;
    }
    if (![[GPSLabEngine sharedEngine] isEnabled]) {
        return;
    }
    if ([GPSLabCoreLocationHooks isBypassedManager:manager]) {
        return;
    }

    // One-shot: no intent is retained.
    __weak CLLocationManager *weakManager = manager;
    dispatch_async(dispatch_get_main_queue(), ^{
        CLLocationManager *strongManager = weakManager;
        if (strongManager == nil) {
            return;
        }
        [GPSLabLocationStream deliverUpdateToManager:strongManager];
    });
}

- (void)notifyAuthorizationGrantedForManager:(CLLocationManager *)manager {
    if (manager == nil) {
        return;
    }
    if (![[GPSLabEngine sharedEngine] isEnabled]) {
        return;
    }
    if ([GPSLabCoreLocationHooks isBypassedManager:manager]) {
        return;
    }

    __weak CLLocationManager *weakManager = manager;
    dispatch_async(dispatch_get_main_queue(), ^{
        CLLocationManager *strongManager = weakManager;
        if (strongManager == nil) {
            return;
        }

        id<CLLocationManagerDelegate> delegate = strongManager.delegate;
        if (delegate == nil) {
            return;
        }

        // The legacy callback and its selector are deprecated in iOS 14; the
        // legacy path runs only for delegates that do not implement the modern
        // replacement. Suppress the deprecation diagnostics across this branch
        // (both the @selector reference and the message send).
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        if ([delegate respondsToSelector:@selector(locationManagerDidChangeAuthorization:)]) {
            [delegate locationManagerDidChangeAuthorization:strongManager];
        } else if ([delegate respondsToSelector:@selector(locationManager:didChangeAuthorizationStatus:)]) {
            id plainDelegate = (id)delegate;
            [plainDelegate locationManager:strongManager
            didChangeAuthorizationStatus:kCLAuthorizationStatusAuthorizedAlways];
        }
#pragma clang diagnostic pop
    });
}

#pragma mark - Suspend / resume

- (void)suspendAllSyntheticPreservingIntent {
    [self performLocked:^{
        NSArray<GPSLabManagerState *> *states = self->_states.objectEnumerator.allObjects;
        for (GPSLabManagerState *state in states) {
            // Stop synthetic timers but keep the recorded intent so a later
            // enable/foreground can resume exactly what the host asked for.
            [state cancelStandardTimer];
            [state cancelSignificantTimer];
        }
    }];
}

- (void)resumeAllRequestedSynthetic {
    // Starting the original streams back is the caller's responsibility; here we
    // only re-arm the synthetic timers for managers that still have intent.
    NSMutableArray<GPSLabManagerState *> *toStart = [NSMutableArray array];

    [self performLocked:^{
        NSArray<GPSLabManagerState *> *states = self->_states.objectEnumerator.allObjects;
        for (GPSLabManagerState *state in states) {
            CLLocationManager *manager = state.manager;
            if (manager == nil) {
                continue;
            }
            if ([GPSLabCoreLocationHooks isBypassedManager:manager]) {
                continue;
            }
            [toStart addObject:state];
        }
    }];

    for (GPSLabManagerState *state in toStart) {
        CLLocationManager *manager = state.manager;
        if (manager == nil) {
            continue;
        }
        if (state.standardRequested) {
            [self startStandardForManagerDirectly:manager];
        }
        if (state.significantRequested) {
            [self startSignificantForManagerDirectly:manager];
        }
    }
}

- (NSArray<CLLocationManager *> *)requestedManagers {
    return [self managersMatchingIntent:^BOOL(GPSLabManagerState *state) {
        return state.standardRequested || state.significantRequested;
    }];
}

- (NSArray<CLLocationManager *> *)standardRequestedManagers {
    return [self managersMatchingIntent:^BOOL(GPSLabManagerState *state) {
        return state.standardRequested;
    }];
}

- (NSArray<CLLocationManager *> *)significantRequestedManagers {
    return [self managersMatchingIntent:^BOOL(GPSLabManagerState *state) {
        return state.significantRequested;
    }];
}

// Collects the non-bypassed managers whose state satisfies `predicate`.
- (NSArray<CLLocationManager *> *)managersMatchingIntent:(BOOL (^)(GPSLabManagerState *state))predicate {
    NSMutableArray<CLLocationManager *> *managers = [NSMutableArray array];
    [self performLocked:^{
        NSArray<GPSLabManagerState *> *states = self->_states.objectEnumerator.allObjects;
        for (GPSLabManagerState *state in states) {
            CLLocationManager *manager = state.manager;
            if (manager == nil) {
                continue;
            }
            if ([GPSLabCoreLocationHooks isBypassedManager:manager]) {
                continue;
            }
            if (predicate(state)) {
                [managers addObject:manager];
            }
        }
    }];
    return managers;
}

#pragma mark - Timer start helpers (must run on _registryQueue)

- (BOOL)startStandardTimerLocked:(GPSLabManagerState *)state {
    __weak GPSLabManagerState *weakState = state;
    dispatch_source_t timer = GPSLabCreateTimer(kGPSLabStandardIntervalSeconds, ^{
        [weakState deliverStandardLocationUpdate];
    });
    if (timer == NULL) {
        return NO;
    }
    state.standardTimer = timer;
    state.standardRunning = YES;
    dispatch_resume(timer);
    return YES;
}

- (BOOL)startSignificantTimerLocked:(GPSLabManagerState *)state {
    __weak GPSLabManagerState *weakState = state;
    dispatch_source_t timer = GPSLabCreateTimer(kGPSLabSignificantIntervalSeconds, ^{
        [weakState deliverSignificantLocationUpdate];
    });
    if (timer == NULL) {
        return NO;
    }
    state.significantTimer = timer;
    state.significantRunning = YES;
    dispatch_resume(timer);
    return YES;
}

- (void)startStandardForManagerDirectly:(CLLocationManager *)manager {
    if (manager == nil || ![GPSLabEngine sharedEngine].isEnabled) {
        return;
    }
    __block GPSLabManagerState *state = nil;
    CLLocationManager *managerForLock = manager;
    [self performLocked:^{
        GPSLabManagerState *existing = [self stateLockedForManager:managerForLock create:YES];
        existing.standardRequested = YES;
        if (!existing.standardRunning) {
            [self startStandardTimerLocked:existing];
        }
        state = existing;
    }];
    if (state != nil) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [state deliverStandardLocationUpdate];
        });
    }
}

- (void)startSignificantForManagerDirectly:(CLLocationManager *)manager {
    if (manager == nil || ![GPSLabEngine sharedEngine].isEnabled) {
        return;
    }
    __block GPSLabManagerState *state = nil;
    CLLocationManager *managerForLock = manager;
    [self performLocked:^{
        GPSLabManagerState *existing = [self stateLockedForManager:managerForLock create:YES];
        existing.significantRequested = YES;
        if (!existing.significantRunning) {
            [self startSignificantTimerLocked:existing];
        }
        state = existing;
    }];
    if (state != nil) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [state deliverSignificantLocationUpdate];
        });
    }
}

#pragma mark - Delegate delivery

+ (void)deliverUpdateToManager:(CLLocationManager *)manager {
    if (manager == nil) {
        return;
    }
    if (![[GPSLabEngine sharedEngine] isEnabled]) {
        return;
    }
    if ([GPSLabCoreLocationHooks isBypassedManager:manager]) {
        return;
    }

    id<CLLocationManagerDelegate> delegate = manager.delegate;
    if (delegate == nil) {
        return;
    }
    if (![delegate respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
        return;
    }

    CLLocation *location = [[GPSLabEngine sharedEngine] nextLocation];
    if (location == nil) {
        // The entitlement gate closed between the enabled check and generation.
        return;
    }
    [delegate locationManager:manager didUpdateLocations:@[ location ]];
}

#pragma mark - Registry internals (must run on _registryQueue)

- (void)performLocked:(dispatch_block_t)block {
    if (dispatch_get_specific(kGPSLabRegistryQueueKey) != NULL) {
        block();
    } else {
        dispatch_sync(_registryQueue, block);
    }
}

- (GPSLabManagerState *)stateLockedForManager:(CLLocationManager *)manager create:(BOOL)create {
    GPSLabManagerState *state = [_states objectForKey:manager];
    if (state == nil && create) {
        state = [[GPSLabManagerState alloc] init];
        state.manager = manager;
        [_states setObject:state forKey:manager];
        objc_setAssociatedObject(manager,
                                 &kGPSLabManagerStateKey,
                                 state,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return state;
}

- (void)pruneStateLocked:(GPSLabManagerState *)state forManager:(CLLocationManager *)manager {
    if (state == nil) {
        return;
    }
    // Keep the state alive while any intent remains, even if no timer is running.
    if (state.standardRequested || state.significantRequested ||
        state.standardRunning || state.significantRunning) {
        return;
    }
    [state cancelStandardTimer];
    [state cancelSignificantTimer];
    [self forgetStateLocked:state forManager:manager];
}

- (void)forgetStateLocked:(GPSLabManagerState *)state forManager:(CLLocationManager *)manager {
    if (state == nil) {
        return;
    }
    [_states removeObjectForKey:manager];
    objc_setAssociatedObject(manager, &kGPSLabManagerStateKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@end

#pragma mark - Helpers

static dispatch_source_t GPSLabCreateTimer(double intervalSeconds, dispatch_block_t handler) {
    uint64_t intervalNanoseconds = (uint64_t)(intervalSeconds * (double)NSEC_PER_SEC);
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,
                                                     0,
                                                     0,
                                                     dispatch_get_main_queue());
    if (timer == NULL) {
        return NULL;
    }
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)intervalNanoseconds),
                              intervalNanoseconds,
                              (uint64_t)(0.1 * (double)NSEC_PER_SEC));
    dispatch_source_set_event_handler(timer, handler);
    return timer;
}
