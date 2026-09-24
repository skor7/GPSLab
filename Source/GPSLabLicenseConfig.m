//
//  GPSLabLicenseConfig.m
//  GPSLab
//
//  Empty defaults fail closed. Build-time macros (if present) override the host
//  Info.plist, so a GPSLab build can be pointed at a backend without editing the host.
//

#import "GPSLabLicenseConfig.h"

#import "GPSLabLicenseBuildConfig.h"
#import "GPSLabPortalPolicy.h"

static NSString * const kGPSLabConfigEndpointKey = @"GPSLabLicenseEndpoint";
static NSString * const kGPSLabConfigPublicKeyKey = @"GPSLabLicensePublicKey";
static NSString * const kGPSLabConfigSignInKey = @"GPSLabSignInURL";
static NSString * const kGPSLabConfigManageKey = @"GPSLabManageAccountURL";
static NSString * const kGPSLabConfigPortalKey = @"GPSLabPortalURL";
static NSString * const kGPSLabConfigTrialPairingKey = @"GPSLabTrialPairingURL";
static NSString * const kGPSLabConfigHelpKey = @"GPSLabHelpURL";
static NSString * const kGPSLabConfigPairingEndpointKey = @"GPSLabPairingEndpoint";
static NSString * const kGPSLabConfigFeedbackEndpointKey = @"GPSLabFeedbackEndpoint";
static NSString * const kGPSLabConfigIssuerKey = @"GPSLabLicenseIssuer";
static NSString * const kGPSLabConfigAudienceKey = @"GPSLabLicenseAudience";
static NSString * const kGPSLabConfigGraceKey = @"GPSLabMaxOfflineGraceSeconds";
static NSString * const kGPSLabConfigSkewKey = @"GPSLabMaxClockSkewSeconds";

// Safe same-origin defaults, derived from the license endpoint only.
static NSString * const kGPSLabPortalDefaultSignInPath = @"/account/login";
static NSString * const kGPSLabPortalDefaultManagePath = @"/account";
static NSString * const kGPSLabPortalDefaultHomePath = @"/account";
static NSString * const kGPSLabPortalDefaultTrialPath = @"/account/pair";
static NSString * const kGPSLabPortalDefaultHelpPath = @"/help";
static NSString * const kGPSLabPortalDefaultPairingPath = @"/api/v1/device/pair";
static NSString * const kGPSLabPortalDefaultFeedbackPath = @"/api/v1/device/feedback";

static const NSTimeInterval kGPSLabDefaultGraceSeconds = 604800.0;   // 7 days
static const NSTimeInterval kGPSLabDefaultSkewSeconds = 300.0;
static const NSTimeInterval kGPSLabDefaultRequestTimeout = 15.0;
static const NSTimeInterval kGPSLabDefaultResourceTimeout = 30.0;
static const NSUInteger kGPSLabDefaultMaxResponseBytes = 128 * 1024;
static const NSUInteger kGPSLabDefaultMaxEnvelopeBytes = 256 * 1024;

#pragma mark - Build-time macros (empty by default)

static NSString *GPSLabBuildEndpoint(void) {
#if defined(GPSLAB_LICENSE_BUILD_ENDPOINT)
    return GPSLAB_LICENSE_BUILD_ENDPOINT;
#else
    return nil;
#endif
}

static NSString *GPSLabBuildPublicKey(void) {
#if defined(GPSLAB_LICENSE_BUILD_PUBLIC_KEY)
    return GPSLAB_LICENSE_BUILD_PUBLIC_KEY;
#else
    return nil;
#endif
}

static NSString *GPSLabBuildSignInURL(void) {
#if defined(GPSLAB_LICENSE_BUILD_SIGN_IN_URL)
    return GPSLAB_LICENSE_BUILD_SIGN_IN_URL;
#else
    return nil;
#endif
}

static NSString *GPSLabBuildManageURL(void) {
#if defined(GPSLAB_LICENSE_BUILD_MANAGE_URL)
    return GPSLAB_LICENSE_BUILD_MANAGE_URL;
#else
    return nil;
#endif
}

static NSString *GPSLabBuildPortalURL(void) {
#if defined(GPSLAB_LICENSE_BUILD_PORTAL_URL)
    return GPSLAB_LICENSE_BUILD_PORTAL_URL;
#else
    return nil;
#endif
}

static NSString *GPSLabBuildTrialURL(void) {
#if defined(GPSLAB_LICENSE_BUILD_TRIAL_URL)
    return GPSLAB_LICENSE_BUILD_TRIAL_URL;
#else
    return nil;
#endif
}

