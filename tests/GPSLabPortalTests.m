//
//  GPSLabPortalTests.m
//  GPSLab
//
//  MacOS Foundation tests for the web-portal configuration and the device-proof
//  request builders. They exercise the same production sources the dylib uses
//  (GPSLabLicenseConfig, GPSLabPortalPolicy, GPSLabDevicePairing) with no fake
//  crypto and no network.
//
//  Build/run (macOS, GitHub Actions macos-latest):
//    clang -fobjc-arc -fmodules -framework Foundation -framework Security -ISource \
//      tests/GPSLabPortalTests.m Source/GPSLabLicenseConfig.m \
//      Source/GPSLabPortalPolicy.c Source/GPSLabDevicePairing.m \
//      Source/GPSLabSecureStore.m Source/GPSLabLocalization.m \
//      Source/GPSLabLocalizationCore.c -o /tmp/gpslab-portal-tests
//    /tmp/gpslab-portal-tests
//

#import <Foundation/Foundation.h>

#import "GPSLabDevicePairing.h"
#import "GPSLabLicenseConfig.h"
#import "GPSLabPortalPolicy.h"

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

static NSString *GPSLabTestPublicKey(void) {
    // A length-91 blob is enough for isConfigured; it is never parsed here.
    return [[NSMutableData dataWithLength:91] base64EncodedStringWithOptions:0];
}

static NSString *GPSLabEndpoint(void) {
    return @"https://portal.example.com:8443/api/v1/license/check";
}

static GPSLabLicenseConfig *GPSLabConfig(NSDictionary *extra) {
    NSMutableDictionary *info = [@{
        @"GPSLabLicenseEndpoint": GPSLabEndpoint(),
        @"GPSLabLicensePublicKey": GPSLabTestPublicKey(),
    } mutableCopy];
    [info addEntriesFromDictionary:extra ?: @{}];
    return [GPSLabLicenseConfig configFromInfoDictionary:info];
}

