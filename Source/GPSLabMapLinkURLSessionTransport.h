//
//  GPSLabMapLinkURLSessionTransport.h
//  GPSLab
//
//  Production map-link transport. Strict HTTPS only, with a per-request delegate
//  so no mutable state is shared between requests. The session is ephemeral
//  (no cookies, cache, credential storage or custom headers); redirects, time,
//  bytes and headers are bounded; every redirect is validated BEFORE it is
//  followed and is rebuilt as a clean GET (no auth/cookie/body carry-over); only
//  the server-trust challenge is handled by default, all other challenges are
//  cancelled. The response body is never read.
//

#import <Foundation/Foundation.h>

#import "GPSLabMapLinkTransport.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const GPSLabMapLinkTransportErrorDomain;

typedef NS_ENUM(NSInteger, GPSLabMapLinkTransportErrorCode) {
    /** A redirect target was not on the strict allowlist. */
    GPSLabMapLinkTransportErrorUntrustedRedirect = 1,
    /** The final URL (or a redirect chain) left the allowlist. */
    GPSLabMapLinkTransportErrorUntrustedFinal = 2,
    /** The response exceeded the byte/header bounds. */
    GPSLabMapLinkTransportErrorOversize = 3,
    /** A non-2xx final response. */
    GPSLabMapLinkTransportErrorBadStatus = 4,
    /** The request was cancelled. */
    GPSLabMapLinkTransportErrorCancelled = 5,
};

@interface GPSLabMapLinkURLSessionTransport : NSObject <GPSLabMapLinkTransport>

+ (instancetype)sharedTransport;

#pragma mark - Test seams (no network access)

/** The hardened session configuration (ephemeral, no cookies/cache/credentials). */
+ (NSURLSessionConfiguration *)hardenedSessionConfiguration;

/** A rebuilt clean GET request for a redirect target (no auth/cookie/body). */
+ (NSURLRequest *)sanitizedRedirectRequestForTarget:(NSURL *)target;

/** Default handling ONLY for server trust; every other method is cancelled. */
+ (NSURLSessionAuthChallengeDisposition)dispositionForAuthenticationMethod:(nullable NSString *)method;

/** Redirect policy delegate to the pure-C core (exact allowlist + hop cap). */
+ (BOOL)shouldFollowRedirectToURLString:(nullable NSString *)urlString atHopIndex:(NSInteger)hopIndex;

/** Bound on accepted response headers (count and total bytes). */
+ (BOOL)responseHeadersAcceptableCount:(NSUInteger)headerCount bytes:(NSUInteger)headerBytes;

@end

NS_ASSUME_NONNULL_END
