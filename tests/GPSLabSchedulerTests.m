//
//  GPSLabSchedulerTests.m
//  GPSLab
//
//  Foundation tests for the real GPSLabScheduler using an injected host: a fake
//  clock, a recorded timer, controllable foreground/engine/license state and a
//  simulated coordinator ownership map. No engine, no real time, no UIKit.
//
//  Build/run (macOS):
//    clang -fobjc-arc -fmodules -framework Foundation -ISource \
//      tests/GPSLabSchedulerTests.m Source/GPSLabScheduler.m Source/GPSLabSchedulerCore.c \
//      Source/GPSLabProfile.m Source/GPSLabProfileCore.c -o /tmp/gpslab-scheduler-tests
//    /tmp/gpslab-scheduler-tests
//

#import <Foundation/Foundation.h>

#import "GPSLabScheduler.h"
#import "GPSLabSchedulerCore.h"

static int gFailures = 0;
static int gChecks = 0;

#define CHECK(condition, message)                                  \
    do {                                                           \
        gChecks++;                                                 \
        if (!(condition)) {                                        \
            gFailures++;                                           \
            fprintf(stderr, "FAIL: %s\n", [(message) UTF8String]); \
        }                                                          \
    } while (0)

#pragma mark - Fake host

@interface FakeSchedulerHost : NSObject <GPSLabSchedulerHost>
@property (nonatomic, assign) long long now;
@property (nonatomic, assign) BOOL foreground;
@property (nonatomic, assign) BOOL engineEnabled;
@property (nonatomic, assign) BOOL licenseUnlocked;
@property (nonatomic, copy, nullable) NSString *ownedIdentifier;
@property (nonatomic, strong, nullable) GPSLabProfile *appliedProfile;
@property (nonatomic, assign) NSUInteger appliedCount;
@property (nonatomic, assign) long long lastDelay;
@property (nonatomic, assign) NSUInteger lastGeneration;
@property (nonatomic, assign) NSUInteger cancelCount;
@property (nonatomic, assign) NSUInteger invalidateCount;
@property (nonatomic, assign) NSUInteger cancelPendingApplicationCount;
@property (nonatomic, strong) NSMutableArray<NSString *> *stopped;
@property (nonatomic, assign) BOOL deferApply;
@property (nonatomic, copy, nullable) void (^pendingApplyCompletion)(BOOL applied);
@property (nonatomic, strong, nullable) GPSLabProfile *pendingApplyProfile;
- (void)completeApply:(BOOL)applied;
@end

@implementation FakeSchedulerHost

- (instancetype)init {
    self = [super init];
    if (self) {
        _foreground = YES;
        _engineEnabled = YES;
        _licenseUnlocked = YES;
        _stopped = [NSMutableArray array];
    }
    return self;
}

- (long long)schedulerNowSeconds { return self.now; }
- (BOOL)schedulerIsForeground { return self.foreground; }
- (BOOL)schedulerIsEngineEnabled { return self.engineEnabled; }
- (BOOL)schedulerIsLicenseUnlocked { return self.licenseUnlocked; }

- (void)schedulerScheduleTimerAfterSeconds:(long long)seconds generation:(NSUInteger)generation {
    self.lastDelay = seconds;
    self.lastGeneration = generation;
}

- (void)schedulerCancelTimer { self.cancelCount++; }

- (void)schedulerApplyProfile:(GPSLabProfile *)profile completion:(void (^)(BOOL applied))completion {
    self.appliedProfile = profile;
    self.appliedCount++;
    if (self.deferApply) {
        self.pendingApplyCompletion = completion;
        self.pendingApplyProfile = profile;
        return; // simulate an asynchronous route preparation
    }
    self.ownedIdentifier = profile.identifier;
    if (completion != nil) {
        completion(YES);
    }
}

- (void)completeApply:(BOOL)applied {
    void (^completion)(BOOL) = self.pendingApplyCompletion;
    self.pendingApplyCompletion = nil;
    if (applied && self.pendingApplyProfile != nil) {
        self.ownedIdentifier = self.pendingApplyProfile.identifier;
    }
    if (completion != nil) {
        completion(applied);
    }
}

