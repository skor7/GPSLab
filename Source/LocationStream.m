//
//  LocationStream.m
//  GPSLab
//
//  Per-manager synthetic location streams.
//

#import "LocationStream.h"

#import <objc/runtime.h>

#import "Diagnostics.h"
#import "GPSLabEngine.h"

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
@property (atomic, assign) BOOL standardActive;
@property (atomic, assign) BOOL significantActive;
@property (nonatomic, strong, nullable) dispatch_source_t standardTimer;
@property (nonatomic, strong, nullable) dispatch_source_t significantTimer;

- (void)invalidateStandardTimer;
- (void)invalidateSignificantTimer;
- (void)deliverStandardLocationUpdate;
- (void)deliverSignificantLocationUpdate;

@end

@implementation GPSLabManagerState

- (void)invalidateStandardTimer {
    if (self.standardTimer != nil) {
        dispatch_source_cancel(self.standardTimer);
        self.standardTimer = nil;
    }
}

- (void)invalidateSignificantTimer {
    if (self.significantTimer != nil) {
        dispatch_source_cancel(self.significantTimer);
        self.significantTimer = nil;
    }
}

- (void)deliverStandardLocationUpdate {
    if (!self.standardActive) {
        return;
    }
    CLLocationManager *manager = self.manager;
    if (manager == nil) {
        return;
    }
    [GPSLabLocationStream deliverUpdateToManager:manager];
}

- (void)deliverSignificantLocationUpdate {
    if (!self.significantActive) {
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

#pragma mark - Public API

- (void)startStandardUpdatesForManager:(CLLocationManager *)manager {
    if (manager == nil) {
        return;
    }

    __block GPSLabManagerState *state = nil;
    __block BOOL started = NO;

    [self performLocked:^{
        GPSLabManagerState *existing = [self stateLockedForManager:manager create:YES];
        state = existing;
        if (existing.standardActive) {
            return;
        }

        existing.standardActive = YES;
        started = YES;

        __weak GPSLabManagerState *weakState = existing;
        dispatch_source_t timer = GPSLabCreateTimer(kGPSLabStandardIntervalSeconds, ^{
            [weakState deliverStandardLocationUpdate];
        });
        if (timer == NULL) {
            existing.standardActive = NO;
            started = NO;
            return;
        }
        existing.standardTimer = timer;
        dispatch_resume(timer);
    }];

    if (started) {
        GPSLabManagerState *capturedState = state;
        dispatch_async(dispatch_get_main_queue(), ^{
            [capturedState deliverStandardLocationUpdate];
        });
    }
}

- (void)stopStandardUpdatesForManager:(CLLocationManager *)manager {
    if (manager == nil) {
        return;
    }

    [self performLocked:^{
        GPSLabManagerState *state = [self stateLockedForManager:manager create:NO];
        if (state == nil) {
            return;
        }
        state.standardActive = NO;
        [state invalidateStandardTimer];
        [self pruneStateLocked:state forManager:manager];
    }];
}

- (void)startSignificantUpdatesForManager:(CLLocationManager *)manager {
    if (manager == nil) {
        return;
    }

    __block GPSLabManagerState *state = nil;
    __block BOOL started = NO;

    [self performLocked:^{
        GPSLabManagerState *existing = [self stateLockedForManager:manager create:YES];
        state = existing;
        if (existing.significantActive) {
            return;
        }

        existing.significantActive = YES;
        started = YES;

        __weak GPSLabManagerState *weakState = existing;
        dispatch_source_t timer = GPSLabCreateTimer(kGPSLabSignificantIntervalSeconds, ^{
            [weakState deliverSignificantLocationUpdate];
        });
        if (timer == NULL) {
            existing.significantActive = NO;
            started = NO;
            return;
        }
        existing.significantTimer = timer;
        dispatch_resume(timer);
    }];

    if (started) {
        GPSLabManagerState *capturedState = state;
        dispatch_async(dispatch_get_main_queue(), ^{
            [capturedState deliverSignificantLocationUpdate];
        });
    }
}

- (void)stopSignificantUpdatesForManager:(CLLocationManager *)manager {
    if (manager == nil) {
        return;
    }

    [self performLocked:^{
        GPSLabManagerState *state = [self stateLockedForManager:manager create:NO];
        if (state == nil) {
            return;
        }
        state.significantActive = NO;
        [state invalidateSignificantTimer];
        [self pruneStateLocked:state forManager:manager];
    }];
}

- (void)deliverSingleUpdateForManager:(CLLocationManager *)manager {
    if (manager == nil) {
        return;
    }

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

        if ([delegate respondsToSelector:@selector(locationManagerDidChangeAuthorization:)]) {
            [delegate locationManagerDidChangeAuthorization:strongManager];
        } else if ([delegate respondsToSelector:@selector(locationManager:didChangeAuthorizationStatus:)]) {
            // Send through `id` so the deprecated selector produces no build warning.
            id plainDelegate = (id)delegate;
            [plainDelegate locationManager:strongManager
            didChangeAuthorizationStatus:kCLAuthorizationStatusAuthorizedAlways];
        }
    });
}

- (void)unregisterManager:(CLLocationManager *)manager {
    if (manager == nil) {
        return;
    }

    [self performLocked:^{
        GPSLabManagerState *state = [self stateLockedForManager:manager create:NO];
        if (state == nil) {
            return;
        }
        state.standardActive = NO;
        state.significantActive = NO;
        [state invalidateStandardTimer];
        [state invalidateSignificantTimer];
        [self forgetStateLocked:state forManager:manager];
    }];
}

#pragma mark - Delegate delivery

+ (void)deliverUpdateToManager:(CLLocationManager *)manager {
    if (manager == nil) {
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
    GPSLabDiagGeneratedCoordinate(location.coordinate.latitude,
                                  location.coordinate.longitude,
                                  location.altitude);
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
        GPSLabDiagManagerRegistered();
    }
    return state;
}

- (void)pruneStateLocked:(GPSLabManagerState *)state forManager:(CLLocationManager *)manager {
    if (state == nil) {
        return;
    }
    if (state.standardActive || state.significantActive) {
        return;
    }
    [state invalidateStandardTimer];
    [state invalidateSignificantTimer];
    [self forgetStateLocked:state forManager:manager];
}

- (void)forgetStateLocked:(GPSLabManagerState *)state forManager:(CLLocationManager *)manager {
    if (state == nil) {
        return;
    }
    [_states removeObjectForKey:manager];
    objc_setAssociatedObject(manager, &kGPSLabManagerStateKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    GPSLabDiagManagerUnregistered();
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
