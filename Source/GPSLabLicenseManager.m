//
//  GPSLabLicenseManager.m
//  GPSLab
//
//  Fail-closed entitlement coordinator.
//
//  Concurrency model (explicit):
//    * A dedicated serial queue (`_licenseQueue`) owns every Keychain access, crypto
//      verification, JSON parse and network callback. `loadAndStart` returns
//      immediately; nothing blocks the caller or the dylib constructor.
//    * The engine gate, published state, deadline timer and notifications are
//      main-thread only (`mainApplyState:` asserts main). The engine defaults to
//      locked until an async result is published.
//    * Results carry a monotonically increasing revision, so a slow earlier result can
//      never overwrite a newer one.
//    * Public refresh/activate/restore/foreground calls all serialize on the license
//      queue; only one HTTP task is in flight (superseded tasks are cancelled).
//

#import "GPSLabLicenseManager.h"

#import <UIKit/UIKit.h>
#import <os/lock.h>

#import "Diagnostics.h"
#import "GPSLabEngine.h"
#import "GPSLabLicenseConfig.h"
#import "GPSLabLicensePolicy.h"
#import "GPSLabSecureStore.h"
#import "GPSLabTokenVerifier.h"

NSNotificationName const GPSLabLicenseStateDidChangeNotification = @"com.gpslab.license.state";

static const NSUInteger kGPSLabMaxMetaBytes = 4096;
static const long long kGPSLabDeadlineChunkSeconds = 3600; // re-check at most hourly

@interface GPSLabLicenseManager () <NSURLSessionDataDelegate>
@end

@implementation GPSLabLicenseManager {
    dispatch_queue_t _licenseQueue;

    // Published state (guarded by _lock, mutated only on main).
    os_unfair_lock _lock;
    GPSLabEntitlementState _state;
    GPSLabEntitlement *_entitlement;
    NSUInteger _lastAppliedRevision;

    // License-queue-owned state.
    GPSLabLicenseClaims *_claims;
    GPSLabLicenseAuthStatus _authStatus;
    BOOL _hasVerifiedToken;
    BOOL _claimsFromCache;
    BOOL _loadStarted;
    BOOL _requestInFlight;
    GPSLabLicenseClock _clock;
    NSUInteger _requestGeneration;
    NSUInteger _applyRevision;

    NSURLSession *_session;
    NSOperationQueue *_delegateQueue;
    NSURLSessionDataTask *_currentTask;
    NSMutableData *_responseBuffer;
    NSInteger _responseStatusCode;
    BOOL _responseOverflow;
    NSUInteger _inflightGeneration;
    void (^_inflightCompletion)(GPSLabEntitlementState, NSString *);

    dispatch_source_t _deadlineTimer;
    BOOL _observing;
}

