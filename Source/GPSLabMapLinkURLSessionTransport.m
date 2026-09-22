//
//  GPSLabMapLinkURLSessionTransport.m
//  GPSLab
//
//  Every request owns its own delegate object (and thus its own hop counter,
//  byte counter and completion), so callbacks from a cancelled or superseded
//  session can never touch a newer request. The delegate queue is the main
//  queue: all mutable state is serialized there and no network work blocks it.
//

#import "GPSLabMapLinkURLSessionTransport.h"

#import "GPSLabMapLinkCore.h"
#import "GPSLabMapLinkURLSessionTransportTesting.h"

NSErrorDomain const GPSLabMapLinkTransportErrorDomain = @"com.gpslab.maplink.transport";

static const NSTimeInterval kGPSLabMapLinkTransportTimeout = 10.0;
static const NSUInteger kGPSLabMapLinkTransportMaxBytes = 32u * 1024u;
static const NSUInteger kGPSLabMapLinkTransportMaxHeaderCount = 64u;
static const NSUInteger kGPSLabMapLinkTransportMaxHeaderBytes = 16u * 1024u;

static NSError *GPSLabMapLinkTransportError(GPSLabMapLinkTransportErrorCode code) {
    return [NSError errorWithDomain:GPSLabMapLinkTransportErrorDomain code:code userInfo:nil];
}

#pragma mark - Per-request delegate

@interface GPSLabMapLinkURLSessionRequest ()

- (instancetype)initWithURL:(NSURL *)url
                 completion:(GPSLabMapLinkTransportCompletion)completion;

- (void)start;
- (void)cancel;

@end

@implementation GPSLabMapLinkURLSessionRequest {
    NSURL *_url;
    GPSLabMapLinkTransportCompletion _completion;
    NSURLSession *_session;
    NSURLSessionDataTask *_task;
    BOOL _finished;
    NSInteger _hopIndex;
    BOOL _rejectedRedirect;
    NSUInteger _receivedBytes;
}

- (instancetype)initWithURL:(NSURL *)url
                 completion:(GPSLabMapLinkTransportCompletion)completion {
    self = [super init];
    if (self) {
        _url = url;
        _completion = [completion copy];
    }
    return self;
}

- (instancetype)initForTestingWithCompletion:(GPSLabMapLinkTransportCompletion)completion {
    self = [super init];
    if (self) {
        _completion = [completion copy];
    }
    return self;
}

- (void)start {
    NSURLSessionConfiguration *configuration =
        [GPSLabMapLinkURLSessionTransport hardenedSessionConfiguration];
    // The main queue is serial, so every delegate callback and all per-request
    // mutable state are serialized without any additional locking.
    NSOperationQueue *queue = [NSOperationQueue mainQueue];
    _session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:queue];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:_url];
    request.HTTPMethod = @"GET";
    request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    request.timeoutInterval = kGPSLabMapLinkTransportTimeout;
    _task = [_session dataTaskWithRequest:request];
    [_task resume];
}

- (void)cancel {
    // A cancelled request never invokes its completion.
    _finished = YES;
    [self invalidate];
}

- (void)invalidate {
    [_task cancel];
    _task = nil;
    [_session invalidateAndCancel];
    _session = nil;
}

- (void)finishWithURL:(nullable NSURL *)finalURL
           statusCode:(NSInteger)statusCode
                error:(nullable NSError *)error {
    if (_finished) {
        return;
    }
    _finished = YES;
    [self invalidate];
    GPSLabMapLinkTransportCompletion completion = _completion;
    _completion = nil;
    if (completion != nil) {
        completion(finalURL, statusCode, error);
    }
}

#pragma mark NSURLSessionDataDelegate (main queue)

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
willPerformHTTPRedirection:(NSHTTPURLResponse *)response
        newRequest:(NSURLRequest *)request
 completionHandler:(void (^)(NSURLRequest * _Nullable))completionHandler {
    (void)session;
    (void)task;
    (void)response;
    if (_finished) {
        completionHandler(nil);
        return;
    }
    NSString *target = request.URL.absoluteString;
    if ([GPSLabMapLinkURLSessionTransport shouldFollowRedirectToURLString:target atHopIndex:_hopIndex]) {
        _hopIndex += 1;
        // Follow a freshly rebuilt GET so no auth/cookie/body header is carried over.
        NSURLRequest *clean = [GPSLabMapLinkURLSessionTransport sanitizedRedirectRequestForTarget:request.URL];
        completionHandler(clean);
    } else {
        // Deterministically terminate NOW: do not rely on didReceiveResponse /
        // didCompleteWithError timing. finishWithURL: is idempotent (exactly-once).
        _rejectedRedirect = YES;
        completionHandler(nil);
        [self finishWithURL:nil
                 statusCode:0
                      error:GPSLabMapLinkTransportError(GPSLabMapLinkTransportErrorUntrustedRedirect)];
    }
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    (void)session;
    if (_finished) {
        completionHandler(NSURLSessionResponseCancel);
        return;
    }

    NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]]
        ? ((NSHTTPURLResponse *)response).statusCode
        : 0;
    NSURL *finalURL = response.URL ?: dataTask.currentRequest.URL ?: dataTask.originalRequest.URL;
    BOOL rejected = _rejectedRedirect;

    NSUInteger headerCount = 0;
    NSUInteger headerBytes = 0;
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSDictionary *headers = ((NSHTTPURLResponse *)response).allHeaderFields;
        headerCount = headers.count;
        for (id key in headers) {
            id value = headers[key];
            headerBytes += [key isKindOfClass:[NSString class]] ? [key lengthOfBytesUsingEncoding:NSUTF8StringEncoding] : 0;
            headerBytes += [value isKindOfClass:[NSString class]] ? [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding] : 0;
        }
    }
    BOOL headersOk = [GPSLabMapLinkURLSessionTransport responseHeadersAcceptableCount:headerCount bytes:headerBytes];

    // Never read the body: cancel on headers.
    completionHandler(NSURLSessionResponseCancel);
    [dataTask cancel];

    if (rejected) {
        [self finishWithURL:nil statusCode:0 error:GPSLabMapLinkTransportError(GPSLabMapLinkTransportErrorUntrustedRedirect)];
        return;
    }
    if (!headersOk) {
        [self finishWithURL:nil statusCode:0 error:GPSLabMapLinkTransportError(GPSLabMapLinkTransportErrorOversize)];
        return;
    }
    if (status < 200 || status >= 300) {
        [self finishWithURL:finalURL statusCode:status error:GPSLabMapLinkTransportError(GPSLabMapLinkTransportErrorBadStatus)];
        return;
    }
    [self finishWithURL:finalURL statusCode:status error:nil];
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
    (void)session;
    if (_finished) {
        return;
    }
    _receivedBytes += data.length;
    if (_receivedBytes > kGPSLabMapLinkTransportMaxBytes) {
        [dataTask cancel];
        [self finishWithURL:nil statusCode:0 error:GPSLabMapLinkTransportError(GPSLabMapLinkTransportErrorOversize)];
    }
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(nullable NSError *)error {
    (void)session;
    (void)task;
    if (_finished) {
        return;
    }
    if (error == nil) {
        // A response should have completed the request; treat a bare completion as failure.
        [self finishWithURL:nil statusCode:0 error:GPSLabMapLinkTransportError(GPSLabMapLinkTransportErrorBadStatus)];
        return;
    }
    if (error.code == NSURLErrorCancelled) {
        return; // intentional cancel (headers/cancel/cap)
    }
    [self finishWithURL:nil statusCode:0 error:error];
}

