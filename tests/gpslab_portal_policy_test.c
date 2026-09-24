/*
 * GPSLab portal security policy tests (portable C).
 *
 * Unit tests for the Foundation-free policy that guards the web-portal UX:
 * HTTPS-only same-origin links, no embedded credentials or identifier query
 * parameters, bounded/sanitized feedback, fixed feedback categories and
 * display-only pairing codes. Compiled from the exact production source.
 *
 * Build/run (from the repository root):
 *   cc -I Source tests/gpslab_portal_policy_test.c Source/GPSLabPortalPolicy.c \
 *     -o /tmp/gpslab_portal_policy_test
 *   /tmp/gpslab_portal_policy_test
 */

#include <stdio.h>
#include <string.h>

#include "GPSLabPortalPolicy.h"

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

static size_t origin_length(const char *url) {
    char buffer[GPSLAB_PORTAL_MAX_URL + 1];
    return GPSLabPortalOriginFromURL(url, buffer, sizeof(buffer));
}

static int origin_is(const char *url, const char *expected) {
    char buffer[GPSLAB_PORTAL_MAX_URL + 1];
    size_t length = GPSLabPortalOriginFromURL(url, buffer, sizeof(buffer));
    return length > 0 && strcmp(buffer, expected) == 0;
}

static void test_origin_parsing(void) {
    CHECK(origin_is("https://portal.example.com:8443/api/v1/device/pair",
                    "https://portal.example.com:8443"),
          "host+port origin extracted");
    CHECK(origin_is("https://portal.example.com/account", "https://portal.example.com"),
          "default-port origin extracted");
    CHECK(origin_is("HTTPS://Portal.Example.com/account", "https://Portal.Example.com"),
          "scheme is matched case-insensitively and host case preserved");
    CHECK(origin_length("http://portal.example.com") == 0, "http origin rejected");
    CHECK(origin_length("https://user@portal.example.com/a") == 0, "userinfo origin rejected");
    CHECK(origin_length("https://portal.example.com:99999/a") == 0, "out-of-range port rejected");
    CHECK(origin_length("https://portal.example.com:0/a") == 0, "zero port rejected");
    CHECK(origin_length("https://ho st.example.com/a") == 0, "space in host rejected");
    CHECK(origin_length("https://portal.example.com:/a") == 0, "empty port rejected");
    CHECK(origin_length("https:///a") == 0, "empty host rejected");
    CHECK(origin_length("https://portal_example.com/a") == 0, "underscore host rejected");
    CHECK(origin_length("https://portal.example.com/a?x=1") > 0, "query does not affect origin");
}

static void test_safe_origin(void) {
    const char *origin = "https://portal.example.com:8443";
    CHECK(GPSLabPortalURLIsSafe("https://portal.example.com:8443/account", origin) == 1,
          "same-origin portal URL accepted");
    CHECK(GPSLabPortalURLIsSafe("https://portal.example.com/account", origin) == 0,
          "different port rejected");
    CHECK(GPSLabPortalURLIsSafe("https://evil.example.com/account", origin) == 0,
          "cross-host rejected");
    CHECK(GPSLabPortalURLIsSafe("http://portal.example.com:8443/account", origin) == 0,
          "non-HTTPS rejected");
    CHECK(GPSLabPortalURLIsSafe("https://user:pass@portal.example.com:8443/account", origin) == 0,
          "credentialed URL rejected");
}

static void test_safe_default_origin(void) {
    const char *origin = "https://portal.example.com";
    CHECK(GPSLabPortalURLIsSafe("https://portal.example.com/account/pair", origin) == 1,
          "default-port same origin accepted");
    CHECK(GPSLabPortalURLIsSafe("https://portal.example.com:443/account", origin) == 0,
          "explicit default port is not silently folded into the origin");
    CHECK(GPSLabPortalURLIsSafe("https://Portal.Example.com/account", origin) == 1,
          "host comparison is case-insensitive");
}

