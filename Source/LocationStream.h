//
//  LocationStream.h
//  GPSLab
//
//  Per-manager synthetic location streams.
//
//  Intent (what the host asked for) is tracked independently from whether a synthetic
//  timer is currently running. That lets the engine suspend synthetic delivery while
//  the host app is disabled/backgrounded without forgetting the request, and resume
//  it later.
//

#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

#import "CoreLocationHooks.h"

NS_ASSUME_NONNULL_BEGIN

/**
 * Owns one independent synthetic stream per CLLocationManager.
 *
 * - Standard updates: one immediate delivery, then one per second.
 * - Significant-change updates: one immediate delivery, then one every 30 seconds.
 * - Single-shot (requestLocation): exactly one delivery (no intent is retained).
 *
 * A manager may be *bypassed*: while bypassed, the hook layer routes every call to
 * the original CoreLocation implementation and the stream never produces synthetic
 * fixes for that manager. Bypass is used by the overlay's own display manager.
 */
@interface GPSLabLocationStream : NSObject

+ (instancetype)sharedStream;

#pragma mark - Synthetic control

/**
 * Records the host's intent for standard updates. When the engine is enabled the
 * synthetic timer is (re)started; when it is disabled the intent is still recorded
 * but nothing synthetic runs, so the hook layer can keep forwarding to the original
 * implementation and later resume synthetically on enable/foreground.
 */
- (void)requestStandardForManager:(CLLocationManager *)manager;
/** Clears the intent and stops synthetic standard delivery. */
- (void)cancelStandardForManager:(CLLocationManager *)manager;
- (void)requestSignificantForManager:(CLLocationManager *)manager;
- (void)cancelSignificantForManager:(CLLocationManager *)manager;

- (void)deliverSingleUpdateForManager:(CLLocationManager *)manager;

/** Notifies the delegate that authorization was granted (never touches the system). */
- (void)notifyAuthorizationGrantedForManager:(CLLocationManager *)manager;

#pragma mark - Suspend / resume (engine toggle, background, foreground)

/**
 * Stops every synthetic timer but keeps the recorded intent. Callers that need to
 * hand managers back to real CoreLocation use `standardRequestedManagers` /
 * `significantRequestedManagers` to start only the streams the host asked for.
 */
- (void)suspendAllSyntheticPreservingIntent;

/** Resumes synthetic delivery for every manager that still has intent. */
- (void)resumeAllRequestedSynthetic;

/** Managers with a recorded standard intent that are not bypassed. */
- (NSArray<CLLocationManager *> *)standardRequestedManagers;

/** Managers with a recorded significant intent that are not bypassed. */
- (NSArray<CLLocationManager *> *)significantRequestedManagers;

/** Managers (weak wrappers) that currently have a requested intent and are not bypassed. */
- (NSArray<CLLocationManager *> *)requestedManagers;

@end

NS_ASSUME_NONNULL_END
