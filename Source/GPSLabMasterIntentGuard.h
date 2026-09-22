//
//  GPSLabMasterIntentGuard.h
//  GPSLab
//
//  Foundation-only ownership guard for the master (service) switch and for
//  profile applications that change it. The overlay uses this exact object to
//  decide whether an asynchronous apply/stage completion still owns the switch
//  intent; the tests drive the same object, so the decision logic is the
//  production logic, not a parallel toy.
//
//  Rules:
//    * a newer intent (profile apply, manual switch change, or explicit
//      invalidate) wins;
//    * a stale completion is ignored entirely (no rollback, no UI, no schedule);
//    * a current-intent failure rolls back ONLY when that intent changed the
//      switch.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, GPSLabMasterIntentResolution) {
    /** A newer intent owns the switch: do nothing at all. */
    GPSLabMasterIntentResolutionIgnoreStale = 0,
    /** The intent succeeded and still owns the switch. */
    GPSLabMasterIntentResolutionApplied,
    /** The intent failed while owning the switch it changed: restore it. */
    GPSLabMasterIntentResolutionRollback,
    /** The intent failed but did not change the switch: just surface the error. */
    GPSLabMasterIntentResolutionFailureNoChange,
};

@interface GPSLabMasterIntentGuard : NSObject

/** Starts a new intent (profile apply/stage) and returns its token. */
- (NSUInteger)beginIntent;

/** Invalidates every outstanding intent (e.g. a manual master-switch change). */
- (void)invalidateIntents;

/** YES when `token` is still the current intent. */
- (BOOL)isCurrentIntent:(NSUInteger)token;

/**
 * Resolves an asynchronous completion against the current intent. `applied` is
 * the apply/stage outcome; `switchWasChanged` is YES when the intent changed the
 * master switch before the async work started.
 */
- (GPSLabMasterIntentResolution)resolveIntent:(NSUInteger)token
                                      applied:(BOOL)applied
                           switchWasChanged:(BOOL)switchWasChanged;

@end

NS_ASSUME_NONNULL_END