static NSString *GPSLabBuildHelpURL(void) {
#if defined(GPSLAB_LICENSE_BUILD_HELP_URL)
    return GPSLAB_LICENSE_BUILD_HELP_URL;
#else
    return nil;
#endif
}

static NSString *GPSLabBuildPairingEndpoint(void) {
#if defined(GPSLAB_LICENSE_BUILD_PAIR_ENDPOINT)
    return GPSLAB_LICENSE_BUILD_PAIR_ENDPOINT;
#else
    return nil;
#endif
}

static NSString *GPSLabBuildFeedbackEndpoint(void) {
#if defined(GPSLAB_LICENSE_BUILD_FEEDBACK_ENDPOINT)
    return GPSLAB_LICENSE_BUILD_FEEDBACK_ENDPOINT;
#else
    return nil;
#endif
}

static NSString *GPSLabBuildIssuer(void) {
#if defined(GPSLAB_LICENSE_BUILD_ISSUER)
    return GPSLAB_LICENSE_BUILD_ISSUER;
#else
    return nil;
#endif
}

static NSString *GPSLabBuildAudience(void) {
#if defined(GPSLAB_LICENSE_BUILD_AUDIENCE)
    return GPSLAB_LICENSE_BUILD_AUDIENCE;
#else
    return nil;
#endif
}

static BOOL GPSLabBuildGraceSeconds(NSTimeInterval *outValue) {
#if defined(GPSLAB_LICENSE_BUILD_GRACE_SECONDS)
    if (outValue != NULL) {
        *outValue = (NSTimeInterval)GPSLAB_LICENSE_BUILD_GRACE_SECONDS;
    }
    return YES;
#else
    (void)outValue;
    return NO;
#endif
}

static BOOL GPSLabBuildSkewSeconds(NSTimeInterval *outValue) {
#if defined(GPSLAB_LICENSE_BUILD_SKEW_SECONDS)
    if (outValue != NULL) {
        *outValue = (NSTimeInterval)GPSLAB_LICENSE_BUILD_SKEW_SECONDS;
    }
    return YES;
#else
    (void)outValue;
    return NO;
#endif
}

#pragma mark - Helpers

static NSURL *GPSLabHTTPSURLFromString(NSString *string) {
    if (![string isKindOfClass:[NSString class]] || string.length == 0) {
        return nil;
    }
    NSURL *url = [NSURL URLWithString:string];
    if (url == nil || ![url.scheme.lowercaseString isEqualToString:@"https"] || url.host.length == 0) {
        return nil;
    }
    // Never accept an authority with embedded userinfo or an identifier query:
    // the license endpoint carries no credential and no caller identifier.
    if (GPSLabPortalURLHasEmbeddedCredential(string.UTF8String)) {
        return nil;
    }
    return url;
}

/** Canonical "https://host[:port]" origin of a URL string, or nil. */
static NSString *GPSLabOriginFromURLString(NSString *string) {
    if (![string isKindOfClass:[NSString class]] || string.length == 0) {
        return nil;
    }
    char buffer[GPSLAB_PORTAL_MAX_URL + 1];
    size_t length = GPSLabPortalOriginFromURL(string.UTF8String, buffer, sizeof(buffer));
    if (length == 0) {
        return nil;
    }
    return [NSString stringWithUTF8String:buffer];
}

/**
 * Returns `string` as a URL only when `origin` is known and the URL passes the
 * shared policy (exact HTTPS origin, no credentials, no identifier query).
 */
static NSURL *GPSLabSafePortalURL(NSString *string, NSString *origin) {
    if (![string isKindOfClass:[NSString class]] || string.length == 0 || origin.length == 0) {
        return nil;
    }
    if (!GPSLabPortalURLIsSafe(string.UTF8String, origin.UTF8String)) {
        return nil;
    }
    return [NSURL URLWithString:string];
}

/** Builds and validates `origin + path` (path starts with '/'). */
static NSURL *GPSLabDerivedPortalURL(NSString *origin, NSString *path) {
    if (origin.length == 0 || path.length == 0) {
        return nil;
    }
    return GPSLabSafePortalURL([origin stringByAppendingString:path], origin);
}