+ (instancetype)sharedManager {
    static GPSLabLicenseManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[GPSLabLicenseManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _state = GPSLabEntitlementStateUnknown;
        _authStatus = GPSLabLicenseAuthStatusNone;
        _licenseQueue = dispatch_queue_create("com.gpslab.runtime.license", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

#pragma mark - Small helpers

- (GPSLabLicenseConfig *)config {
    return [GPSLabLicenseConfig sharedConfig];
}

- (long long)wallNow {
    return (long long)[NSDate date].timeIntervalSince1970;
}

- (long long)uptimeNow {
    return (long long)[NSProcessInfo processInfo].systemUptime;
}

- (long long)graceCap {
    NSTimeInterval cap = [self config].maxOfflineGraceSeconds;
    if (cap < 0.0) {
        return 0;
    }
    return (long long)cap;
}

- (long long)skewCap {
    return (long long)[self config].maxClockSkewSeconds;
}

#pragma mark - Public state (thread-safe reads)

- (GPSLabEntitlementState)state {
    os_unfair_lock_lock(&_lock);
    GPSLabEntitlementState state = _state;
    os_unfair_lock_unlock(&_lock);
    return state;
}

- (GPSLabEntitlement *)currentEntitlement {
    os_unfair_lock_lock(&_lock);
    GPSLabEntitlement *entitlement = [_entitlement copy];
    os_unfair_lock_unlock(&_lock);
    if (entitlement != nil) {
        entitlement.state = [self state];
    }
    return entitlement;
}

- (BOOL)isUnlocked {
    return GPSLabLicenseStateIsUnlocked([self state]) != 0;
}

- (BOOL)isServiceConfigured {
    return [self config].isConfigured;
}

- (NSString *)nonTechnicalServiceStatus {
    return [self messageForState:[self state] configured:[self isServiceConfigured]];
}

- (NSString *)messageForState:(GPSLabEntitlementState)state configured:(BOOL)configured {
    switch (state) {
        case GPSLabEntitlementStateActive:
        case GPSLabEntitlementStateGrace:
            return @"Subscription active.";
        case GPSLabEntitlementStateChecking:
            return @"Checking your subscription...";
        case GPSLabEntitlementStateExpired:
            return @"Your subscription has expired. Renew to continue.";
        case GPSLabEntitlementStateInvalid:
            return @"This subscription is not valid on this device.";
        case GPSLabEntitlementStateOffline:
            return configured
                ? @"Can't reach the subscription service. Check your connection and try again."
                : @"Subscription is not available in this build.";
        case GPSLabEntitlementStateUnknown:
            return configured ? @"Subscription status unknown. Try again."
                              : @"Subscription is not available in this build.";
    }
    return @"Subscription unavailable.";
}

#pragma mark - Main-thread state application (engine gate + UI)

- (void)mainApplyState:(GPSLabEntitlementState)state
           entitlement:(GPSLabEntitlement *)entitlement
              revision:(NSUInteger)revision {
    NSAssert([NSThread isMainThread], @"license state must be applied on the main thread");
    if (revision <= _lastAppliedRevision) {
        return; // a newer result already won
    }
    _lastAppliedRevision = revision;

    os_unfair_lock_lock(&_lock);
    BOOL changed = (_state != state);
    _state = state;
    _entitlement = [entitlement copy];
    if (_entitlement != nil) {
        _entitlement.state = state;
    }
    os_unfair_lock_unlock(&_lock);

    [[GPSLabEngine sharedEngine] setEntitlementAllowsSynthesis:GPSLabLicenseStateIsUnlocked(state) != 0];
    [self scheduleDeadlineForState:state];

    if (changed) {
        GPSLabDiagLicenseStateChanged((NSInteger)state);
        [[NSNotificationCenter defaultCenter] postNotificationName:GPSLabLicenseStateDidChangeNotification
                                                            object:self];
    }
}

#pragma mark - Load / start (async, non-blocking)

- (void)loadAndStart {
    dispatch_async(_licenseQueue, ^{
        if (self->_loadStarted) {
            return;
        }
        self->_loadStarted = YES;
        [self onQueueEnsureSession];
        [self onQueueLoadCache];
        [self onQueueObserveClock];

        if ([self config].isConfigured) {
            [self onQueueStartRequestWithActivationCode:nil completion:nil];
        } else {
            [self onQueuePublishResolvedState];
            [self onQueuePersistMeta];
        }
    });
    [self observeApplicationLifecycle];
}

- (void)onQueueLoadCache {
    (void)[[GPSLabSecureStore sharedStore] installationUUID];
    [self onQueueLoadMeta];

    BOOL configured = [self config].isConfigured;
    NSData *envelope = [[GPSLabSecureStore sharedStore] tokenEnvelope];
    if (!configured) {
        // Service unavailable: keep an authenticated revoked/expired status, but do not
        // invent Invalid from an orphan token we cannot verify.
        if (_authStatus != GPSLabLicenseAuthStatusRevoked &&
            _authStatus != GPSLabLicenseAuthStatusExpired) {
            _authStatus = GPSLabLicenseAuthStatusNone;
        }
        _hasVerifiedToken = NO;
        _claims = nil;
        _claimsFromCache = NO;
        return;
    }

    if (envelope.length == 0) {
        return; // authStatus (if any) still drives the resolved state
    }

    GPSLabLicenseConfig *config = [self config];
    NSError *verifyError = nil;
    GPSLabLicenseClaims *claims = [GPSLabTokenVerifier verifyEnvelopeData:envelope
                                                               publicKey:config.publicKey
                                                    expectedInstallation:[[GPSLabSecureStore sharedStore] installationUUID]
                                                                  issuer:config.issuer
                                                                audience:config.audience
                                                         maxPayloadBytes:config.maxResponseBytes
                                                        maxEnvelopeBytes:config.maxEnvelopeBytes
                                                                   error:&verifyError];
    long long now = [self onQueueEffectiveNow];
    if (claims == nil ||
        !GPSLabLicenseIssuedAtAcceptable(claims.issuedAt, now, [self skewCap])) {
        // A present-but-untrusted token is Invalid (distinct from Offline), never used.
        _authStatus = GPSLabLicenseAuthStatusInvalid;
        _hasVerifiedToken = NO;
        _claims = nil;
        _claimsFromCache = NO;
        [[GPSLabSecureStore sharedStore] clearLicenseMaterial];
        [self onQueuePersistMeta];
        return;
    }

    _claims = claims;
    _hasVerifiedToken = YES;
    _claimsFromCache = YES;
    _authStatus = [self authStatusForClaims:claims];
}

- (GPSLabLicenseAuthStatus)authStatusForClaims:(GPSLabLicenseClaims *)claims {
    if ([claims.status isEqualToString:@"revoked"]) {
        return GPSLabLicenseAuthStatusRevoked;
    }
    if ([claims.status isEqualToString:@"expired"]) {
        return GPSLabLicenseAuthStatusExpired;
    }
    if ([claims.status isEqualToString:@"grace"]) {
        return GPSLabLicenseAuthStatusGrace;
    }
    return GPSLabLicenseAuthStatusActive;
}

#pragma mark - Clock + metadata (license queue)

- (long long)onQueueEffectiveNow {
    return GPSLabLicenseEffectiveNow([self wallNow], [self uptimeNow], &_clock, NULL);
}

- (void)onQueueObserveClock {
    (void)[self onQueueEffectiveNow];
}

- (BOOL)onQueueReadMetaInteger:(NSDictionary *)meta key:(NSString *)key allowZero:(BOOL)allowZero out:(long long *)outValue {
    id value = meta[key];
    if (![value isKindOfClass:[NSNumber class]]) {
        return NO;
    }
    const char *type = [(NSNumber *)value objCType];
    if (type == NULL || type[0] == 'c' || type[0] == 'C' || type[0] == 'B' ||
        type[0] == 'f' || type[0] == 'd') {
        return NO;
    }
    long long number = [(NSNumber *)value longLongValue];
    if (allowZero) {
        if (number < 0 || number > GPSLAB_LICENSE_MAX_TIMESTAMP) {
            return NO;
        }
    } else if (!GPSLabLicenseIsSaneTimestamp(number)) {
        return NO;
    }
    if (outValue != NULL) {
        *outValue = number;
    }
    return YES;
}

- (void)onQueueLoadMeta {
    NSData *metaData = [[GPSLabSecureStore sharedStore] entitlementMeta];
    if (metaData.length == 0 || metaData.length > kGPSLabMaxMetaBytes) {
        return;
    }
    id object = [NSJSONSerialization JSONObjectWithData:metaData options:0 error:NULL];
    if (![object isKindOfClass:[NSDictionary class]]) {
        return;
    }
    NSDictionary *meta = object;

    long long version = 0;
    if (![self onQueueReadMetaInteger:meta key:@"v" allowZero:NO out:&version] || version != 1) {
        return;
    }

    long long value = 0;
    if ([self onQueueReadMetaInteger:meta key:@"lastSeenWall" allowZero:YES out:&value]) {
        _clock.lastSeenWall = value;
    }
    if ([self onQueueReadMetaInteger:meta key:@"lastSeenUptime" allowZero:YES out:&value]) {
        _clock.lastSeenUptime = value;
    }
    if ([self onQueueReadMetaInteger:meta key:@"verifiedAtWall" allowZero:YES out:&value]) {
        _clock.verifiedAtWall = value;
    }
    if ([self onQueueReadMetaInteger:meta key:@"verifiedAtUptime" allowZero:YES out:&value]) {
        _clock.verifiedAtUptime = value;
    }
    if ([self onQueueReadMetaInteger:meta key:@"authStatus" allowZero:YES out:&value]) {
        if (value >= GPSLabLicenseAuthStatusNone && value <= GPSLabLicenseAuthStatusInvalid) {
            _authStatus = (GPSLabLicenseAuthStatus)value;
        }
    }
}

- (NSData *)onQueueMetaData {
    NSDictionary *meta = @{
        @"v": @1,
        @"lastSeenWall": @(_clock.lastSeenWall),
        @"lastSeenUptime": @(_clock.lastSeenUptime),
        @"verifiedAtWall": @(_clock.verifiedAtWall),
        @"verifiedAtUptime": @(_clock.verifiedAtUptime),
        @"authStatus": @((NSInteger)_authStatus),
    };
    return [NSJSONSerialization dataWithJSONObject:meta options:0 error:NULL];
}

- (void)onQueuePersistMeta {
    NSData *meta = [self onQueueMetaData];
    if (meta.length > 0) {
        [[GPSLabSecureStore sharedStore] storeEntitlementMeta:meta];
    }
}

#pragma mark - Resolution + publishing (license queue)

- (BOOL)onQueueIsUnlocked {
    return GPSLabLicenseStateIsUnlocked([self onQueueResolveCurrent]) != 0;
}

- (GPSLabEntitlementState)onQueueResolveCurrent {
    if (![self config].isConfigured) {
        return GPSLabEntitlementStateOffline;
    }
    if (_authStatus == GPSLabLicenseAuthStatusRevoked || _authStatus == GPSLabLicenseAuthStatusInvalid) {
        return GPSLabEntitlementStateInvalid;
    }
    if (_authStatus == GPSLabLicenseAuthStatusExpired) {
        return GPSLabEntitlementStateExpired;
    }
    if (!_hasVerifiedToken || _claims == nil) {
        return _requestInFlight ? GPSLabEntitlementStateChecking : GPSLabEntitlementStateOffline;
    }
    long long now = [self onQueueEffectiveNow];
    return GPSLabLicenseStateForTime(now, _claims.expiresAt, _claims.graceUntil, [self graceCap]);
}

- (GPSLabEntitlement *)onQueueEntitlementForPublish {
    if (_claims == nil) {
        return nil;
    }
    GPSLabEntitlement *entitlement = [[GPSLabEntitlement alloc] init];
    entitlement.entitlementId = _claims.entitlementId;
    entitlement.installationId = _claims.installationId;
    entitlement.plan = _claims.plan;
    entitlement.issuedAt = _claims.issuedAt;
    entitlement.expiresAt = _claims.expiresAt;
    entitlement.graceUntil = _claims.graceUntil;
    entitlement.lastVerifiedAt = [NSDate date];
    entitlement.fromCache = _claimsFromCache;
    return entitlement;
}

- (void)onQueuePublishResolvedState {
    GPSLabEntitlementState state = [self onQueueResolveCurrent];
    GPSLabEntitlement *entitlement = [self onQueueEntitlementForPublish];
    NSUInteger revision = ++_applyRevision;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self mainApplyState:state entitlement:entitlement revision:revision];
    });
}

