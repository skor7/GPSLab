//
//  GPSLabProfileApplicationCoordinator.h
//  GPSLab
//
//  Applies a profile through a small backend protocol. The production backend
//  uses ONLY the existing public GPSLabEngine / GPSLabLicenseManager APIs; it
//  never touches the hook layer, configuration internals, the route simulator,
//  the CoreLocation store or any CoreLocation source.
//
//  The coordinator owns the notion of "currently applied profile" so the
//  scheduler never depends on UI selection. A stale asynchronous route
//  completion is side-effect free: cancellation invalidates only the request it
//  owns, and a newer application already tore the old route down.
//
//  A fixture backend can be injected for unit tests without a host manager.
//

#import <CoreLocation/CoreLocation.h>
#import <Foundation/Foundation.h>

#import "GPSLabProfile.h"
#import "GPSLabTypes.h"

NS_ASSUME_NONNULL_BEGIN

@protocol GPSLabProfileApplicationBackend <NSObject>

- (BOOL)isEngineEnabled;
- (BOOL)isLicenseUnlocked;

- (void)applyStaticCoordinate:(CLLocationCoordinate2D)coordinate
                     altitude:(double)altitude
                      heading:(double)heading;
/** Applies altitude/heading without moving the anchor (used by route profiles). */
- (void)applyAltitude:(double)altitude heading:(double)heading;
- (void)setDriftEnabled:(BOOL)enabled radiusMeters:(double)radius;
- (void)stopRoute;
- (void)startRouteFrom:(CLLocationCoordinate2D)start
                    to:(CLLocationCoordinate2D)end
                  mode:(GPSLabRouteMode)mode
        customSpeedKmh:(double)customSpeedKmh
            completion:(nullable void (^)(NSError * _Nullable error))completion;

/** Opaque snapshot of the backend's apply-relevant state (best effort). */
- (nullable id)captureSnapshot;
- (void)restoreSnapshot:(nullable id)snapshot;

@end

/** Typed outcome with a catalog message key (never a raw error description). */
@interface GPSLabProfileApplicationResult : NSObject

@property (nonatomic, readonly) BOOL applied;
@property (nonatomic, readonly, copy, nullable) NSString *messageKey;

+ (instancetype)appliedResult;
+ (instancetype)resultWithMessageKey:(NSString *)messageKey;

@end

@interface GPSLabProfileApplicationCoordinator : NSObject

+ (instancetype)sharedCoordinator;

- (instancetype)initWithBackend:(id<GPSLabProfileApplicationBackend>)backend NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/**
 * The identifier of the profile the coordinator most recently applied
 * successfully. This is the ownership token the scheduler uses; it is
 * independent of any UI selection and is cleared by a manual change or
 * cancellation.
 */
@property (nonatomic, readonly, copy, nullable) NSString *appliedProfileIdentifier;

/**
 * Applies `profile` atomically from the caller's perspective: the profile is
 * strictly validated and the engine must already be enabled and unlocked (this
 * never enables it). Wi-Fi/Bluetooth test metadata is activated/cleared through
 * the simulation registry. An asynchronous route that finishes after a newer
 * selection, cancellation, license lock or manual disable is NOT applied and
 * performs no engine writes.
 */
- (void)applyProfile:(GPSLabProfile *)profile
          completion:(nullable void (^)(GPSLabProfileApplicationResult *result))completion;

/**
 * Stages a profile's synthetic state while the engine stays OFF. It validates and
 * gates on the license exactly like applyProfile:, but deliberately skips the
 * engine-enabled gate so an explicitly disabled profile can load its saved
 * coordinate (a route profile stages its start coordinate), altitude, heading,
 * drift and test metadata and be usable on the next enable. It never
 * enables/toggles the engine.
 *
 * Ownership: the gates run BEFORE any state change; only after they pass does it
 * stop the prior owned active/pending route and clear ownership. Staging is not
 * an application, so `appliedProfileIdentifier` is left nil and the scheduler is
 * never armed.
 *
 * A route is NEVER started while the engine is OFF: the engine has no
 * auto-start-on-enable behaviour, so the user must start the route explicitly
 * after the next enable. Backward compatible: callers that never use it are
 * unaffected.
 */
- (void)stageProfile:(GPSLabProfile *)profile
          completion:(nullable void (^)(GPSLabProfileApplicationResult *result))completion;

/**
 * Invalidates any in-flight application and stops ONLY the route this
 * coordinator currently owns (if any). Already-applied ownership is cleared.
 */
- (void)cancelPendingApplication;

/** Marks a manual (non-coordinator) change: clears applied ownership. */
- (void)invalidateAppliedProfile;

@end

NS_ASSUME_NONNULL_END
