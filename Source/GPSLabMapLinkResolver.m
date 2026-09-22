//
//  GPSLabMapLinkResolver.m
//  GPSLab
//

#import "GPSLabMapLinkResolver.h"

#import "GPSLabMapLinkCore.h"
#import "GPSLabMapLinkTransport.h"
#import "GPSLabMapLinkURLSessionTransport.h"

@implementation GPSLabMapLinkResolverResult

+ (instancetype)successWithCoordinate:(CLLocationCoordinate2D)coordinate
                        sourceKindKey:(nullable NSString *)sourceKindKey {
    GPSLabMapLinkResolverResult *result = [[GPSLabMapLinkResolverResult alloc] init];
    result->_success = YES;
    result->_coordinate = coordinate;
    result->_sourceKindKey = [sourceKindKey copy];
    result->_error = GPSLabMapLinkResolverErrorNone;
    return result;
}

+ (instancetype)failureWithError:(GPSLabMapLinkResolverError)error {
    GPSLabMapLinkResolverResult *result = [[GPSLabMapLinkResolverResult alloc] init];
    result->_success = NO;
    result->_coordinate = kCLLocationCoordinate2DInvalid;
    result->_sourceKindKey = nil;
    result->_error = error;
    return result;
}

@end

@interface GPSLabMapLinkResolver ()
@property (nonatomic, strong) id<GPSLabMapLinkTransport> transport;
@end

@implementation GPSLabMapLinkResolver {
    NSUInteger _generation;
    NSString *_activeText;
    id _activeRequest;
    void (^_completion)(GPSLabMapLinkResolverResult *);
    BOOL _finished;
}

+ (instancetype)sharedResolver {
    static GPSLabMapLinkResolver *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[GPSLabMapLinkResolver alloc] initWithTransport:[GPSLabMapLinkURLSessionTransport sharedTransport]];
    });
    return instance;
}

- (instancetype)initWithTransport:(id<GPSLabMapLinkTransport>)transport {
    self = [super init];
    if (self) {
        _transport = transport;
    }
    return self;
}

#pragma mark - Public API

- (void)resolveText:(nullable NSString *)text
         completion:(void (^)(GPSLabMapLinkResolverResult *))completion {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self resolveText:text completion:completion];
        });
        return;
    }
    [self cancelInternal];
    _generation += 1;
    NSUInteger token = _generation;
    NSString *value = text ?: @"";
    _activeText = [value copy];
    _finished = NO;
    _completion = [completion copy];

    const char *bytes = value.UTF8String;
    size_t length = [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    GPSLabMapLink link = GPSLabMapLinkParseText(bytes, length);

    switch (link.result) {
        case GPSLabMapLinkParseCoordinates:
            [self deliverResult:[GPSLabMapLinkResolverResult successWithCoordinate:CLLocationCoordinate2DMake(link.latitude, link.longitude)
                                                                    sourceKindKey:nil]
                          token:token];
            return;
        case GPSLabMapLinkParseURLWithCoordinates:
            [self deliverResult:[GPSLabMapLinkResolverResult successWithCoordinate:CLLocationCoordinate2DMake(link.latitude, link.longitude)
                                                                    sourceKindKey:[self sourceKindKeyForKind:link.kind]]
                          token:token];
            return;
        case GPSLabMapLinkParseShortLink:
            break;
        case GPSLabMapLinkParseRejected:
            [self deliverResult:[GPSLabMapLinkResolverResult failureWithError:GPSLabMapLinkResolverErrorUntrusted] token:token];
            return;
        case GPSLabMapLinkParseNone:
        default:
            [self deliverResult:[GPSLabMapLinkResolverResult failureWithError:GPSLabMapLinkResolverErrorNotALink] token:token];
            return;
    }

    // Short link: normalise, then resolve through the injected transport.
    if (self.transport == nil) {
        [self deliverResult:[GPSLabMapLinkResolverResult failureWithError:GPSLabMapLinkResolverErrorUnresolved] token:token];
        return;
    }
    char urlBuffer[2048];
    size_t written = GPSLabMapLinkNormalizedURL(bytes, length, urlBuffer, sizeof(urlBuffer));
    if (written == 0) {
        [self deliverResult:[GPSLabMapLinkResolverResult failureWithError:GPSLabMapLinkResolverErrorUntrusted] token:token];
        return;
    }
    NSURL *url = [NSURL URLWithString:[NSString stringWithUTF8String:urlBuffer]];
    if (url == nil) {
        [self deliverResult:[GPSLabMapLinkResolverResult failureWithError:GPSLabMapLinkResolverErrorUntrusted] token:token];
        return;
    }

    GPSLabMapLinkResolver *__weak weakSelf = self;
    _activeRequest = [self.transport performRequestWithURL:url
        completion:^(NSURL * _Nullable finalURL, NSInteger statusCode, NSError * _Nullable error) {
            [weakSelf handleTransportFinalURL:finalURL
                                   statusCode:statusCode
                                        error:error
                                        token:token
                                requestedText:value];
        }];
}