- (BOOL)schedulerOwnsProfileIdentifier:(NSString *)identifier {
    return [self.ownedIdentifier isEqualToString:identifier];
}

- (void)schedulerStopOwnedProfileIdentifier:(NSString *)identifier {
    [self.stopped addObject:identifier];
    self.ownedIdentifier = nil;
}

- (void)schedulerInvalidateOwnedProfile {
    self.invalidateCount++;
    self.ownedIdentifier = nil;
}

- (void)schedulerCancelPendingApplication { self.cancelPendingApplicationCount++; }

- (void)schedulerStartObserving { /* no notifications in the test host */ }

@end

#pragma mark - Helpers

static GPSLabProfile *ScheduledProfile(NSString *identifier,
                                       GPSLabProfileScheduleMode mode,
                                       long long start,
                                       long long end) {
    GPSLabProfileSchedule *schedule = [[GPSLabProfileSchedule alloc] initWithMode:mode
                                                                       startEpoch:start
                                                                         endEpoch:end
                                                           timeZoneOffsetSeconds:0];
    return [[GPSLabProfile alloc] initWithIdentifier:identifier
                                                name:@"Sched"
                                        locationMode:GPSLabProfileLocationStatic
                                           latitude:24.7136
                                          longitude:46.6753
                                           altitude:0.0
                                            heading:-1.0
                                       driftEnabled:NO
                                  driftRadiusMeters:12.0
                                              route:nil
                                               wifi:nil
                                          bluetooth:nil
                                           schedule:schedule];
}

#pragma mark - Tests

static void test_far_future_waits_then_fires_at_real_start(void) {
    FakeSchedulerHost *host = [[FakeSchedulerHost alloc] init];
    GPSLabScheduler *scheduler = [[GPSLabScheduler alloc] initWithHost:host];
    host.now = 0;
    long long start = 48LL * 3600LL;
    [scheduler armWithProfile:ScheduledProfile(@"far", GPSLabProfileScheduleOnce, start, start)];

    CHECK(!scheduler.isFired, @"48h-away schedule does not fire immediately");
    CHECK(host.lastDelay == GPSLAB_SCHEDULER_MAX_WAIT_SECONDS, @"wake is clamped to 24h");

    host.now = start - 1;
    [scheduler handleTimerGeneration:host.lastGeneration];
    CHECK(!scheduler.isFired, @"clamped wake far from start does not fire");
    CHECK(host.lastDelay == 1, @"re-evaluated wake is one second away");

    host.now = start;
    [scheduler handleTimerGeneration:host.lastGeneration];
    CHECK(scheduler.isFired, @"fires at the real start");
    CHECK(host.appliedCount == 1, @"applied exactly once");
}

static void test_background_suspends_and_foreground_resumes(void) {
    FakeSchedulerHost *host = [[FakeSchedulerHost alloc] init];
    GPSLabScheduler *scheduler = [[GPSLabScheduler alloc] initWithHost:host];
    host.now = 1000;
    host.foreground = NO;
    [scheduler armWithProfile:ScheduledProfile(@"bg", GPSLabProfileScheduleOnce, 1000, 1000)];
    CHECK(!scheduler.isFired, @"backgrounded schedule performs no work");
    CHECK(host.appliedCount == 0, @"nothing applied while backgrounded");

    host.foreground = YES;
    [scheduler noteForegroundChanged];
    CHECK(scheduler.isFired, @"resumes and fires when foregrounded in-window");
}

