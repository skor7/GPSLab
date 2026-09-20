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
 * Invalidates any in-flight application and stops ONLY the route this
 * coordinator currently owns (if any). Already-applied ownership is cleared.
 */
- (void)cancelPendingApplication;

/** Marks a manual (non-coordinator) change: clears applied ownership. */
- (void)invalidateAppliedProfile;

@end

NS_ASSUME_NONNULL_END
