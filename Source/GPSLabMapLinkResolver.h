//
//  GPSLabMapLinkResolver.h
//  GPSLab
//
//  Turns a map-link search-field string into coordinates WITHOUT ever touching
//  the synthetic engine. It reuses the pure-C policy core for all classification
//  and only follows short links through an injectable transport (the production
//  transport enforces the strict HTTPS allowlist, redirect and challenge policy).
//
//  The resolver owns only token/generation bookkeeping: every input transition
//  cancels the previous request and advances the generation, so a late or
//  hostile completion from a superseded request can never win. Results are
//  delivered on the main thread.
//

#import <CoreLocation/CoreLocation.h>
#import <Foundation/Foundation.h>

#import "GPSLabMapLinkTransport.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, GPSLabMapLinkResolverError) {
    GPSLabMapLinkResolverErrorNone = 0,
    /** Not a maps link and not a coordinate pair: the caller keeps its normal flow. */
    GPSLabMapLinkResolverErrorNotALink,
    /** A link whose host/scheme is not on the strict allowlist: never followed. */
    GPSLabMapLinkResolverErrorUntrusted,
    /** A trusted short link that produced no usable coordinates. */
    GPSLabMapLinkResolverErrorUnresolved,
};

/** Immutable result delivered on the main thread. */
@interface GPSLabMapLinkResolverResult : NSObject

@property (nonatomic, readonly, getter=isSuccess) BOOL success;
@property (nonatomic, readonly) CLLocationCoordinate2D coordinate;
/** Localization catalog key for the provider banner, or nil for a bare pair. */
@property (nonatomic, readonly, copy, nullable) NSString *sourceKindKey;
@property (nonatomic, readonly) GPSLabMapLinkResolverError error;

+ (instancetype)successWithCoordinate:(CLLocationCoordinate2D)coordinate
                        sourceKindKey:(nullable NSString *)sourceKindKey;
+ (instancetype)failureWithError:(GPSLabMapLinkResolverError)error;

@end

@interface GPSLabMapLinkResolver : NSObject

/** Production resolver (hardened URL-session transport). */
+ (instancetype)sharedResolver;

/** Test seam: inject an offline transport. */
- (instancetype)initWithTransport:(id<GPSLabMapLinkTransport>)transport NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/**
 * Classifies `text` and, for a trusted short link, resolves it asynchronously.
 * The completion always runs on the main thread. Calling it again cancels any
 * in-flight resolution (the older completion is dropped as stale).
 */
- (void)resolveText:(nullable NSString *)text
         completion:(void (^)(GPSLabMapLinkResolverResult *result))completion;

/** Cancels any in-flight resolution and drops its completion. */
- (void)cancel;

@end

NS_ASSUME_NONNULL_END