static void test_identifier_parameters_rejected(void) {
    const char *origin = "https://portal.example.com:8443";
    CHECK(GPSLabPortalURLIsSafe("https://portal.example.com:8443/account?installationId=abc", origin) == 0,
          "installationId query rejected");
    CHECK(GPSLabPortalURLIsSafe("https://portal.example.com:8443/account?refreshToken=abc", origin) == 0,
          "refreshToken query rejected");
    CHECK(GPSLabPortalURLIsSafe("https://portal.example.com:8443/account?deviceSecret=abc", origin) == 0,
          "deviceSecret query rejected");
    CHECK(GPSLabPortalURLIsSafe("https://portal.example.com:8443/account#activationCode=abc", origin) == 0,
          "activationCode fragment rejected");
    CHECK(GPSLabPortalURLIsSafe("https://portal.example.com:8443/account?help=1", origin) == 1,
          "non-sensitive query accepted");
    CHECK(GPSLabPortalURLHasEmbeddedCredential("https://user@portal.example.com:8443/a") == 1,
          "userinfo flagged");
    CHECK(GPSLabPortalURLHasEmbeddedCredential("https://portal.example.com:8443/a") == 0,
          "plain URL not flagged");
}

static void test_feedback_bounding(void) {
    char buffer[GPSLAB_PORTAL_MAX_FEEDBACK_BYTES + 1];

    const char *shortMessage = "hello world";
    size_t shortLength = GPSLabPortalBoundFeedback(shortMessage, buffer, sizeof(buffer));
    CHECK(shortLength == strlen(shortMessage) && strcmp(buffer, shortMessage) == 0,
          "short feedback preserved verbatim");

    CHECK(GPSLabPortalBoundFeedback("", buffer, sizeof(buffer)) == 0, "empty feedback is empty");
    CHECK(GPSLabPortalBoundFeedback(NULL, buffer, sizeof(buffer)) == 0, "null feedback is empty");

    const char *control = "a\x01" "b\nc";
    size_t controlLength = GPSLabPortalBoundFeedback(control, buffer, sizeof(buffer));
    CHECK(strcmp(buffer, "ab\nc") == 0 && controlLength == 4, "control bytes are dropped");

    char longMessage[4000];
    memset(longMessage, 'a', sizeof(longMessage) - 1);
    longMessage[sizeof(longMessage) - 1] = '\0';
    size_t bounded = GPSLabPortalBoundFeedback(longMessage, buffer, sizeof(buffer));
    CHECK(bounded == GPSLAB_PORTAL_MAX_FEEDBACK_BYTES, "feedback is byte-bounded to the cap");

    // 2 ASCII bytes + 3-byte code points: the cap must land on a code point edge.
    char multibyte[4000];
    multibyte[0] = 'a';
    multibyte[1] = 'b';
    size_t cursor = 2;
    while (cursor + 3 < sizeof(multibyte)) {
        multibyte[cursor++] = (char)0xE2;
        multibyte[cursor++] = (char)0x82;
        multibyte[cursor++] = (char)0xAC;
    }
    multibyte[cursor] = '\0';
    size_t multibyteLength = GPSLabPortalBoundFeedback(multibyte, buffer, sizeof(buffer));
    CHECK(multibyteLength <= GPSLAB_PORTAL_MAX_FEEDBACK_BYTES,
          "multibyte feedback respects the byte cap");
    CHECK(multibyteLength >= GPSLAB_PORTAL_MAX_FEEDBACK_BYTES - 3,
          "multibyte feedback fills close to the cap");
    CHECK((multibyteLength - 2) % 3 == 0, "multibyte feedback never cuts a code point");
    for (size_t index = 2; index < multibyteLength; index += 3) {
        CHECK((unsigned char)buffer[index] == 0xE2 &&
                  (unsigned char)buffer[index + 1] == 0x82 &&
                  (unsigned char)buffer[index + 2] == 0xAC,
              "each retained multibyte code point is intact");
    }
}

