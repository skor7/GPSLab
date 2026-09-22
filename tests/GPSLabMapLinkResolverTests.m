//
//  GPSLabMapLinkResolverTests.m
//  GPSLab
//
//  Real Foundation tests for the map-link resolver and its transport seam. The
//  resolver is driven through an INJECTED OFFLINE MOCK transport, so the
//  synchronous classification, the async short-link path, hostile/late
//  callbacks, cancellation/staleness and the transport's session/redirect/
//  challenge policy are all exercised without any network I/O.
//
//  Build/run (macOS):
//    clang -fobjc-arc -fmodules -framework Foundation -framework CoreLocation \
//      -ISource tests/GPSLabMapLinkResolverTests.m Source/GPSLabMapLinkResolver.m \
//      Source/GPSLabMapLinkURLSessionTransport.m Source/GPSLabMapLinkCore.c \
//      -o /tmp/gpslab-map-link-resolver-tests
//    /tmp/gpslab-map-link-resolver-tests
//

#import <Foundation/Foundation.h>

#include <math.h>

#import "GPSLabMapLinkCore.h"
#import "GPSLabMapLinkResolver.h"
#import "GPSLabMapLinkURLSessionTransport.h"
#import "GPSLabMapLinkURLSessionTransportTesting.h"

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

static BOOL nearly(double a, double b) {
    return fabs(a - b) < 1e-6;
}

#pragma mark - Offline mock transport

@interface GPSLabMockMapLinkTransport : NSObject <GPSLabMapLinkTransport>
@property (nonatomic, strong) NSURL *lastRequestedURL;
@property (nonatomic, assign) NSInteger performCount;
@property (nonatomic, assign) NSInteger cancelCount;
@property (nonatomic, copy, nullable) GPSLabMapLinkTransportCompletion pending;
@end

@implementation GPSLabMockMapLinkTransport

- (id)performRequestWithURL:(NSURL *)url completion:(GPSLabMapLinkTransportCompletion)completion {
    self.performCount += 1;
    self.lastRequestedURL = url;
    self.pending = completion;
    return [[NSObject alloc] init];
}

- (void)cancelRequest:(nullable id)requestToken {
    (void)requestToken;
    self.cancelCount += 1;
    self.pending = nil; // a cancelled request never completes
}

- (void)completeWithFinalURL:(NSURL *)url statusCode:(NSInteger)status error:(NSError *)error {
    GPSLabMapLinkTransportCompletion completion = self.pending;
    self.pending = nil;
    if (completion != nil) {
        completion(url, status, error);
    }
}

@end

static GPSLabMapLinkResolverResult *ImmediateResult(GPSLabMapLinkResolver *resolver, NSString *text) {
    __block GPSLabMapLinkResolverResult *result = nil;
    [resolver resolveText:text completion:^(GPSLabMapLinkResolverResult *r) { result = r; }];
    return result;
}