int main(void) {
    @autoreleasepool {
        // 1) Portal endpoints are derived from the license endpoint origin.
        GPSLabLicenseConfig *derived = GPSLabConfig(@{});
        CHECK([derived.endpointOrigin isEqualToString:@"https://portal.example.com:8443"],
              @"endpoint origin canonicalized");
        CHECK([derived.signInURL.absoluteString isEqualToString:@"https://portal.example.com:8443/account/login"],
              @"sign-in URL derived on the license origin");
        CHECK([derived.manageAccountURL.absoluteString isEqualToString:@"https://portal.example.com:8443/account"],
              @"manage URL derived on the license origin");
        CHECK([derived.portalURL.absoluteString isEqualToString:@"https://portal.example.com:8443/account"],
              @"portal URL derived on the license origin");
        CHECK([derived.trialPairingURL.absoluteString isEqualToString:@"https://portal.example.com:8443/account/pair"],
              @"trial pairing URL derived");
        CHECK([derived.helpURL.absoluteString isEqualToString:@"https://portal.example.com:8443/help"],
              @"help URL derived");
        CHECK([derived.pairingEndpoint.absoluteString isEqualToString:@"https://portal.example.com:8443/api/v1/device/pair"],
              @"device pairing endpoint derived");
        CHECK([derived.feedbackEndpoint.absoluteString isEqualToString:@"https://portal.example.com:8443/api/v1/device/feedback"],
              @"device feedback endpoint derived");
        CHECK(derived.isConfigured, @"derived config is usable");

        // 2) An explicit cross-host URL is dropped and replaced by the safe default.
        GPSLabLicenseConfig *crossHost = GPSLabConfig(@{
            @"GPSLabSignInURL": @"https://evil.example.com/signin",
            @"GPSLabPortalURL": @"https://evil.example.com/account",
        });
        CHECK([crossHost.signInURL.host isEqualToString:@"portal.example.com"],
              @"cross-host sign-in is never used");
        CHECK([crossHost.portalURL.host isEqualToString:@"portal.example.com"],
              @"cross-host portal is never used");

        // 3) A credentialed URL is rejected outright.
        GPSLabLicenseConfig *credentialed = GPSLabConfig(@{
            @"GPSLabPortalURL": @"https://user:pass@portal.example.com:8443/account",
            @"GPSLabHelpURL": @"https://user@portal.example.com:8443/help",
        });
        CHECK(credentialed.portalURL.user == nil && credentialed.portalURL.password == nil,
              @"credentialed portal URL rejected");
        CHECK([credentialed.portalURL.host isEqualToString:@"portal.example.com"],
              @"portal falls back to the safe origin");
        CHECK(credentialed.helpURL.user == nil, @"credentialed help URL rejected");

        // 4) A non-HTTPS URL is rejected.
        GPSLabLicenseConfig *insecure = GPSLabConfig(@{
            @"GPSLabHelpURL": @"http://portal.example.com:8443/help",
        });
        CHECK([insecure.helpURL.scheme isEqualToString:@"https"], @"http URL rejected");

        // 5) A different port is rejected; a safe explicit value is accepted verbatim.
        GPSLabLicenseConfig *wrongPort = GPSLabConfig(@{
            @"GPSLabTrialPairingURL": @"https://portal.example.com:9443/account/pair",
        });
        CHECK([wrongPort.trialPairingURL.absoluteString isEqualToString:@"https://portal.example.com:8443/account/pair"],
              @"off-origin port rejected");
        GPSLabLicenseConfig *explicitSafe = GPSLabConfig(@{
            @"GPSLabTrialPairingURL": @"https://portal.example.com:8443/account/trial",
        });
        CHECK([explicitSafe.trialPairingURL.absoluteString isEqualToString:@"https://portal.example.com:8443/account/trial"],
              @"explicit same-origin URL accepted verbatim");

        // 6) No endpoint means no portal surface at all (fail closed).
        GPSLabLicenseConfig *unconfigured = [GPSLabLicenseConfig configFromInfoDictionary:@{ @"GPSLabPortalURL": @"https://portal.example.com/account" }];
        CHECK(unconfigured.portalURL == nil && unconfigured.signInURL == nil,
              @"portal URLs require a license endpoint origin");

        // 7) Device-proof request builders: pairing body carries the two fields only.
        NSData *pairBody = [GPSLabDevicePairing pairingRequestBodyForInstallation:@"install-1"
                                                                     deviceSecret:@"secret-1"];
        NSDictionary *pairJSON = [NSJSONSerialization JSONObjectWithData:pairBody options:0 error:NULL];
        CHECK([pairJSON[@"installationId"] isEqualToString:@"install-1"], @"pairing body has installationId");
        CHECK([pairJSON[@"deviceSecret"] isEqualToString:@"secret-1"], @"pairing body has deviceSecret");
        CHECK(pairJSON.count == 2, @"pairing body carries no extra fields");
        CHECK([GPSLabDevicePairing pairingRequestBodyForInstallation:@"" deviceSecret:@"x"] == nil,
              @"pairing body rejects an empty installation id");

        // 8) Feedback body: valid category, bounded message, invalid input rejected.
        NSData *feedbackBody = [GPSLabDevicePairing feedbackRequestBodyForInstallation:@"install-1"
                                                                          deviceSecret:@"secret-1"
                                                                              category:@"bug"
                                                                               message:@"it broke"];
        NSDictionary *feedbackJSON = [NSJSONSerialization JSONObjectWithData:feedbackBody options:0 error:NULL];
        CHECK([feedbackJSON[@"category"] isEqualToString:@"bug"], @"feedback body has category");
        CHECK([feedbackJSON[@"message"] isEqualToString:@"it broke"], @"feedback body has message");
        CHECK(feedbackJSON.count == 4, @"feedback body carries no extra fields");

        // 8b) The feature/account categories are accepted to match the server enum.
        for (NSString *category in @[@"feature", @"account"]) {
            NSData *categoryBody = [GPSLabDevicePairing feedbackRequestBodyForInstallation:@"install-1"
                                                                              deviceSecret:@"secret-1"
                                                                                  category:category
                                                                                   message:@"x"];
            NSDictionary *categoryJSON = [NSJSONSerialization JSONObjectWithData:categoryBody options:0 error:NULL];
            NSString *categoryMessage = [NSString stringWithFormat:@"feedback body accepts the %@ category", category];
            CHECK([categoryJSON[@"category"] isEqualToString:category], categoryMessage);
        }
        CHECK([GPSLabDevicePairing feedbackRequestBodyForInstallation:@"install-1"
                                                         deviceSecret:@"secret-1"
                                                             category:@"nonsense"
                                                              message:@"x"] == nil,
              @"feedback body rejects an unknown category");
        CHECK([GPSLabDevicePairing feedbackRequestBodyForInstallation:@"install-1"
                                                         deviceSecret:@"secret-1"
                                                             category:@"bug"
                                                              message:@""] == nil,
              @"feedback body rejects an empty message");

        NSMutableString *longMessage = [NSMutableString string];
        for (NSUInteger index = 0; index < 4000; index++) {
            [longMessage appendString:@"a"];
        }
        NSData *longBody = [GPSLabDevicePairing feedbackRequestBodyForInstallation:@"install-1"
                                                                      deviceSecret:@"secret-1"
                                                                          category:@"other"
                                                                           message:longMessage];
        NSDictionary *longJSON = [NSJSONSerialization JSONObjectWithData:longBody options:0 error:NULL];
        CHECK([longJSON[@"message"] lengthOfBytesUsingEncoding:NSUTF8StringEncoding] <= GPSLAB_PORTAL_MAX_FEEDBACK_BYTES,
              @"oversized feedback message is byte-bounded");

        CHECK([GPSLabDevicePairing pairingRequestBodyForInstallation:@"install-1" deviceSecret:nil] == nil,
              @"pairing body rejects a missing device secret");
    }

    if (gFailures != 0) {
        fprintf(stderr, "GPSLabPortalTests: %d/%d checks failed\n", gFailures, gChecks);
        return 1;
    }
    printf("GPSLabPortalTests: %d checks passed\n", gChecks);
    return 0;
}