static void test_status_success(void) {
    CHECK(GPSLabPortalStatusIsSuccess(200) == 1, "200 OK is success");
    CHECK(GPSLabPortalStatusIsSuccess(201) == 1, "201 Created is success (feedback)");
    CHECK(GPSLabPortalStatusIsSuccess(204) == 1, "204 No Content is success");
    CHECK(GPSLabPortalStatusIsSuccess(299) == 1, "top of the 2xx range is success");
    CHECK(GPSLabPortalStatusIsSuccess(199) == 0, "1xx is not success");
    CHECK(GPSLabPortalStatusIsSuccess(300) == 0, "3xx is not success");
    CHECK(GPSLabPortalStatusIsSuccess(400) == 0, "4xx is not success");
    CHECK(GPSLabPortalStatusIsSuccess(500) == 0, "5xx is not success");
    CHECK(GPSLabPortalStatusIsSuccess(0) == 0, "zero status is not success");
    CHECK(GPSLabPortalStatusIsSuccess(-1) == 0, "negative status is not success");
}

static void test_categories(void) {
    CHECK(GPSLabPortalFeedbackCategoryCount() == 6, "six feedback categories match the server enum");
    CHECK(strcmp(GPSLabPortalFeedbackCategoryAt(0), "bug") == 0, "first category is bug");
    CHECK(strcmp(GPSLabPortalFeedbackCategoryAt(1), "feature") == 0, "second category is feature");
    CHECK(GPSLabPortalFeedbackCategoryAt(-1) == NULL, "negative category index is null");
    CHECK(GPSLabPortalFeedbackCategoryAt(99) == NULL, "overrun category index is null");
    CHECK(GPSLabPortalFeedbackCategoryIsValid("bug") == 1, "bug category valid");
    CHECK(GPSLabPortalFeedbackCategoryIsValid("feature") == 1, "feature category valid");
    CHECK(GPSLabPortalFeedbackCategoryIsValid("billing") == 1, "billing category valid");
    CHECK(GPSLabPortalFeedbackCategoryIsValid("account") == 1, "account category valid");
    CHECK(GPSLabPortalFeedbackCategoryIsValid("trial") == 1, "trial category valid");
    CHECK(GPSLabPortalFeedbackCategoryIsValid("other") == 1, "other category valid");
    CHECK(GPSLabPortalFeedbackCategoryIsValid("Bug") == 0, "category is case-sensitive");
    CHECK(GPSLabPortalFeedbackCategoryIsValid("") == 0, "empty category invalid");
    CHECK(GPSLabPortalFeedbackCategoryIsValid("../../etc") == 0, "path-like category invalid");
}

static void test_pairing_code(void) {
    CHECK(GPSLabPortalPairingCodeIsSafe("ABCD-1234") == 1, "grouped pairing code accepted");
    CHECK(GPSLabPortalPairingCodeIsSafe("a1B2_c3D4") == 1, "underscore pairing code accepted");
    CHECK(GPSLabPortalPairingCodeIsSafe("abc") == 0, "too-short code rejected");
    CHECK(GPSLabPortalPairingCodeIsSafe("abcd efgh") == 0, "space in code rejected");
    CHECK(GPSLabPortalPairingCodeIsSafe("abcd<efgh") == 0, "HTML in code rejected");
    CHECK(GPSLabPortalPairingCodeIsSafe("https://evil.example.com") == 0, "URL as code rejected");
    char longCode[GPSLAB_PORTAL_MAX_PAIRING_CODE + 2];
    memset(longCode, 'A', sizeof(longCode) - 1);
    longCode[sizeof(longCode) - 1] = '\0';
    CHECK(GPSLabPortalPairingCodeIsSafe(longCode) == 0, "over-long code rejected");
}

int main(void) {
    test_origin_parsing();
    test_safe_origin();
    test_safe_default_origin();
    test_identifier_parameters_rejected();
    test_feedback_bounding();
    test_status_success();
    test_categories();
    test_pairing_code();

    if (gFailures != 0) {
        fprintf(stderr, "%d/%d portal policy checks failed\n", gFailures, gChecks);
        return 1;
    }
    printf("gpslab_portal_policy_test: %d checks passed\n", gChecks);
    return 0;
}
