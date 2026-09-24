//
//  GPSLabDevicePairing.m
//  GPSLab
//
//  Hardened device-proof client for pairing and feedback. See the header for the
//  security contract. No secrets, tokens or messages are ever logged.
//

#import "GPSLabDevicePairing.h"

#import "GPSLabLicenseConfig.h"
#import "GPSLabLocalization.h"
#import "GPSLabPortalPolicy.h"
#import "GPSLabSecureStore.h"

@interface GPSLabDevicePairing () <NSURLSessionDataDelegate>
@end

@implementation GPSLabDevicePairing {
    dispatch_queue_t _queue;

    NSURLSession *_session;
    NSOperationQueue *_delegateQueue;

    NSURLSessionDataTask *_task;
    NSMutableData *_buffer;
    NSInteger _status;
    BOOL _overflow;
    BOOL _pairingRequest;

    void (^_completion)(GPSLabDeviceRequestResult, NSString *, NSString *);
}

+ (instancetype)sharedClient {
    static GPSLabDevicePairing *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[GPSLabDevicePairing alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("com.gpslab.runtime.device", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (GPSLabLicenseConfig *)config {
    return [GPSLabLicenseConfig sharedConfig];
}

- (BOOL)isConfigured {
    return [self config].pairingEndpoint != nil &&
           [[GPSLabSecureStore sharedStore] deviceSecretBase64].length > 0;
}

#pragma mark - Testable payload builders

+ (NSData *)pairingRequestBodyForInstallation:(NSString *)installationId
                                 deviceSecret:(NSString *)deviceSecret {
    if (installationId.length == 0 || deviceSecret.length == 0) {
        return nil;
    }
    NSDictionary *body = @{
        @"installationId": installationId,
        @"deviceSecret": deviceSecret,
    };
    return [NSJSONSerialization dataWithJSONObject:body options:0 error:NULL];
}

+ (NSData *)feedbackRequestBodyForInstallation:(NSString *)installationId
                                  deviceSecret:(NSString *)deviceSecret
                                      category:(NSString *)category
                                       message:(NSString *)message {
    if (installationId.length == 0 || deviceSecret.length == 0) {
        return nil;
    }
    if (category.length == 0 || !GPSLabPortalFeedbackCategoryIsValid(category.UTF8String)) {
        return nil;
    }
    char bounded[GPSLAB_PORTAL_MAX_FEEDBACK_BYTES + 1];
    size_t written = GPSLabPortalBoundFeedback(message.UTF8String, bounded, sizeof(bounded));
    if (written == 0) {
        return nil;
    }
    NSString *trimmed = [NSString stringWithUTF8String:bounded];
    if (trimmed.length == 0) {
        return nil;
    }
    NSDictionary *body = @{
        @"installationId": installationId,
        @"deviceSecret": deviceSecret,
        @"category": category,
        @"message": trimmed,
    };
    return [NSJSONSerialization dataWithJSONObject:body options:0 error:NULL];
}

#pragma mark - Session (device queue)

- (void)onQueueEnsureSession {
    if (_session != nil) {
        return;
    }
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    configuration.timeoutIntervalForRequest = [self config].requestTimeoutSeconds;
    configuration.timeoutIntervalForResource = [self config].resourceTimeoutSeconds;
    configuration.waitsForConnectivity = NO;
    configuration.HTTPAdditionalHeaders = @{@"Accept": @"application/json"};

    NSOperationQueue *delegateQueue = [[NSOperationQueue alloc] init];
    delegateQueue.maxConcurrentOperationCount = 1;
    delegateQueue.underlyingQueue = _queue;
    _delegateQueue = delegateQueue;
    _session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:delegateQueue];
}

#pragma mark - Public API

- (void)requestPairingCodeWithCompletion:
    (void (^)(GPSLabDeviceRequestResult, NSString *, NSString *))completion {
    dispatch_async(_queue, ^{
        NSData *body = [GPSLabDevicePairing pairingRequestBodyForInstallation:
                            [[GPSLabSecureStore sharedStore] installationUUID] ?: @""
                                                                deviceSecret:[[GPSLabSecureStore sharedStore] deviceSecretBase64]];
        [self onQueueBeginRequestWithURL:[self config].pairingEndpoint
                                    body:body
                                 pairing:YES
                              completion:completion];
    });
}

- (void)submitFeedbackWithCategory:(NSString *)category
                           message:(NSString *)message
                        completion:(void (^)(GPSLabDeviceRequestResult, NSString *))completion {
    NSString *safeCategory = [category copy] ?: @"";
    NSString *safeMessage = [message copy] ?: @"";
    dispatch_async(_queue, ^{
        NSData *body = [GPSLabDevicePairing feedbackRequestBodyForInstallation:
                            [[GPSLabSecureStore sharedStore] installationUUID] ?: @""
                                                                deviceSecret:[[GPSLabSecureStore sharedStore] deviceSecretBase64]
                                                                    category:safeCategory
                                                                     message:safeMessage];
        [self onQueueBeginRequestWithURL:[self config].feedbackEndpoint
                                    body:body
                                 pairing:NO
                              completion:^(GPSLabDeviceRequestResult result, NSString *code, NSString *text) {
            (void)code;
            if (completion != nil) {
                completion(result, text ?: @"");
            }
        }];
    });
}

#pragma mark - Request lifecycle (device queue)

- (void)onQueueBeginRequestWithURL:(NSURL *)url
                              body:(NSData *)body
                           pairing:(BOOL)pairing
                        completion:(void (^)(GPSLabDeviceRequestResult, NSString *, NSString *))completion {
    NSString *origin = [self config].endpointOrigin;
    BOOL endpointSafe = (url != nil && origin.length > 0 &&
                         GPSLabPortalURLIsSafe(url.absoluteString.UTF8String, origin.UTF8String));
    if (!endpointSafe) {
        [self onQueueFinishWithResult:GPSLabDeviceRequestResultUnconfigured
                                 code:nil
                              message:GPSLabLocalized(@"portal.error.unavailable")
                           completion:completion];
        return;
    }
    if (body.length == 0) {
        [self onQueueFinishWithResult:GPSLabDeviceRequestResultInvalidInput
                                 code:nil
                              message:pairing ? GPSLabLocalized(@"portal.error.unavailable")
                                              : GPSLabLocalized(@"portal.feedback.invalid")
                           completion:completion];
        return;
    }

    [self onQueueCancelCurrentTask];
    [self onQueueEnsureSession];

    _pairingRequest = pairing;
    _completion = completion != nil ? [completion copy] : nil;

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.HTTPBody = body;
    request.timeoutInterval = [self config].requestTimeoutSeconds;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"no-store" forHTTPHeaderField:@"Cache-Control"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];

    _buffer = [NSMutableData data];
    _status = 0;
    _overflow = NO;
    NSURLSessionDataTask *task = [_session dataTaskWithRequest:request];
    _task = task;
    [task resume];
}

- (void)onQueueCancelCurrentTask {
    if (_task != nil) {
        [_task cancel];
        _task = nil;
    }
    _buffer = nil;
    _overflow = NO;
    _completion = nil;
}

- (void)onQueueFinishWithResult:(GPSLabDeviceRequestResult)result
                           code:(NSString *)code
                        message:(NSString *)message
                     completion:(void (^)(GPSLabDeviceRequestResult, NSString *, NSString *))block {
    if (block == nil) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        block(result, code, message);
    });
}

