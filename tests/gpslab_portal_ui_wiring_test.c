/*
 * GPSLab portal UI wiring tests (portable C, source-validated).
 *
 * Executable static assertions for the UIKit/NSURLSession behaviour the portable
 * target cannot instantiate: the portal entry points, the browser-link origin
 * policy, the pairing-code display-only path, the fail-closed device secret and
 * the hardened device transport.
 * The test reads the production sources and pins the exact structure, so it is
 * honestly source-validated wiring, not a runtime UI test.
 *
 * The pure rules it depends on are unit-tested elsewhere:
 *   * URL/feedback/code policy -> tests/gpslab_portal_policy_test.c
 *   * config + request builders -> tests/GPSLabPortalTests.m (macOS)
 *
 * Build/run (from the repository root):
 *   cc -I Source tests/gpslab_portal_ui_wiring_test.c -o /tmp/gpslab_portal_ui_wiring_test
 *   /tmp/gpslab_portal_ui_wiring_test
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int gFailures = 0;
static int gChecks = 0;

#define CHECK(condition, message)                                                \
    do {                                                                         \
        gChecks++;                                                               \
        if (!(condition)) {                                                      \
            gFailures++;                                                         \
            fprintf(stderr, "FAIL: %s (%s:%d)\n", (message), __FILE__, __LINE__); \
        }                                                                        \
    } while (0)

static char *read_file(const char *path) {
    FILE *handle = fopen(path, "rb");
    if (handle == NULL) {
        return NULL;
    }
    if (fseek(handle, 0, SEEK_END) != 0) {
        fclose(handle);
        return NULL;
    }
    long size = ftell(handle);
    if (size < 0) {
        fclose(handle);
        return NULL;
    }
    rewind(handle);
    char *buffer = (char *)malloc((size_t)size + 1);
    if (buffer == NULL) {
        fclose(handle);
        return NULL;
    }
    size_t read = fread(buffer, 1, (size_t)size, handle);
    buffer[read] = '\0';
    fclose(handle);
    return buffer;
}

static int contains(const char *haystack, const char *needle) {
    return haystack != NULL && strstr(haystack, needle) != NULL;
}

static int count_occurrences(const char *haystack, const char *needle) {
    if (haystack == NULL || needle == NULL || *needle == '\0') {
        return 0;
    }
    int count = 0;
    const char *cursor = haystack;
    while ((cursor = strstr(cursor, needle)) != NULL) {
        count++;
        cursor += strlen(needle);
    }
    return count;
}

static int appears_before(const char *haystack, const char *first, const char *second) {
    if (haystack == NULL) {
        return 0;
    }
    const char *a = strstr(haystack, first);
    const char *b = strstr(haystack, second);
    return a != NULL && b != NULL && a < b;
}

/** Body of the first method whose signature line starts with `signature`. */
static char *extract_body(const char *start) {
    if (start == NULL) {
        return NULL;
    }
    const char *cursor = start;
    while (*cursor != '\0' && *cursor != '\n') {
        cursor++;
    }
    const char *end = cursor;
    while (*cursor != '\0') {
        const char *line = cursor + 1;
        if ((line[0] == '-' && line[1] == ' ') || (line[0] == '+' && line[1] == ' ') ||
            strncmp(line, "#pragma", 7) == 0 || strncmp(line, "@end", 4) == 0) {
            break;
        }
        end = line;
        cursor = line;
        while (*cursor != '\0' && *cursor != '\n') {
            cursor++;
        }
    }
    size_t length = (size_t)(end - start);
    char *body = (char *)malloc(length + 1);
    if (body == NULL) {
        return NULL;
    }
    memcpy(body, start, length);
    body[length] = '\0';
    return body;
}

static char *method_body(const char *source, const char *signature) {
    return extract_body(strstr(source, signature));
}

#define REQUIRE_BODY(variable, source, signature)        \
    char *variable = method_body((source), (signature)); \
    CHECK((variable) != NULL, "method present: " signature)

/* --------------------------------------------------------- Config + policy */