static void test_long_window_stops_at_real_end_only(void) {
    FakeSchedulerHost *host = [[FakeSchedulerHost alloc] init];
    GPSLabScheduler *scheduler = [[GPSLabScheduler alloc] initWithHost:host];
    host.now = 1000;
    long long end = 1000 + 48LL * 3600LL;
    [scheduler armWithProfile:ScheduledProfile(@"win", GPSLabProfileScheduleWindow, 1000, end)];
    CHECK(scheduler.isFired, @"window fires at its start");
    CHECK([host.ownedIdentifier isEqualToString:@"win"], @"ownership recorded");
    CHECK(host.lastDelay == GPSLAB_SCHEDULER_MAX_WAIT_SECONDS, @"window wait is clamped");

    host.now = 1000 + GPSLAB_SCHEDULER_MAX_WAIT_SECONDS;
    [scheduler handleTimerGeneration:host.lastGeneration];
    CHECK(host.stopped.count == 0, @"clamped wake does not stop the window early");
    CHECK(host.lastDelay == GPSLAB_SCHEDULER_MAX_WAIT_SECONDS, @"still waiting");

    host.now = end;
    [scheduler handleTimerGeneration:host.lastGeneration];
    CHECK(host.stopped.count == 1, @"stops exactly once at the real end");
    CHECK([host.stopped.firstObject isEqualToString:@"win"], @"stopped the owned profile");
}

static void test_manual_disable_blocks_then_explicit_rearm_works(void) {
    FakeSchedulerHost *host = [[FakeSchedulerHost alloc] init];
    GPSLabScheduler *scheduler = [[GPSLabScheduler alloc] initWithHost:host];
    host.now = 0;
    GPSLabProfile *profile = ScheduledProfile(@"latch", GPSLabProfileScheduleOnce, 100, 100);
    [scheduler armWithProfile:profile];
    CHECK(!scheduler.isFired, @"future schedule waits");

    [scheduler noteManualEngineDisable];
    CHECK(host.cancelPendingApplicationCount == 1, @"manual disable invalidates pending application");
    CHECK(host.invalidateCount >= 1, @"manual disable invalidates ownership");

    host.engineEnabled = YES;
    host.now = 100;
    [scheduler noteEngineStateChanged];
    CHECK(!scheduler.isFired, @"re-enabling alone never silently fires");
    CHECK(host.appliedCount == 0, @"no apply after silent re-enable");

    [scheduler armWithProfile:profile];
    CHECK(scheduler.isFired, @"explicit re-arm fires");
    CHECK(host.appliedCount == 1, @"explicit re-arm applies exactly once");
}

static void test_stale_generation_ignored(void) {
    FakeSchedulerHost *host = [[FakeSchedulerHost alloc] init];
    GPSLabScheduler *scheduler = [[GPSLabScheduler alloc] initWithHost:host];
    host.now = 0;
    [scheduler armWithProfile:ScheduledProfile(@"stale", GPSLabProfileScheduleOnce, 1000, 1000)];
    NSUInteger staleGeneration = host.lastGeneration + 99;
    [scheduler handleTimerGeneration:staleGeneration];
    CHECK(!scheduler.isFired, @"a stale wake does nothing");
    CHECK(host.appliedCount == 0, @"stale wake applies nothing");
}

static void test_switching_profiles_does_not_stop_new_one(void) {
    FakeSchedulerHost *host = [[FakeSchedulerHost alloc] init];
    GPSLabScheduler *scheduler = [[GPSLabScheduler alloc] initWithHost:host];
    host.now = 1000;
    [scheduler armWithProfile:ScheduledProfile(@"A", GPSLabProfileScheduleWindow, 1000, 2000)];
    CHECK([host.ownedIdentifier isEqualToString:@"A"], @"A owns the window");
    NSUInteger generationForA = host.lastGeneration;

    host.now = 1500;
    [scheduler armWithProfile:ScheduledProfile(@"B", GPSLabProfileScheduleOnce, 1500, 1500)];
    CHECK([host.ownedIdentifier isEqualToString:@"B"], @"B replaced A as owner");
    CHECK(host.appliedCount == 2, @"both applied");

    // A's retired wake must not stop B.
    [scheduler handleTimerGeneration:generationForA];
    CHECK(host.stopped.count == 0, @"retired A wake never stops B");

    // Duplicate callback for B's wake must not double-apply.
    NSUInteger generationForB = host.lastGeneration;
    [scheduler handleTimerGeneration:generationForB];
    [scheduler handleTimerGeneration:generationForB];
    CHECK(host.appliedCount == 2, @"duplicate callbacks do not re-apply");
}