- (void)onQueueCompleteWithData:(NSData *)data
                         status:(NSInteger)status
                        offline:(BOOL)offline
                       overflow:(BOOL)overflow {
    void (^completion)(GPSLabDeviceRequestResult, NSString *, NSString *) = _completion;
    _completion = nil;
    if (completion == nil) {
        return;
    }

    // Accept every HTTP 2xx: pairing answers 200, feedback answers 201 Created.
    // The pairing branch below still rejects a 2xx response that carries no
    // usable code, so an empty/unparseable body can never count as success there.
    BOOL transportOK = (!offline && GPSLabPortalStatusIsSuccess((int)status) && !overflow);
    if (!transportOK) {
        GPSLabDeviceRequestResult result = offline
            ? GPSLabDeviceRequestResultOffline
            : GPSLabDeviceRequestResultRejected;
        NSString *message = offline
            ? GPSLabLocalized(@"portal.error.offline")
            : GPSLabLocalized(_pairingRequest ? @"portal.pair.rejected" : @"portal.feedback.rejected");
        [self onQueueFinishWithResult:result code:nil message:message completion:completion];
        return;
    }

    if (_pairingRequest) {
        id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        NSString *code = nil;
        if ([object isKindOfClass:[NSDictionary class]]) {
            id value = ((NSDictionary *)object)[@"code"];
            if ([value isKindOfClass:[NSString class]]) {
                code = value;
            }
        }
        if (code == nil || !GPSLabPortalPairingCodeIsSafe(code.UTF8String)) {
            [self onQueueFinishWithResult:GPSLabDeviceRequestResultRejected
                                     code:nil
                                  message:GPSLabLocalized(@"portal.pair.rejected")
                               completion:completion];
            return;
        }
        [self onQueueFinishWithResult:GPSLabDeviceRequestResultSuccess
                                 code:code
                              message:GPSLabLocalized(@"portal.pair.success")
                           completion:completion];
        return;
    }

    [self onQueueFinishWithResult:GPSLabDeviceRequestResultSuccess
                             code:nil
                          message:GPSLabLocalized(@"portal.feedback.sent")
                       completion:completion];
}

#pragma mark - NSURLSessionDataDelegate

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
 willPerformHTTPRedirection:(NSHTTPURLResponse *)response
        newRequest:(NSURLRequest *)request
 completionHandler:(void (^)(NSURLRequest * _Nullable))completionHandler {
    // A device proof must never be forwarded to another host/scheme.
    (void)session;
    (void)task;
    (void)response;
    (void)request;
    completionHandler(nil);
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    (void)session;
    if (dataTask == _task && [response isKindOfClass:[NSHTTPURLResponse class]]) {
        _status = ((NSHTTPURLResponse *)response).statusCode;
    }
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
    (void)session;
    if (dataTask != _task) {
        return;
    }
    [_buffer appendData:data];
    if (_buffer.length > [self config].maxResponseBytes) {
        _overflow = YES;
        [dataTask cancel];
    }
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    (void)session;
    if (task != _task) {
        return;
    }
    NSData *data = [_buffer copy] ?: [NSData data];
    NSInteger status = _status;
    BOOL overflow = _overflow;

    _task = nil;
    _buffer = nil;
    _overflow = NO;

    // Map only a genuine wait-for-connectivity / timeout cancellation to Offline;
    // any other cancellation (e.g. our own overflow cap) must resolve Rejected.
    BOOL offline = (error != nil &&
                    ([error.domain isEqualToString:NSURLErrorDomain] &&
                     (error.code == NSURLErrorTimedOut ||
                      error.code == NSURLErrorCannotConnectToHost ||
                      error.code == NSURLErrorNetworkConnectionLost ||
                      error.code == NSURLErrorNotConnectedToInternet ||
                      error.code == NSURLErrorCannotFindHost)));

    [self onQueueCompleteWithData:data
                           status:status
                          offline:offline
                         overflow:overflow];
}

@end