static NSData *GPSLabDecodedPublicKey(NSString *string) {
    if (![string isKindOfClass:[NSString class]] || string.length == 0) {
        return nil;
    }
    NSString *normalized = [string stringByReplacingOccurrencesOfString:@"-" withString:@"+"];
    normalized = [normalized stringByReplacingOccurrencesOfString:@"_" withString:@"/"];
    while (normalized.length % 4 != 0) {
        normalized = [normalized stringByAppendingString:@"="];
    }
    return [[NSData alloc] initWithBase64EncodedString:normalized
                                               options:NSDataBase64DecodingIgnoreUnknownCharacters];
}

static BOOL GPSLabAcceptSeconds(NSNumber *number, NSTimeInterval maximum, NSTimeInterval *outValue) {
    if (![number isKindOfClass:[NSNumber class]]) {
        return NO;
    }
    double seconds = [number doubleValue];
    if (seconds < 0.0 || seconds > maximum) {
        return NO;
    }
    if (outValue != NULL) {
        *outValue = seconds;
    }
    return YES;
}

@interface GPSLabLicenseConfig ()
- (void)resolvePortalURLs;
@end

@implementation GPSLabLicenseConfig

+ (instancetype)sharedConfig {
    static GPSLabLicenseConfig *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSDictionary *info = [NSBundle mainBundle].infoDictionary;
        GPSLabLicenseConfig *config = [GPSLabLicenseConfig configFromInfoDictionary:info];
        [config applyBuildTimeOverrides];
        instance = config;
    });
    return instance;
}

+ (instancetype)configFromInfoDictionary:(NSDictionary *)info {
    GPSLabLicenseConfig *config = [[GPSLabLicenseConfig alloc] init];
    config.maxOfflineGraceSeconds = kGPSLabDefaultGraceSeconds;
    config.maxClockSkewSeconds = kGPSLabDefaultSkewSeconds;
    config.requestTimeoutSeconds = kGPSLabDefaultRequestTimeout;
    config.resourceTimeoutSeconds = kGPSLabDefaultResourceTimeout;
    config.maxResponseBytes = kGPSLabDefaultMaxResponseBytes;
    config.maxEnvelopeBytes = kGPSLabDefaultMaxEnvelopeBytes;

    if (![info isKindOfClass:[NSDictionary class]]) {
        return config;
    }

    config.endpoint = GPSLabHTTPSURLFromString(info[kGPSLabConfigEndpointKey]);
    config.signInURL = GPSLabHTTPSURLFromString(info[kGPSLabConfigSignInKey]);
    config.manageAccountURL = GPSLabHTTPSURLFromString(info[kGPSLabConfigManageKey]);
    config.portalURL = GPSLabHTTPSURLFromString(info[kGPSLabConfigPortalKey]);
    config.trialPairingURL = GPSLabHTTPSURLFromString(info[kGPSLabConfigTrialPairingKey]);
    config.helpURL = GPSLabHTTPSURLFromString(info[kGPSLabConfigHelpKey]);
    config.pairingEndpoint = GPSLabHTTPSURLFromString(info[kGPSLabConfigPairingEndpointKey]);
    config.feedbackEndpoint = GPSLabHTTPSURLFromString(info[kGPSLabConfigFeedbackEndpointKey]);
    config.publicKey = GPSLabDecodedPublicKey(info[kGPSLabConfigPublicKeyKey]);

    NSString *issuer = info[kGPSLabConfigIssuerKey];
    if ([issuer isKindOfClass:[NSString class]] && issuer.length > 0) {
        config.issuer = issuer;
    }
    NSString *audience = info[kGPSLabConfigAudienceKey];
    if ([audience isKindOfClass:[NSString class]] && audience.length > 0) {
        config.audience = audience;
    }

    NSTimeInterval seconds = 0.0;
    if (GPSLabAcceptSeconds(info[kGPSLabConfigGraceKey], 10.0 * 365.0 * 24.0 * 60.0 * 60.0, &seconds)) {
        config.maxOfflineGraceSeconds = seconds;
    }
    if (GPSLabAcceptSeconds(info[kGPSLabConfigSkewKey], 24.0 * 60.0 * 60.0, &seconds)) {
        config.maxClockSkewSeconds = seconds;
    }

    [config resolvePortalURLs];
    return config;
}

/**
 * Forces every portal/account URL to the license endpoint's exact HTTPS origin
 * and fills any missing value with a safe same-origin default. Called after the
 * Info.plist load and again after build-time overrides (which may move the
 * endpoint host, invalidating earlier values).
 */