static void test_deferred_async_completion_arms_true_end(void) {
    FakeSchedulerHost *host = [[FakeSchedulerHost alloc] init];
    GPSLabScheduler *scheduler = [[GPSLabScheduler alloc] initWithHost:host];
    host.now = 1000;
    host.deferApply = YES;
    long long end = 1000 + 48LL * 3600LL;
    [scheduler armWithProfile:ScheduledProfile(@"async", GPSLabProfileScheduleWindow, 1000, end)];

    CHECK(scheduler.isFired, @"async window marks fired at its start");
    CHECK(host.pendingApplyCompletion != nil, @"apply deferred (route preparation)");
    CHECK(host.ownedIdentifier == nil, @"ownership is not real until completion");
    CHECK(host.lastDelay == 0, @"no window-end timer before ownership exists");
    CHECK(host.stopped.count == 0, @"no early stop");

    [host completeApply:YES];
    CHECK([host.ownedIdentifier isEqualToString:@"async"], @"ownership real after completion");
    CHECK(host.lastDelay == GPSLAB_SCHEDULER_MAX_WAIT_SECONDS, @"true end wait armed after async success");
    CHECK(host.stopped.count == 0, @"still no early stop");

    host.now = end;
    [scheduler handleTimerGeneration:host.lastGeneration];
    CHECK(host.stopped.count == 1, @"stops at the true end");
    CHECK([host.stopped.firstObject isEqualToString:@"async"], @"stopped the owned profile");
}

static void test_stale_deferred_completion_ignored(void) {
    FakeSchedulerHost *host = [[FakeSchedulerHost alloc] init];
    GPSLabScheduler *scheduler = [[GPSLabScheduler alloc] initWithHost:host];
    host.now = 1000;
    host.deferApply = YES;
    [scheduler armWithProfile:ScheduledProfile(@"A", GPSLabProfileScheduleWindow, 1000, 2000)];
    void (^completionA)(BOOL) = host.pendingApplyCompletion;
    CHECK(completionA != nil, @"A deferred");

    host.deferApply = NO;
    [scheduler armWithProfile:ScheduledProfile(@"B", GPSLabProfileScheduleOnce, 1000, 1000)];
    CHECK([host.ownedIdentifier isEqualToString:@"B"], @"B owns");
    NSUInteger appliedAfterB = host.appliedCount;

    completionA(YES); // stale A completion
    CHECK([host.ownedIdentifier isEqualToString:@"B"], @"stale A completion never re-arms/cancels B");
    CHECK(host.appliedCount == appliedAfterB, @"stale A completion applies nothing");
    CHECK(host.stopped.count == 0, @"stale A completion never stops B");
}

static void test_background_during_async_no_fire_until_active(void) {
    FakeSchedulerHost *host = [[FakeSchedulerHost alloc] init];
    GPSLabScheduler *scheduler = [[GPSLabScheduler alloc] initWithHost:host];
    host.now = 1000;
    host.deferApply = YES;
    long long end = 1000 + 48LL * 3600LL;
    [scheduler armWithProfile:ScheduledProfile(@"bgasync", GPSLabProfileScheduleWindow, 1000, end)];

    host.foreground = NO;
    [host completeApply:YES];
    CHECK(host.lastDelay == 0, @"no end timer armed while backgrounded");

    host.foreground = YES;
    [scheduler noteForegroundChanged];
    CHECK(host.lastDelay == GPSLAB_SCHEDULER_MAX_WAIT_SECONDS, @"end wait armed once active again");
    CHECK(host.stopped.count == 0, @"no stop while active before end");
}

int main(void) {
    @autoreleasepool {
        test_far_future_waits_then_fires_at_real_start();
        test_background_suspends_and_foreground_resumes();
        test_long_window_stops_at_real_end_only();
        test_manual_disable_blocks_then_explicit_rearm_works();
        test_stale_generation_ignored();
        test_switching_profiles_does_not_stop_new_one();
        test_deferred_async_completion_arms_true_end();
        test_stale_deferred_completion_ignored();
        test_background_during_async_no_fire_until_active();
    }

    if (gFailures == 0) {
        printf("GPSLabSchedulerTests: %d checks passed\n", gChecks);
        return 0;
    }
    fprintf(stderr, "GPSLabSchedulerTests: %d/%d checks failed\n", gFailures, gChecks);
    return 1;
}