static void test_config_policy(const char *config, const char *policy_h, const char *build_config) {
    CHECK(contains(config, "#import \"GPSLabPortalPolicy.h\""),
          "config uses the shared portal policy");
    CHECK(contains(config, "GPSLabPortalURLIsSafe("),
          "config validates every portal URL against the allowed origin");
    CHECK(contains(config, "GPSLabPortalOriginFromURL("),
          "config derives the allowed origin from the endpoint");
    CHECK(contains(config, "resolvePortalURLs"),
          "config resolves/derives the portal URLs after load and build overrides");
    CHECK(contains(config, "[config resolvePortalURLs];"),
          "Info.plist load resolves the portal URLs");
    CHECK(contains(config, "[self resolvePortalURLs];"),
          "build-time overrides re-resolve the portal URLs");
    CHECK(contains(config, "GPSLabDerivedPortalURL"),
          "missing portal URLs are derived from the endpoint origin");
    CHECK(contains(config, "GPSLAB_LICENSE_BUILD_PORTAL_URL") &&
              contains(config, "GPSLAB_LICENSE_BUILD_PAIR_ENDPOINT") &&
              contains(config, "GPSLAB_LICENSE_BUILD_FEEDBACK_ENDPOINT"),
          "build config can point every portal endpoint");
    CHECK(contains(policy_h, "GPSLAB_PORTAL_MAX_FEEDBACK_BYTES"),
          "the feedback bound is defined by the shared policy");
    CHECK(contains(policy_h, "GPSLabPortalPairingCodeIsSafe"),
          "the pairing-code policy is the shared policy");
    CHECK(contains(policy_h, "GPSLabPortalStatusIsSuccess"),
          "the HTTP-success predicate is part of the shared policy");
    CHECK(contains(build_config, "NEVER place a signing PRIVATE key") ||
              contains(build_config, "NEVER put a signing key"),
          "the build config documents the no-secret rule");
}

/* ------------------------------------------------------------ Device client */

static void test_device_client(const char *pairing) {
    CHECK(contains(pairing, "#import \"GPSLabPortalPolicy.h\""),
          "device client uses the shared policy");
    CHECK(contains(pairing, "@\"POST\""), "device client uses POST");
    CHECK(contains(pairing, "willPerformHTTPRedirection"),
          "device client implements redirect handling");
    CHECK(contains(pairing, "completionHandler(nil)"),
          "device client rejects redirects (never forwards the proof)");
    CHECK(contains(pairing, "maxResponseBytes"),
          "device client caps the streamed response size");
    CHECK(contains(pairing, "timeoutIntervalForRequest"),
          "device client honors the bounded request timeout");
    CHECK(contains(pairing, "HTTPMethod = @\"POST\""),
          "device client uses uppercase HTTPMethod");
    CHECK(contains(pairing, "GPSLabPortalFeedbackCategoryIsValid"),
          "device client validates the feedback category");
    CHECK(contains(pairing, "GPSLabPortalBoundFeedback"),
          "device client bounds the feedback message");
    CHECK(contains(pairing, "GPSLabPortalPairingCodeIsSafe"),
          "device client validates the pairing code before display");
    CHECK(contains(pairing, "GPSLabPortalURLIsSafe("),
          "device client re-checks the endpoint origin before sending");
    CHECK(contains(pairing, "@\"deviceSecret\": deviceSecret"),
          "device secret is a JSON body field, never a URL parameter");
    CHECK(contains(pairing, "GPSLabPortalStatusIsSuccess("),
          "device client accepts every HTTP 2xx (201 feedback), not just 200");
    CHECK(!contains(pairing, "status == 200"),
          "device client must not hard-code HTTP 200 as the only success");
    CHECK(!contains(pairing, "NSURLQueryItem"),
          "device client never builds a URL query");
    CHECK(!contains(pairing, "GPSLabDiag"),
          "device client never logs the proof or the code");
    CHECK(!contains(pairing, "componentsSeparatedByString") && !contains(pairing, "NSURLComponents"),
          "device client never assembles URLs from raw parts");

    REQUIRE_BODY(feedback, pairing,
                 "+ (NSData *)feedbackRequestBodyForInstallation:(NSString *)installationId");
    CHECK(contains(feedback, "GPSLabPortalBoundFeedback"), "feedback builder bounds the message");
    CHECK(appears_before(feedback, "GPSLabPortalFeedbackCategoryIsValid", "NSJSONSerialization"),
          "feedback validates the category before serializing");
    free(feedback);
}