- (void)resolvePortalURLs {
    NSString *origin = GPSLabOriginFromURLString(self.endpoint.absoluteString);
    self.signInURL = GPSLabSafePortalURL(self.signInURL.absoluteString, origin);
    self.manageAccountURL = GPSLabSafePortalURL(self.manageAccountURL.absoluteString, origin);
    self.portalURL = GPSLabSafePortalURL(self.portalURL.absoluteString, origin);
    self.trialPairingURL = GPSLabSafePortalURL(self.trialPairingURL.absoluteString, origin);
    self.helpURL = GPSLabSafePortalURL(self.helpURL.absoluteString, origin);
    self.pairingEndpoint = GPSLabSafePortalURL(self.pairingEndpoint.absoluteString, origin);
    self.feedbackEndpoint = GPSLabSafePortalURL(self.feedbackEndpoint.absoluteString, origin);

    if (origin.length == 0) {
        return;
    }
    if (self.signInURL == nil) {
        self.signInURL = GPSLabDerivedPortalURL(origin, kGPSLabPortalDefaultSignInPath);
    }
    if (self.manageAccountURL == nil) {
        self.manageAccountURL = GPSLabDerivedPortalURL(origin, kGPSLabPortalDefaultManagePath);
    }
    if (self.portalURL == nil) {
        self.portalURL = GPSLabDerivedPortalURL(origin, kGPSLabPortalDefaultHomePath);
    }
    if (self.trialPairingURL == nil) {
        self.trialPairingURL = GPSLabDerivedPortalURL(origin, kGPSLabPortalDefaultTrialPath);
    }
    if (self.helpURL == nil) {
        self.helpURL = GPSLabDerivedPortalURL(origin, kGPSLabPortalDefaultHelpPath);
    }
    if (self.pairingEndpoint == nil) {
        self.pairingEndpoint = GPSLabDerivedPortalURL(origin, kGPSLabPortalDefaultPairingPath);
    }
    if (self.feedbackEndpoint == nil) {
        self.feedbackEndpoint = GPSLabDerivedPortalURL(origin, kGPSLabPortalDefaultFeedbackPath);
    }
}

- (NSString *)endpointOrigin {
    return GPSLabOriginFromURLString(self.endpoint.absoluteString);
}

// Build-time macros win over the host Info.plist. Never carries a private key.
- (void)applyBuildTimeOverrides {
    NSURL *endpoint = GPSLabHTTPSURLFromString(GPSLabBuildEndpoint());
    if (endpoint != nil) {
        self.endpoint = endpoint;
    }
    NSData *publicKey = GPSLabDecodedPublicKey(GPSLabBuildPublicKey());
    if (publicKey.length > 0) {
        self.publicKey = publicKey;
    }
    NSURL *signIn = GPSLabHTTPSURLFromString(GPSLabBuildSignInURL());
    if (signIn != nil) {
        self.signInURL = signIn;
    }
    NSURL *manage = GPSLabHTTPSURLFromString(GPSLabBuildManageURL());
    if (manage != nil) {
        self.manageAccountURL = manage;
    }
    NSURL *portal = GPSLabHTTPSURLFromString(GPSLabBuildPortalURL());
    if (portal != nil) {
        self.portalURL = portal;
    }
    NSURL *trial = GPSLabHTTPSURLFromString(GPSLabBuildTrialURL());
    if (trial != nil) {
        self.trialPairingURL = trial;
    }
    NSURL *help = GPSLabHTTPSURLFromString(GPSLabBuildHelpURL());
    if (help != nil) {
        self.helpURL = help;
    }
    NSURL *pair = GPSLabHTTPSURLFromString(GPSLabBuildPairingEndpoint());
    if (pair != nil) {
        self.pairingEndpoint = pair;
    }
    NSURL *feedback = GPSLabHTTPSURLFromString(GPSLabBuildFeedbackEndpoint());
    if (feedback != nil) {
        self.feedbackEndpoint = feedback;
    }
    NSString *issuer = GPSLabBuildIssuer();
    if (issuer.length > 0) {
        self.issuer = issuer;
    }
    NSString *audience = GPSLabBuildAudience();
    if (audience.length > 0) {
        self.audience = audience;
    }
    NSTimeInterval seconds = 0.0;
    if (GPSLabBuildGraceSeconds(&seconds) && seconds >= 0.0) {
        self.maxOfflineGraceSeconds = seconds;
    }
    if (GPSLabBuildSkewSeconds(&seconds) && seconds >= 0.0) {
        self.maxClockSkewSeconds = seconds;
    }
    // The build may have moved the endpoint, so re-resolve the portal URLs.
    [self resolvePortalURLs];
}

- (BOOL)isConfigured {
    return self.endpoint != nil && self.publicKey.length > 0;
}

@end