- (void)URLSession:(NSURLSession *)session
didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential * _Nullable))completionHandler {
    (void)session;
    NSURLSessionAuthChallengeDisposition disposition =
        [GPSLabMapLinkURLSessionTransport dispositionForAuthenticationMethod:challenge.protectionSpace.authenticationMethod];
    // Default handling only ever applies to server trust; no credential is supplied.
    completionHandler(disposition, nil);
}

// Task-level challenges carry HTTP Basic/Digest/NTLM. The same server-trust-only
// rule applies: anything that is not server trust is cancelled, never answered
// with a credential.
- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential * _Nullable))completionHandler {
    (void)session;
    (void)task;
    NSURLSessionAuthChallengeDisposition disposition =
        [GPSLabMapLinkURLSessionTransport dispositionForAuthenticationMethod:challenge.protectionSpace.authenticationMethod];
    completionHandler(disposition, nil);
}

@end

#pragma mark - Transport

@implementation GPSLabMapLinkURLSessionTransport

+ (instancetype)sharedTransport {
    static GPSLabMapLinkURLSessionTransport *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[GPSLabMapLinkURLSessionTransport alloc] init];
    });
    return instance;
}

- (id)performRequestWithURL:(NSURL *)url completion:(GPSLabMapLinkTransportCompletion)completion {
    GPSLabMapLinkURLSessionRequest *request =
        [[GPSLabMapLinkURLSessionRequest alloc] initWithURL:url completion:completion];
    [request start];
    return request;
}

- (void)cancelRequest:(nullable id)requestToken {
    if ([requestToken isKindOfClass:[GPSLabMapLinkURLSessionRequest class]]) {
        [(GPSLabMapLinkURLSessionRequest *)requestToken cancel];
    }
}

#pragma mark - Test seams

+ (NSURLSessionConfiguration *)hardenedSessionConfiguration {
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    configuration.HTTPShouldSetCookies = NO;
    configuration.HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyNever;
    configuration.HTTPCookieStorage = nil;
    configuration.URLCache = nil;
    configuration.URLCredentialStorage = nil;
    configuration.HTTPAdditionalHeaders = nil;
    configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    configuration.timeoutIntervalForRequest = kGPSLabMapLinkTransportTimeout;
    configuration.timeoutIntervalForResource = kGPSLabMapLinkTransportTimeout;
    return configuration;
}

+ (NSURLRequest *)sanitizedRedirectRequestForTarget:(NSURL *)target {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:target];
    request.HTTPMethod = @"GET";
    request.HTTPBody = nil;
    [request setValue:nil forHTTPHeaderField:@"Authorization"];
    [request setValue:nil forHTTPHeaderField:@"Cookie"];
    request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    request.timeoutInterval = kGPSLabMapLinkTransportTimeout;
    return request;
}

+ (NSURLSessionAuthChallengeDisposition)dispositionForAuthenticationMethod:(nullable NSString *)method {
    if ([method isEqualToString:NSURLAuthenticationMethodServerTrust]) {
        return NSURLSessionAuthChallengePerformDefaultHandling;
    }
    return NSURLSessionAuthChallengeCancelAuthenticationChallenge;
}

+ (BOOL)shouldFollowRedirectToURLString:(nullable NSString *)urlString atHopIndex:(NSInteger)hopIndex {
    NSString *value = urlString ?: @"";
    const char *bytes = value.UTF8String;
    size_t length = [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    return GPSLabMapLinkRedirectAllowed((int)hopIndex, GPSLAB_MAP_LINK_MAX_REDIRECTS, bytes, length) ? YES : NO;
}

+ (BOOL)responseHeadersAcceptableCount:(NSUInteger)headerCount bytes:(NSUInteger)headerBytes {
    return (headerCount <= kGPSLabMapLinkTransportMaxHeaderCount &&
            headerBytes <= kGPSLabMapLinkTransportMaxHeaderBytes) ? YES : NO;
}

@end