/* --------------------------------------------- Secure store fail-closed */

static void test_secure_store(const char *secure_store, const char *pairing) {
    REQUIRE_BODY(device_secret, secure_store, "- (NSData *)deviceSecret {");
    CHECK(contains(device_secret, "if (![self setData:secret forAccount:kGPSLabAccountDeviceSecret])"),
          "deviceSecret detects a failed Keychain persist");
    const char *failure_branch =
        strstr(device_secret, "if (![self setData:secret forAccount:kGPSLabAccountDeviceSecret])");
    const char *nil_return = failure_branch != NULL ? strstr(failure_branch, "return nil;") : NULL;
    const char *secret_return = failure_branch != NULL ? strstr(failure_branch, "return secret;") : NULL;
    CHECK(failure_branch != NULL && nil_return != NULL && (secret_return == NULL || nil_return < secret_return),
          "deviceSecret FAILS CLOSED: nil on persist failure, never an ephemeral secret");
    CHECK(!contains(device_secret, "per-process") && !contains(device_secret, "still return"),
          "deviceSecret never hands back a value a restart cannot reproduce");
    CHECK(contains(secure_store, "FAIL CLOSED"),
          "the fail-closed contract is documented on the device secret");
    free(device_secret);

    // A duplicate Cache-Control set is a no-op; the device client must set it once.
    CHECK(count_occurrences(pairing, "forHTTPHeaderField:@\"Cache-Control\"") == 1,
          "the device client sets Cache-Control exactly once");
}

/* ----------------------------------------------------------- Portal screen */

static void test_portal_screen(const char *portal, const char *subscription,
                               const char *options, const char *overlay, const char *catalog) {
    CHECK(contains(portal, "UIPasteboard.generalPasteboard.string = code"),
          "the pairing code is copied in-app via the pasteboard");
    CHECK(contains(portal, "// Display/copy only"),
          "the pairing code path is explicitly display/copy only");
    CHECK(!contains(portal, "NSLocalizedString"),
          "portal strings use the embedded catalog");
    CHECK(contains(portal, "GPSLabLocalized(@\"portal.title\")"),
          "portal title is localized");
    CHECK(contains(portal, "GPSLabLicenseStateDidChangeNotification"),
          "portal re-reads the entitlement on license changes");

    // Opening the pairing page must not carry the code.
    REQUIRE_BODY(openPair, portal, "- (void)openPairPageTapped {");
    CHECK(contains(openPair, "trialPairingURL"), "the pairing page uses the configured URL");
    CHECK(!contains(openPair, "pairCodeLabel"), "the pairing code is never appended to the URL");
    CHECK(!contains(openPair, "stringByAppending"), "no code is appended to the pairing page URL");
    free(openPair);

    // Sign-in/manage/help all use the safe configured URLs.
    CHECK(contains(portal, "config.signInURL != nil") && contains(portal, "config.manageAccountURL != nil") &&
              contains(portal, "config.helpURL != nil"),
          "portal gates each browser action on a configured safe URL");
    CHECK(contains(portal, "openExternalURL:"), "portal opens browser actions externally");
    CHECK(contains(portal, "UIApplication sharedApplication") && contains(portal, "openURL:url") &&
              !contains(portal, "WKWebView") && !contains(portal, "UIWebView"),
          "portal uses the system openURL, not a web view");

    // Feedback uses the device client and shows bounded states.
    CHECK(contains(portal, "submitFeedbackWithCategory:"),
          "the feedback form posts through the device client");
    CHECK(contains(portal, "GPSLabPortalFeedbackCategoryAt("),
          "the category control maps to the policy allow-list");
    CHECK(contains(portal, "initWithItems:feedbackTitles") &&
              contains(portal, "GPSLabPortalFeedbackCategoryCount()"),
          "the category control is sized from the shared allow-list");
    CHECK(contains(portal, "portal.feedback.empty"),
          "an empty feedback message is rejected locally");

    // Entry points exist in every state.
    CHECK(contains(subscription, "- (void)accountTapped {"),
          "the locked subscription screen exposes account/support");
    CHECK(contains(subscription, "GPSLabPortalViewController"),
          "the subscription screen opens the portal");
    CHECK(contains(options, "- (void)accountTapped {") &&
              contains(options, "options.account"),
          "the options sheet exposes account/support");
    CHECK(contains(overlay, "- (void)presentPortalSheet {"),
          "the unlocked canvas exposes the portal sheet");
    CHECK(contains(overlay, "options.accountHandler"),
          "the options handler opens the portal from the canvas");

    CHECK(contains(catalog, "\"portal.title\""), "the catalog defines the portal title");
    CHECK(contains(catalog, "\"portal.trial.copy\"") && contains(catalog, "\"portal.trial.open\""),
          "the catalog defines the trial pairing strings");
    CHECK(contains(catalog, "\"portal.feedback.send\"") &&
              contains(catalog, "\"portal.feedback.category.bug\""),
          "the catalog defines the feedback strings");
    CHECK(contains(catalog, "\"portal.feedback.category.feature\"") &&
              contains(catalog, "\"portal.feedback.category.account\""),
          "the catalog defines the feature and account feedback labels");
    CHECK(contains(catalog, "\"options.account\"") && contains(catalog, "\"subscription.account\""),
          "the catalog defines both account entry labels");
}