int main(void) {
    @autoreleasepool {
        GPSLabMockMapLinkTransport *mock = [[GPSLabMockMapLinkTransport alloc] init];
        GPSLabMapLinkResolver *resolver = [[GPSLabMapLinkResolver alloc] initWithTransport:mock];

        // 1) Synchronous classification never touches the transport.
        GPSLabMapLinkResolverResult *result = ImmediateResult(resolver, @"37.7749, -122.4194");
        CHECK(result.isSuccess && nearly(result.coordinate.latitude, 37.7749),
              @"direct pair succeeds with coordinates");
        CHECK(result.sourceKindKey == nil, @"direct pair has no provider key");

        result = ImmediateResult(resolver, @"https://www.google.com/maps/@37.7,-122.4,15z");
        CHECK(result.isSuccess && [result.sourceKindKey isEqualToString:@"search.source.google"],
              @"google url succeeds with provider key");

        result = ImmediateResult(resolver, @"https://maps.apple.com/?ll=37.7,-122.4");
        CHECK(result.isSuccess && [result.sourceKindKey isEqualToString:@"search.source.apple"],
              @"apple url succeeds with provider key");

        result = ImmediateResult(resolver, @"https://evil.com/maps/@1,2");
        CHECK(!result.isSuccess && result.error == GPSLabMapLinkResolverErrorUntrusted,
              @"untrusted input fails closed");

        result = ImmediateResult(resolver, @"Tokyo Tower");
        CHECK(!result.isSuccess && result.error == GPSLabMapLinkResolverErrorNotALink,
              @"place text is NotALink");
        CHECK(mock.performCount == 0, @"no transport request for non-short-link input");

        // 2) A short link is resolved through the injected transport.
        __block GPSLabMapLinkResolverResult *shortResult = nil;
        [resolver resolveText:@"https://maps.app.goo.gl/AbCdEf123"
                   completion:^(GPSLabMapLinkResolverResult *r) { shortResult = r; }];
        CHECK(mock.performCount == 1, @"short link starts a transport request");
        CHECK([mock.lastRequestedURL.absoluteString isEqualToString:@"https://maps.app.goo.gl/AbCdEf123"],
              @"transport receives the normalized https short link");
        CHECK(shortResult == nil, @"short link does not resolve synchronously");
        [mock completeWithFinalURL:[NSURL URLWithString:@"https://www.google.com/maps/@24.71,46.67,15z"]
                        statusCode:200
                             error:nil];
        CHECK(shortResult.isSuccess && [shortResult.sourceKindKey isEqualToString:@"search.source.google"],
              @"resolved short link yields coordinates from the FINAL url only");

        // 3) HOSTILE/LATE: a superseded request's completion must be dropped.
        __block BOOL staleFired = NO;
        [resolver resolveText:@"https://maps.app.goo.gl/stale"
                   completion:^(GPSLabMapLinkResolverResult *r) { (void)r; staleFired = YES; }];
        CHECK(mock.performCount == 2, @"stale short link started");
        GPSLabMapLinkTransportCompletion staleCompletion = mock.pending;
        // Switching to ordinary text cancels the in-flight request...
        __block GPSLabMapLinkResolverResult *ordinary = nil;
        [resolver resolveText:@"Riyadh"
                   completion:^(GPSLabMapLinkResolverResult *r) { ordinary = r; }];
        CHECK(mock.cancelCount >= 1, @"input transition cancels the in-flight resolver request");
        CHECK(ordinary.error == GPSLabMapLinkResolverErrorNotALink, @"ordinary text classified");
        // ...and the late completion from the OLD request must not win.
        if (staleCompletion != nil) {
            staleCompletion([NSURL URLWithString:@"https://www.google.com/maps/@1,2"], 200, nil);
        }
        CHECK(!staleFired, @"late callback from a superseded request is ignored");

        // 4) Explicit cancel drops the pending completion.
        [resolver resolveText:@"https://maps.apple.com/place"
                   completion:^(GPSLabMapLinkResolverResult *r) { (void)r; }];
        NSInteger cancelsBefore = mock.cancelCount;
        [resolver cancel];
        CHECK(mock.cancelCount == cancelsBefore + 1, @"cancel() cancels the transport request");

        // 5) A transport error maps to a typed failure (untrusted vs unresolved).
        __block GPSLabMapLinkResolverResult *errorResult = nil;
        [resolver resolveText:@"https://maps.app.goo.gl/err"
                   completion:^(GPSLabMapLinkResolverResult *r) { errorResult = r; }];
        NSError *untrusted = [NSError errorWithDomain:GPSLabMapLinkTransportErrorDomain
                                                 code:GPSLabMapLinkTransportErrorUntrustedRedirect
                                             userInfo:nil];
        [mock completeWithFinalURL:nil statusCode:0 error:untrusted];
        CHECK(errorResult.error == GPSLabMapLinkResolverErrorUntrusted,
              @"untrusted redirect transport error maps to Untrusted");

        // 6) A trusted final URL without coordinates is Unresolved.
        __block GPSLabMapLinkResolverResult *unresolved = nil;
        [resolver resolveText:@"https://maps.app.goo.gl/nocoords"
                   completion:^(GPSLabMapLinkResolverResult *r) { unresolved = r; }];
        [mock completeWithFinalURL:[NSURL URLWithString:@"https://www.google.com/maps"]
                        statusCode:200
                             error:nil];
        CHECK(unresolved.error == GPSLabMapLinkResolverErrorUnresolved,
              @"coordinate-free final URL is Unresolved");

        // 7) A final URL that leaves the allowlist is rejected.
        __block GPSLabMapLinkResolverResult *leftAllowlist = nil;
        [resolver resolveText:@"https://maps.app.goo.gl/evil"
                   completion:^(GPSLabMapLinkResolverResult *r) { leftAllowlist = r; }];
        [mock completeWithFinalURL:[NSURL URLWithString:@"https://evil.com/maps/@1,2"]
                        statusCode:200
                             error:nil];
        CHECK(leftAllowlist.error == GPSLabMapLinkResolverErrorUntrusted,
              @"final URL off the allowlist is rejected");

        // 8) Transport policy seams (no network).
        NSURLSessionConfiguration *config = [GPSLabMapLinkURLSessionTransport hardenedSessionConfiguration];
        CHECK(config.HTTPShouldSetCookies == NO, @"transport disables cookies");
        CHECK(config.HTTPCookieStorage == nil, @"transport has no cookie storage");
        CHECK(config.URLCache == nil, @"transport has no URL cache");
        CHECK(config.URLCredentialStorage == nil, @"transport has no credential storage");
        CHECK(config.HTTPAdditionalHeaders == nil, @"transport sends no custom headers");
        CHECK(config.requestCachePolicy == NSURLRequestReloadIgnoringLocalCacheData,
              @"transport ignores the local cache");

        NSURLRequest *clean = [GPSLabMapLinkURLSessionTransport sanitizedRedirectRequestForTarget:
            [NSURL URLWithString:@"https://www.google.com/maps/@1,2"]];
        CHECK([clean.HTTPMethod isEqualToString:@"GET"], @"sanitized redirect is a GET");
        CHECK([clean valueForHTTPHeaderField:@"Authorization"] == nil, @"no auth header carried");
        CHECK([clean valueForHTTPHeaderField:@"Cookie"] == nil, @"no cookie header carried");
        CHECK(clean.HTTPBody == nil, @"no body carried");

        CHECK([GPSLabMapLinkURLSessionTransport dispositionForAuthenticationMethod:NSURLAuthenticationMethodServerTrust]
                  == NSURLSessionAuthChallengePerformDefaultHandling,
              @"server trust uses default handling");
        CHECK([GPSLabMapLinkURLSessionTransport dispositionForAuthenticationMethod:NSURLAuthenticationMethodHTTPBasic]
                  == NSURLSessionAuthChallengeCancelAuthenticationChallenge,
              @"HTTP basic auth is cancelled");
        CHECK([GPSLabMapLinkURLSessionTransport dispositionForAuthenticationMethod:NSURLAuthenticationMethodHTTPDigest]
                  == NSURLSessionAuthChallengeCancelAuthenticationChallenge,
              @"HTTP digest auth is cancelled");
        CHECK([GPSLabMapLinkURLSessionTransport dispositionForAuthenticationMethod:NSURLAuthenticationMethodNTLM]
                  == NSURLSessionAuthChallengeCancelAuthenticationChallenge,
              @"NTLM auth is cancelled");
        CHECK([GPSLabMapLinkURLSessionTransport dispositionForAuthenticationMethod:NSURLAuthenticationMethodClientCertificate]
                  == NSURLSessionAuthChallengeCancelAuthenticationChallenge,
              @"client-certificate auth is cancelled");

        CHECK([GPSLabMapLinkURLSessionTransport shouldFollowRedirectToURLString:@"https://www.google.com/maps"
                                                                     atHopIndex:0],
              @"trusted redirect allowed");
        CHECK(![GPSLabMapLinkURLSessionTransport shouldFollowRedirectToURLString:@"https://goo.gl/maps"
                                                                      atHopIndex:0],
              @"plain goo.gl redirect rejected");
        CHECK(![GPSLabMapLinkURLSessionTransport shouldFollowRedirectToURLString:@"http://maps.apple.com"
                                                                      atHopIndex:0],
              @"non-https redirect rejected");
        CHECK(![GPSLabMapLinkURLSessionTransport shouldFollowRedirectToURLString:@"https://www.google.com/maps"
                                                                      atHopIndex:GPSLAB_MAP_LINK_MAX_REDIRECTS],
              @"redirect beyond the cap rejected");

        CHECK([GPSLabMapLinkURLSessionTransport responseHeadersAcceptableCount:10 bytes:100],
              @"small header set accepted");
        CHECK(![GPSLabMapLinkURLSessionTransport responseHeadersAcceptableCount:1000 bytes:100],
              @"oversized header count rejected");
        CHECK(![GPSLabMapLinkURLSessionTransport responseHeadersAcceptableCount:1 bytes:1000000],
              @"oversized header bytes rejected");

        // 9) Delegate-driven redirect regression (the REAL per-request delegate,
        //    no network): an untrusted redirect must finish deterministically,
        //    exactly once, and a late callback after finishing must be ignored.
        //    nil session/task is intentional here (the delegate methods ignore them).
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnonnull"
        NSURLRequest *evil = [NSURLRequest requestWithURL:[NSURL URLWithString:@"https://evil.com/maps/@1,2"]];
        __block NSInteger completions = 0;
        __block NSURL *finalURL = nil;
        __block NSError *finalError = nil;
        GPSLabMapLinkURLSessionRequest *request =
            [[GPSLabMapLinkURLSessionRequest alloc] initForTestingWithCompletion:^(NSURL *u, NSInteger s, NSError *e) {
                (void)s;
                completions += 1;
                finalURL = u;
                finalError = e;
            }];
        __block BOOL handlerCalled = NO;
        __block NSURLRequest *followedRequest = nil;
        [request URLSession:nil
                       task:nil
 willPerformHTTPRedirection:nil
                 newRequest:evil
          completionHandler:^(NSURLRequest *r) {
              handlerCalled = YES;
              followedRequest = r;
          }];
        CHECK(handlerCalled && followedRequest == nil, @"untrusted redirect is not followed");
        CHECK(completions == 1, @"rejected redirect completes exactly once (deterministic)");
        CHECK(finalURL == nil && finalError != nil &&
              [finalError.domain isEqualToString:GPSLabMapLinkTransportErrorDomain] &&
              finalError.code == GPSLabMapLinkTransportErrorUntrustedRedirect,
              @"rejected redirect reports the untrusted error");
        // A late callback after finishing must not complete again.
        [request URLSession:nil
                       task:nil
 willPerformHTTPRedirection:nil
                 newRequest:evil
          completionHandler:^(NSURLRequest *r) { (void)r; }];
        CHECK(completions == 1, @"late callback after finish is ignored");

        // An allowed redirect is followed with a rebuilt clean GET and does not
        // complete until the session would.
        __block NSInteger completions2 = 0;
        GPSLabMapLinkURLSessionRequest *request2 =
            [[GPSLabMapLinkURLSessionRequest alloc] initForTestingWithCompletion:^(NSURL *u, NSInteger s, NSError *e) {
                (void)u; (void)s; (void)e;
                completions2 += 1;
            }];
        __block NSURLRequest *cleanRequest = nil;
        [request2 URLSession:nil
                        task:nil
  willPerformHTTPRedirection:nil
                  newRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"https://www.google.com/maps/@1,2"]]
           completionHandler:^(NSURLRequest *r) { cleanRequest = r; }];
        CHECK(cleanRequest != nil && [cleanRequest.HTTPMethod isEqualToString:@"GET"],
              @"allowed redirect is rebuilt as a clean GET");
        CHECK(completions2 == 0, @"allowed redirect does not complete yet");

        // Explicit cancel suppresses the completion (no hanging banner).
        __block NSInteger completions3 = 0;
        GPSLabMapLinkURLSessionRequest *request3 =
            [[GPSLabMapLinkURLSessionRequest alloc] initForTestingWithCompletion:^(NSURL *u, NSInteger s, NSError *e) {
                (void)u; (void)s; (void)e;
                completions3 += 1;
            }];
        [request3 cancel];
        [request3 URLSession:nil
                        task:nil
  willPerformHTTPRedirection:nil
                  newRequest:evil
           completionHandler:^(NSURLRequest *r) { (void)r; }];
        CHECK(completions3 == 0, @"cancelled request suppresses its completion");
#pragma clang diagnostic pop
    }

    if (gFailures == 0) {
        printf("GPSLabMapLinkResolverTests: %d checks passed\n", gChecks);
        return 0;
    }
    fprintf(stderr, "GPSLabMapLinkResolverTests: %d/%d checks failed\n", gFailures, gChecks);
    return 1;
}
