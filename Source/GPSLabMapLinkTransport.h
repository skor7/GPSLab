//
//  GPSLabMapLinkTransport.h
//  GPSLab
//
//  Minimal transport seam for the map-link resolver. The production
//  implementation performs a hardened, bounded HTTPS GET and reports the final
//  URL; tests inject an offline mock so the resolver's request/stale/redirect
//  logic is fully exercisable without network access.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/** Completion runs on the main thread exactly once per request. */
typedef void (^GPSLabMapLinkTransportCompletion)(NSURL * _Nullable finalURL,
                                                 NSInteger statusCode,
                                                 NSError * _Nullable error);

@protocol GPSLabMapLinkTransport <NSObject>

/**
 * Starts a request. Returns an opaque token the caller can pass to
 * `cancelRequest:`. The completion is invoked on the main thread; a cancelled
 * request never invokes it.
 */
- (id)performRequestWithURL:(NSURL *)url completion:(GPSLabMapLinkTransportCompletion)completion;

/** Cancels a request. Safe on an already-finished request or a nil token. */
- (void)cancelRequest:(nullable id)requestToken;

@end

NS_ASSUME_NONNULL_END