- (void)cancel {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self cancel]; });
        return;
    }
    [self cancelInternal];
}

#pragma mark - Internals

- (nullable NSString *)sourceKindKeyForKind:(GPSLabMapLinkKind)kind {
    switch (kind) {
        case GPSLabMapLinkKindGoogle:
            return @"search.source.google";
        case GPSLabMapLinkKindApple:
            return @"search.source.apple";
        default:
            return nil;
    }
}

- (GPSLabMapLinkResolverError)errorForTransportError:(nullable NSError *)error {
    if (error != nil && [error.domain isEqualToString:GPSLabMapLinkTransportErrorDomain]) {
        if (error.code == GPSLabMapLinkTransportErrorUntrustedRedirect ||
            error.code == GPSLabMapLinkTransportErrorUntrustedFinal) {
            return GPSLabMapLinkResolverErrorUntrusted;
        }
    }
    return GPSLabMapLinkResolverErrorUnresolved;
}

- (void)handleTransportFinalURL:(nullable NSURL *)finalURL
                     statusCode:(NSInteger)statusCode
                          error:(nullable NSError *)error
                          token:(NSUInteger)token
                  requestedText:(NSString *)requestedText {
    // Main-thread (transport contract). Stale/hostile completions are dropped:
    // the generation and the still-active requested text must both match.
    if (token != _generation || _finished) {
        return;
    }
    if (_activeText == nil || ![_activeText isEqualToString:requestedText]) {
        return;
    }
    if (error != nil) {
        [self deliverResult:[GPSLabMapLinkResolverResult failureWithError:[self errorForTransportError:error]] token:token];
        return;
    }
    if (statusCode < 200 || statusCode >= 300 || finalURL == nil) {
        [self deliverResult:[GPSLabMapLinkResolverResult failureWithError:GPSLabMapLinkResolverErrorUnresolved] token:token];
        return;
    }

    NSString *finalString = finalURL.absoluteString ?: @"";
    const char *bytes = finalString.UTF8String;
    size_t length = [finalString lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    if (!GPSLabMapLinkURLIsTrusted(bytes, length)) {
        [self deliverResult:[GPSLabMapLinkResolverResult failureWithError:GPSLabMapLinkResolverErrorUntrusted] token:token];
        return;
    }
    double latitude = 0.0;
    double longitude = 0.0;
    if (!GPSLabMapLinkParseURLCoordinates(bytes, length, &latitude, &longitude)) {
        [self deliverResult:[GPSLabMapLinkResolverResult failureWithError:GPSLabMapLinkResolverErrorUnresolved] token:token];
        return;
    }
    GPSLabMapLink finalLink = GPSLabMapLinkParseText(bytes, length);
    [self deliverResult:[GPSLabMapLinkResolverResult successWithCoordinate:CLLocationCoordinate2DMake(latitude, longitude)
                                                            sourceKindKey:[self sourceKindKeyForKind:finalLink.kind]]
                  token:token];
}

- (void)deliverResult:(GPSLabMapLinkResolverResult *)result token:(NSUInteger)token {
    if (token != _generation || _finished) {
        return;
    }
    _finished = YES;
    _activeRequest = nil; // the request invalidated its own session on completion
    _activeText = nil;
    void (^completion)(GPSLabMapLinkResolverResult *) = _completion;
    _completion = nil;
    if (completion != nil) {
        completion(result);
    }
}

- (void)cancelInternal {
    _generation += 1;
    _finished = YES;
    _activeText = nil;
    _completion = nil;
    id request = _activeRequest;
    _activeRequest = nil;
    [self.transport cancelRequest:request];
}

@end