- (void)onQueueFinishWithCompletion:(void (^)(GPSLabEntitlementState, NSString *))completion {
    GPSLabEntitlementState state = [self onQueueResolveCurrent];
    NSString *message = [self messageForState:state configured:[self config].isConfigured];
    if (completion != nil) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(state, message);
        });
    }
}

#pragma mark - Network (license queue; delegate callbacks run on the same queue)

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
    delegateQueue.underlyingQueue = _licenseQueue;
    _delegateQueue = delegateQueue;
    _session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:delegateQueue];
}

- (void)onQueueCancelCurrentTask {
    if (_currentTask != nil) {
        [_currentTask cancel];
        _currentTask = nil;
    }
    _responseBuffer = nil;
    _responseOverflow = NO;
    _inflightCompletion = nil;
    _requestInFlight = NO;
}

- (void)onQueueStartRequestWithActivationCode:(NSString *)activationCode
                                   completion:(void (^)(GPSLabEntitlementState, NSString *))completion {
    GPSLabLicenseConfig *config = [self config];
    if (!config.isConfigured) {
        [self onQueuePublishResolvedState];
        if (completion != nil) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(GPSLabEntitlementStateOffline, @"Subscription is not available in this build.");
            });
        }
        return;
    }

    // Serialize: cancel any superseded task and invalidate its responses.
    [self onQueueCancelCurrentTask];
    _requestGeneration += 1;
    NSUInteger generation = _requestGeneration;
    _inflightGeneration = generation;
    _inflightCompletion = completion != nil ? [completion copy] : nil;
    _requestInFlight = YES;

    [self onQueueObserveClock];

    NSMutableDictionary *body = [NSMutableDictionary dictionary];
    body[@"installationId"] = [[GPSLabSecureStore sharedStore] installationUUID] ?: @"";
    NSString *refreshToken = [[GPSLabSecureStore sharedStore] refreshToken];
    if (refreshToken.length > 0) {
        body[@"refreshToken"] = refreshToken;
    }
    if (activationCode.length > 0) {
        body[@"activationCode"] = activationCode;
    }
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body options:0 error:NULL];
    if (bodyData == nil) {
        [self onQueueHandleFailureWithCompletion:completion];
        return;
    }

    GPSLabDiagLicenseCheckStarted();
    [self onQueuePublishResolvedState];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:config.endpoint];
    request.HTTPMethod = @"POST";
    request.HTTPBody = bodyData;
    request.timeoutInterval = config.requestTimeoutSeconds;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"no-store" forHTTPHeaderField:@"Cache-Control"];

    _responseBuffer = [NSMutableData data];
    _responseStatusCode = 0;
    _responseOverflow = NO;
    NSURLSessionDataTask *task = [_session dataTaskWithRequest:request];
    _currentTask = task;
    [task resume];
    [self onQueuePersistMeta];
}

