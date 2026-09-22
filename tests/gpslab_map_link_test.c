/*
 * GPSLab map-link policy tests (portable C).
 *
 * Exercises Source/GPSLabMapLinkCore.c directly — the exact URL/coordinate
 * classification and redirect policy compiled into the dylib and used by the
 * async resolver. No Foundation/UIKit dependency, runs on any CI runner.
 *
 * Build/run:
 *   cc -I Source tests/gpslab_map_link_test.c Source/GPSLabMapLinkCore.c \
 *     -o /tmp/gpslab_map_link_test && /tmp/gpslab_map_link_test
 */

#include <stdio.h>
#include <string.h>

#include "GPSLabMapLinkCore.h"

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

static GPSLabMapLink parse(const char *text) {
    return GPSLabMapLinkParseText(text, text != NULL ? strlen(text) : 0);
}

static int trusted(const char *text) {
    return GPSLabMapLinkURLIsTrusted(text, strlen(text));
}

static void test_host_allowlist(void) {
    CHECK(GPSLabMapLinkHostAllowed("maps.app.goo.gl", strlen("maps.app.goo.gl")) == 1,
          "maps.app.goo.gl allowed");
    CHECK(GPSLabMapLinkHostAllowed("google.com", strlen("google.com")) == 1, "google.com allowed");
    CHECK(GPSLabMapLinkHostAllowed("www.google.com", strlen("www.google.com")) == 1,
          "www.google.com allowed");
    CHECK(GPSLabMapLinkHostAllowed("maps.google.com", strlen("maps.google.com")) == 1,
          "maps.google.com allowed");
    CHECK(GPSLabMapLinkHostAllowed("maps.apple.com", strlen("maps.apple.com")) == 1,
          "maps.apple.com allowed");
    CHECK(GPSLabMapLinkHostAllowed("GOOGLE.COM", strlen("GOOGLE.COM")) == 1,
          "allowlist is case-insensitive");

    CHECK(GPSLabMapLinkHostAllowed("goo.gl", strlen("goo.gl")) == 0, "plain goo.gl rejected");
    CHECK(GPSLabMapLinkHostAllowed("maps.google.co.uk", strlen("maps.google.co.uk")) == 0,
          "no wildcard google domains");
    CHECK(GPSLabMapLinkHostAllowed("google.com.evil.com", strlen("google.com.evil.com")) == 0,
          "suffix attack rejected");
    CHECK(GPSLabMapLinkHostAllowed("evilgoogle.com", strlen("evilgoogle.com")) == 0,
          "prefix attack rejected");
    CHECK(GPSLabMapLinkHostAllowed("maps.apple.com.evil", strlen("maps.apple.com.evil")) == 0,
          "apple suffix attack rejected");
    CHECK(GPSLabMapLinkHostAllowed("", 0) == 0, "empty host rejected");
    CHECK(GPSLabMapLinkHostAllowed(NULL, 0) == 0, "NULL host rejected");
}

static void test_url_trust(void) {
    CHECK(trusted("https://maps.apple.com/?ll=1,2") == 1, "https apple trusted");
    CHECK(trusted("HTTPS://WWW.GOOGLE.COM/maps") == 1, "scheme/host case-insensitive");
    CHECK(trusted("http://maps.apple.com/?ll=1,2") == 0, "plain http rejected");
    CHECK(trusted("ftp://google.com/maps") == 0, "non-https scheme rejected");
    CHECK(trusted("https://user:pass@google.com/maps") == 0, "credentials rejected");
    CHECK(trusted("https://google.com:443/maps") == 0, "explicit port rejected");
    CHECK(trusted("https://google.com@evil.com/") == 0, "userinfo host confusion rejected");
    CHECK(trusted("https://evil.com/?ll=1,2") == 0, "untrusted host rejected");
    CHECK(trusted("https://google.com.evil.com/maps") == 0, "untrusted suffix host rejected");
    CHECK(trusted("https://maps.apple.com/?ll=1,2 path") == 0, "raw space rejected");
    CHECK(trusted("") == 0, "empty url rejected");
}

static void test_redirect_policy(void) {
    const char *ok = "https://www.google.com/maps/@1,2";
    const char *bad = "https://evil.com/maps";
    CHECK(GPSLabMapLinkRedirectAllowed(0, GPSLAB_MAP_LINK_MAX_REDIRECTS, ok, strlen(ok)) == 1,
          "first hop to allowed host follows");
    CHECK(GPSLabMapLinkRedirectAllowed(2, GPSLAB_MAP_LINK_MAX_REDIRECTS, ok, strlen(ok)) == 1,
          "last allowed hop follows");
    CHECK(GPSLabMapLinkRedirectAllowed(GPSLAB_MAP_LINK_MAX_REDIRECTS, GPSLAB_MAP_LINK_MAX_REDIRECTS,
                                       ok, strlen(ok)) == 0,
          "hop at the cap rejected");
    CHECK(GPSLabMapLinkRedirectAllowed(0, GPSLAB_MAP_LINK_MAX_REDIRECTS, bad, strlen(bad)) == 0,
          "redirect to untrusted host rejected");
}