int main(void) {
    const char *config_path = "Source/GPSLabLicenseConfig.m";
    const char *policy_h_path = "Source/GPSLabPortalPolicy.h";
    const char *build_config_path = "Source/GPSLabLicenseBuildConfig.h";
    const char *pairing_path = "Source/GPSLabDevicePairing.m";
    const char *secure_store_path = "Source/GPSLabSecureStore.m";
    const char *portal_path = "Source/GPSLabPortalViewController.m";
    const char *subscription_path = "Source/GPSLabSubscriptionViewController.m";
    const char *options_path = "Source/GPSLabOptionsViewController.m";
    const char *overlay_path = "Source/GPSLabOverlayViewController.m";
    const char *catalog_path = "Source/GPSLabLocalizationCore.c";

    char *config = read_file(config_path);
    char *policy_h = read_file(policy_h_path);
    char *build_config = read_file(build_config_path);
    char *pairing = read_file(pairing_path);
    char *secure_store = read_file(secure_store_path);
    char *portal = read_file(portal_path);
    char *subscription = read_file(subscription_path);
    char *options = read_file(options_path);
    char *overlay = read_file(overlay_path);
    char *catalog = read_file(catalog_path);

    if (config == NULL || policy_h == NULL || build_config == NULL || pairing == NULL ||
        portal == NULL || subscription == NULL || options == NULL || overlay == NULL ||
        catalog == NULL || secure_store == NULL) {
        fprintf(stderr, "FAIL: cannot read one or more sources (run from the repository root)\n");
        return 1;
    }

    test_config_policy(config, policy_h, build_config);
    test_device_client(pairing);
    test_secure_store(secure_store, pairing);
    test_portal_screen(portal, subscription, options, overlay, catalog);

    free(config);
    free(policy_h);
    free(build_config);
    free(pairing);
    free(secure_store);
    free(portal);
    free(subscription);
    free(options);
    free(overlay);
    free(catalog);

    if (gFailures != 0) {
        fprintf(stderr, "%d/%d portal UI wiring checks failed\n", gFailures, gChecks);
        return 1;
    }
    printf("ok: %d portal UI wiring checks passed\n", gChecks);
    return 0;
}