- (void)onQueueHandleFailureWithCompletion:(void (^)(GPSLabEntitlementState, NSString *))completion {
    _requestInFlight = NO;
    [self onQueueObserveClock];
    [self onQueuePublishResolvedState];
    [self onQueuePersistMeta];
    [self onQueueFinishWithCompletion:completion];
}

- (void)onQueueApplyVerifiedClaims:(GPSLabLicenseClaims *)claims envelope:(NSData *)envelope {
    [self onQueueObserveClock];
    _authStatus = [self authStatusForClaims:claims];

    if (_authStatus == GPSLabLicenseAuthStatusRevoked) {
        // Hard revocation: drop the token/refresh but remember the authenticated status
        // so a later offline failure still resolves Invalid, not Offline.
        [[GPSLabSecureStore sharedStore] clearLicenseMaterial];
        _hasVerifiedToken = NO;
        _claims = nil;
        _claimsFromCache = NO;
        _clock.verifiedAtWall = [self onQueueEffectiveNow];
        _clock.verifiedAtUptime = [self uptimeNow];
        [self onQueuePersistMeta];
        return;
    }

    _clock.verifiedAtWall = [self onQueueEffectiveNow];
    _clock.verifiedAtUptime = [self uptimeNow];
    _hasVerifiedToken = YES;
    _claims = claims;
    _claimsFromCache = NO;

    NSData *meta = [self onQueueMetaData];
    NSString *refreshToken = [self refreshTokenFromEnvelopeData:envelope];
    [[GPSLabSecureStore sharedStore] storeTokenEnvelope:envelope meta:meta refreshToken:refreshToken];
}

