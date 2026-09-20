//
//  GPSLabScheduler.h
//  GPSLab
//
//  Best-effort foreground scheduler for a selected profile's optional schedule.
//
//  iOS cannot guarantee that a host app is launched or woken on the user's
//  behalf, so this scheduler never claims background reliability: it arms a
//  single bounded timer for the next due instant while GPSLab is running and
//  re-evaluates deterministically with the real clock on every wake and when the
//  app becomes active again.
//
//  It applies a profile ONLY when the synthetic engine is ALREADY enabled and
//  the license is unlocked, and it never re-enables GPSLab after a manual
//  Disable. Ownership is recorded by the application coordinator (never by UI
//  selection): at the end of a window it stops GPSLab's own scheduled profile
//  only while that profile is still owned.
//
//  A host protocol abstracts the clock, the timer, app-active state, the engine
//  gate and the coordinator, so the runtime behaviour is unit-testable.
//

#import <Foundation/Foundation.h>

#import "GPSLabProfile.h"

NS_ASSUME_NONNULL_BEGIN

@protocol GPSLabSchedulerHost;

@interface GPSLabScheduler : NSObject

+ (instancetype)sharedScheduler;

/** Test seam: inject a host (clock, timer, foreground, gate, ownership). */
- (instancetype)initWithHost:(id<GPSLabSchedulerHost>)host NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/** Starts observing app activation and license/engine state (idempotent). */
- (void)startObserving;

/**
 * Explicit user apply: arms (or re-arms) the schedule for `profile`. Passing
 * nil, a profile without a schedule, or an already-expired schedule clears any
 * pending work. This is the ONLY path that clears the manual-disable latch.
 */
- (void)armWithProfile:(nullable GPSLabProfile *)profile;

/** Cancels pending work and releases ownership (selection change/delete/close). */
- (void)cancelPending;

/** Marks a user-initiated Disable: cancels pending work and blocks re-arming. */
- (void)noteManualEngineDisable;

/** The profile id the scheduler last applied (nil when it owns nothing). */
@property (nonatomic, readonly, copy, nullable) NSString *ownedProfileIdentifier;

/** YES once the armed profile has been applied for the current arm. */
@property (nonatomic, readonly) BOOL isFired;

/** Host callback: a scheduled wake with this generation fired. */
- (void)handleTimerGeneration:(NSUInteger)generation;

/** Host/notification callbacks. */
- (void)noteForegroundChanged;
- (void)noteEngineStateChanged;
- (void)noteLicenseStateChanged;

@end

#pragma mark - Host

@protocol GPSLabSchedulerHost <NSObject>

- (long long)schedulerNowSeconds;
- (BOOL)schedulerIsForeground;
- (void)schedulerScheduleTimerAfterSeconds:(long long)seconds generation:(NSUInteger)generation;
- (void)schedulerCancelTimer;
- (void)schedulerApplyProfile:(GPSLabProfile *)profile completion:(void (^)(BOOL applied))completion;
- (BOOL)schedulerIsEngineEnabled;
- (BOOL)schedulerIsLicenseUnlocked;
- (BOOL)schedulerOwnsProfileIdentifier:(NSString *)identifier;
- (void)schedulerStopOwnedProfileIdentifier:(NSString *)identifier;
- (void)schedulerInvalidateOwnedProfile;
- (void)schedulerCancelPendingApplication;
/** Register engine/license observers and forward them to the scheduler. */
- (void)schedulerStartObserving;

@end

NS_ASSUME_NONNULL_END