static void test_direct_coordinates(void) {
    GPSLabMapLink link = parse("37.7749, -122.4194");
    CHECK(link.result == GPSLabMapLinkParseCoordinates, "direct pair recognised");
    CHECK(link.kind == GPSLabMapLinkKindCoordinates, "direct pair kind is coordinates");
    CHECK(link.latitude > 37.77 && link.latitude < 37.78, "direct pair latitude");

    link = parse("  -33.8688 ,151.2093  ");
    CHECK(link.result == GPSLabMapLinkParseCoordinates, "signed pair with spaces recognised");
    CHECK(link.latitude < -33.8 && link.longitude > 151.2, "signed pair values");

    link = parse("100, 200");
    CHECK(link.result == GPSLabMapLinkParseRejected, "out-of-range pair rejected");

    link = parse("Tokyo Tower");
    CHECK(link.result == GPSLabMapLinkParseNone, "plain place text is not a link");
}

static void test_url_formats(void) {
    GPSLabMapLink link = parse("https://www.google.com/maps/@37.7749,-122.4194,15z");
    CHECK(link.result == GPSLabMapLinkParseURLWithCoordinates, "google @lat,lon parsed");
    CHECK(link.kind == GPSLabMapLinkKindGoogle, "google @lat,lon kind");
    CHECK(link.latitude > 37.77 && link.longitude < -122.41, "google @lat,lon values");

    link = parse("https://www.google.com/maps/place/X/data=!3d37.7749!4d-122.4194");
    CHECK(link.result == GPSLabMapLinkParseURLWithCoordinates, "google !3d!4d parsed");
    CHECK(link.latitude > 37.77 && link.longitude < -122.41, "google !3d!4d values");

    link = parse("https://maps.apple.com/?ll=37.7749,-122.4194");
    CHECK(link.result == GPSLabMapLinkParseURLWithCoordinates, "apple ll= parsed");
    CHECK(link.kind == GPSLabMapLinkKindApple, "apple ll= kind");

    link = parse("https://maps.apple.com/?coordinate=37.7749,-122.4194");
    CHECK(link.result == GPSLabMapLinkParseURLWithCoordinates, "apple coordinate= parsed");

    link = parse("https://www.google.com/maps?q=37.7749,-122.4194");
    CHECK(link.result == GPSLabMapLinkParseURLWithCoordinates, "google q= parsed");

    /* Bare allowlisted host without a scheme is normalised to https for parsing. */
    link = parse("maps.apple.com/?ll=37.7749,-122.4194");
    CHECK(link.result == GPSLabMapLinkParseURLWithCoordinates, "bare apple host link parsed");
    CHECK(link.kind == GPSLabMapLinkKindApple, "bare apple host kind");
}

static void test_short_and_rejected(void) {
    GPSLabMapLink link = parse("https://maps.app.goo.gl/AbCdEf123");
    CHECK(link.result == GPSLabMapLinkParseShortLink, "google short link needs resolution");
    CHECK(link.kind == GPSLabMapLinkKindGoogle, "google short link kind");

    link = parse("https://maps.apple.com/place");
    CHECK(link.result == GPSLabMapLinkParseShortLink, "apple link without coords needs resolution");

    link = parse("https://evil.com/maps/@1,2");
    CHECK(link.result == GPSLabMapLinkParseRejected, "untrusted host rejected");

    link = parse("http://maps.apple.com/?ll=1,2");
    CHECK(link.result == GPSLabMapLinkParseRejected, "non-https link rejected");

    link = parse("https://goo.gl/maps/abc");
    CHECK(link.result == GPSLabMapLinkParseRejected, "plain goo.gl link rejected");
}

static void test_normalized_url(void) {
    char buffer[256];
    size_t written = GPSLabMapLinkNormalizedURL("maps.apple.com/?ll=1,2", strlen("maps.apple.com/?ll=1,2"),
                                                buffer, sizeof(buffer));
    CHECK(written > 0 && strcmp(buffer, "https://maps.apple.com/?ll=1,2") == 0,
          "bare host normalised with https prefix");

    written = GPSLabMapLinkNormalizedURL("https://www.google.com/maps", strlen("https://www.google.com/maps"),
                                         buffer, sizeof(buffer));
    CHECK(written > 0 && strcmp(buffer, "https://www.google.com/maps") == 0,
          "absolute trusted url preserved");

    written = GPSLabMapLinkNormalizedURL("https://evil.com/maps", strlen("https://evil.com/maps"),
                                         buffer, sizeof(buffer));
    CHECK(written == 0, "untrusted url not normalised");

    written = GPSLabMapLinkNormalizedURL("maps.apple.com/?ll=1,2", strlen("maps.apple.com/?ll=1,2"),
                                         buffer, 8);
    CHECK(written == 0, "undersized output buffer rejected");
}

int main(void) {
    test_host_allowlist();
    test_url_trust();
    test_redirect_policy();
    test_direct_coordinates();
    test_url_formats();
    test_short_and_rejected();
    test_normalized_url();

    if (gFailures == 0) {
        printf("gpslab_map_link_test: %d checks passed\n", gChecks);
        return 0;
    }
    fprintf(stderr, "gpslab_map_link_test: %d/%d checks failed\n", gFailures, gChecks);
    return 1;
}