- (NSString *)refreshTokenFromEnvelopeData:(NSData *)envelopeData {
    id object = [NSJSONSerialization JSONObjectWithData:envelopeData options:0 error:NULL];
    if (![object isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    id token = ((NSDictionary *)object)[@"refreshToken"];
    return [token isKindOfClass:[NSString class]] ? token : nil;
}

- (void)onQueueHandleCompletedData:(NSData *)data
                            status:(NSInteger)status
                             error:(NSError *)error
                          overflow:(BOOL)overflow
                        completion:(void (^)(GPSLabEntitlementState, NSString *))completion {
    GPSLabLicenseConfig *config = [self config];
    BOOL transportOK = (error == nil && status == 200 && !overflow && data.length > 0 &&
                        data.length <= config.maxEnvelopeBytes);
    if (transportOK) {
        NSError *verifyError = nil;
        GPSLabLicenseClaims *claims = [GPSLabTokenVerifier verifyEnvelopeData:data
                                                                   publicKey:config.publicKey
                                                        expectedInstallation:[[GPSLabSecureStore sharedStore] installationUUID]
                                                                      issuer:config.issuer
                                                                    audience:config.audience
                                                             maxPayloadBytes:config.maxResponseBytes
                                                            maxEnvelopeBytes:config.maxEnvelopeBytes
                                                                       error:&verifyError];
        long long now = [self onQueueEffectiveNow];
        if (claims != nil && GPSLabLicenseIssuedAtAcceptable(claims.issuedAt, now, [self skewCap])) {
            [self onQueueApplyVerifiedClaims:claims envelope:data];
            _requestInFlight = NO;
            [self onQueuePublishResolvedState];
            [self onQueueFinishWithCompletion:completion];
            return;
        }
        // Unsigned/malformed/future-dated response: never revoke a valid cache.
    }
    [self onQueueHandleFailureWithCompletion:completion];
}

#pragma mark - NSURLSessionDataDelegate

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
willPerformHTTPRedirection:(NSHTTPURLResponse *)response
        newRequest:(NSURLRequest *)request
 completionHandler:(void (^)(NSURLRequest * _Nullable))completionHandler {
    // Never forward activation codes / refresh tokens to another host or scheme.
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
    if (dataTask == _currentTask && [response isKindOfClass:[NSHTTPURLResponse class]]) {
        _responseStatusCode = ((NSHTTPURLResponse *)response).statusCode;
    }
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
    (void)session;
    if (dataTask != _currentTask) {
        return;
    }
    [_responseBuffer appendData:data];
    if (_responseBuffer.length > [self config].maxResponseBytes) {
        // Cancel as soon as the cap is exceeded; do not buffer unbounded data.
        _responseOverflow = YES;
        [dataTask cancel];
    }
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    (void)session;
    if (task != _currentTask) {
        return; // superseded task
    }
    NSUInteger generation = _inflightGeneration;
    void (^completion)(GPSLabEntitlementState, NSString *) = _inflightCompletion;
    NSData *data = [_responseBuffer copy] ?: [NSData data];
    NSInteger status = _responseStatusCode;
    BOOL overflow = _responseOverflow;

    _currentTask = nil;
    _responseBuffer = nil;
    _inflightCompletion = nil;
    _responseOverflow = NO;

    if (generation != _requestGeneration) {
        return; // a newer request superseded this one
    }
    [self onQueueHandleCompletedData:data status:status error:error overflow:overflow completion:completion];
}

#pragma mark - Public API (serialized onto the license queue)

- (void)refreshWithCompletion:(void (^)(GPSLabEntitlementState))completion {
    dispatch_async(_licenseQueue, ^{
        [self onQueueStartRequestWithActivationCode:nil
                                         completion:^(GPSLabEntitlementState state, NSString *message) {
            (void)message;
            if (completion != nil) {
                completion(state);
            }
        }];
    });
}

- (void)activateWithCode:(NSString *)code
              completion:(void (^)(GPSLabEntitlementState, NSString *))completion {
    if (![self config].isConfigured) {
        if (completion != nil) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(GPSLabEntitlementStateOffline, @"Subscription is not available in this build.");
            });
        }
        return;
    }
    dispatch_async(_licenseQueue, ^{
        [self onQueueStartRequestWithActivationCode:code
                                         completion:^(GPSLabEntitlementState state, NSString *message) {
            if (completion == nil) {
                return;
            }
            if (GPSLabLicenseStateIsUnlocked(state)) {
                completion(state, @"Subscription activated.");
            } else {
                completion(state, message ?: @"Activation did not succeed.");
            }
        }];
    });
}

- (void)restoreWithCompletion:(void (^)(GPSLabEntitlementState, NSString *))completion {
    if (![self config].isConfigured) {
        if (completion != nil) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(GPSLabEntitlementStateOffline, @"Subscription is not available in this build.");
            });
        }
        return;
    }
    dispatch_async(_licenseQueue, ^{
        [self onQueueStartRequestWithActivationCode:nil
                                         completion:^(GPSLabEntitlementState state, NSString *message) {
            if (completion == nil) {
                return;
            }
            if (GPSLabLicenseStateIsUnlocked(state)) {
                completion(state, @"Subscription restored.");
            } else {
                completion(state, message ?: @"Nothing could be restored for this device.");
            }
        }];
    });
}

- (void)reconcileOnForeground {
    dispatch_async(_licenseQueue, ^{
        [self onQueueObserveClock];
        [self onQueuePersistMeta];
        [self onQueuePublishResolvedState];
        if ([self config].isConfigured) {
            [self onQueueStartRequestWithActivationCode:nil completion:nil];
        }
    });
}

#pragma mark - Lifecycle + deadline (main thread)

- (void)observeApplicationLifecycle {
    if (_observing) {
        return;
    }
    _observing = YES;
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self
               selector:@selector(applicationWillEnterForeground:)
                   name:UIApplicationWillEnterForegroundNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(applicationDidEnterBackground:)
                   name:UIApplicationDidEnterBackgroundNotification
                 object:nil];
}

- (void)applicationWillEnterForeground:(NSNotification *)notification {
    (void)notification;
    [self reconcileOnForeground];
}

- (void)applicationDidEnterBackground:(NSNotification *)notification {
    (void)notification;
    dispatch_async(_licenseQueue, ^{
        [self onQueueObserveClock];
        [self onQueuePersistMeta];
    });
}

- (void)scheduleDeadlineForState:(GPSLabEntitlementState)state {
    NSAssert([NSThread isMainThread], @"deadline scheduling must be on the main thread");
    if (_deadlineTimer != nil) {
        dispatch_source_cancel(_deadlineTimer);
        _deadlineTimer = nil;
    }
    if (!GPSLabLicenseStateIsUnlocked(state)) {
        return;
    }

    os_unfair_lock_lock(&_lock);
    long long target = (state == GPSLabEntitlementStateGrace)
        ? (_entitlement != nil ? _entitlement.graceUntil : 0)
        : (_entitlement != nil ? _entitlement.expiresAt : 0);
    os_unfair_lock_unlock(&_lock);
    if (target <= 0) {
        return;
    }

    long long delta = target - [self wallNow] + 1;
    if (delta < 1) {
        delta = 1;
    }
    // Cap each chunk so dispatch_time never overflows and the effective clock is
    // re-checked at least hourly.
    if (delta > kGPSLabDeadlineChunkSeconds) {
        delta = kGPSLabDeadlineChunkSeconds;
    }

    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    if (timer == NULL) {
        return;
    }
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delta * NSEC_PER_SEC)),
                              DISPATCH_TIME_FOREVER,
                              (uint64_t)(1.0 * NSEC_PER_SEC));
    GPSLabLicenseManager *__weak weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        [weakSelf deadlineFired];
    });
    _deadlineTimer = timer;
    dispatch_resume(timer);
}

- (void)deadlineFired {
    NSAssert([NSThread isMainThread], @"deadline must fire on the main thread");
    if (_deadlineTimer != nil) {
        dispatch_source_cancel(_deadlineTimer);
        _deadlineTimer = nil;
    }
    dispatch_async(_licenseQueue, ^{
        [self onQueueObserveClock];
        [self onQueuePersistMeta];
        [self onQueuePublishResolvedState];
        if ([self config].isConfigured && ![self onQueueIsUnlocked]) {
            [self onQueueStartRequestWithActivationCode:nil completion:nil];
        }
    });
}

@end
