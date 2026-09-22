//
//  GPSLabMapLinkCore.h
//  GPSLab
//
//  Pure C, dependency-free policy core for the map-link search field. It has no
//  Foundation/UIKit dependency so the EXACT rules the dylib obeys are compiled
//  both into the dylib and into the portable CI tests.
//
//  Responsibilities:
//    * classify a search-field string as direct coordinates, a Google Maps URL,
//      an Apple Maps URL, or a coordinate-bearing / short maps link;
//    * extract coordinates from the formats the reference recognises
//      (Google `@lat,lon` / `!3dlat!4dlon`, Apple/query `ll=` / `coordinate=`,
//      plus `q=` / `sll=` / `center=` / `daddr=` / `destination=`, and a plain
//      `lat, lon` pair);
//    * enforce the STRICT exact-host allowlist for URL inputs and redirects.
//
//  Security: only HTTPS URLs on the exact allowlist are trusted. Credentials
//  (userinfo `@`) and explicit ports (`:`) are rejected, as are non-HTTPS
//  schemes and malformed hosts. There is no wildcard domain matching.
//

#ifndef GPSLAB_MAP_LINK_CORE_H
#define GPSLAB_MAP_LINK_CORE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/** Maximum redirect hops the resolver may follow before failing closed. */
#define GPSLAB_MAP_LINK_MAX_REDIRECTS 3

/** Human-readable provider of a recognised link. */
typedef enum {
    GPSLabMapLinkKindNone = 0,
    GPSLabMapLinkKindGoogle = 1,
    GPSLabMapLinkKindApple = 2,
    GPSLabMapLinkKindCoordinates = 3,
} GPSLabMapLinkKind;

/** Outcome of parsing a search-field string. */
typedef enum {
    /** Not a coordinate pair and not a maps link: caller keeps the normal flow. */
    GPSLabMapLinkParseNone = 0,
    /** A plain "lat, lon" pair typed directly into the field. */
    GPSLabMapLinkParseCoordinates = 1,
    /** A trusted maps URL that already carries coordinates. */
    GPSLabMapLinkParseURLWithCoordinates = 2,
    /** A trusted maps URL without inline coordinates: needs safe resolution. */
    GPSLabMapLinkParseShortLink = 3,
    /** Looked like a URL/pair but is untrusted or malformed: never followed. */
    GPSLabMapLinkParseRejected = 4,
} GPSLabMapLinkParseResult;

/** Parse result with the kind and (when present) the coordinates. */
typedef struct {
    GPSLabMapLinkParseResult result;
    GPSLabMapLinkKind kind;
    double latitude;
    double longitude;
} GPSLabMapLink;

/**
 * 1 when `host` (case-insensitive, exact) is one of the allowlisted hosts:
 *   maps.app.goo.gl, google.com, www.google.com, maps.google.com, maps.apple.com
 * No wildcard, no subdomain, no `goo.gl` (only `maps.app.goo.gl`).
 */
int GPSLabMapLinkHostAllowed(const char *host, size_t length);

/**
 * 1 when `text` is a syntactically valid HTTPS URL whose host is exactly
 * allowlisted, with no userinfo credentials and no explicit port.
 */
int GPSLabMapLinkURLIsTrusted(const char *text, size_t length);

/**
 * Redirect policy: `next_hop_index` (0-based) must be < `max_hops`, and the
 * target URL must be trusted by GPSLabMapLinkURLIsTrusted. Returns 1 to follow.
 */
int GPSLabMapLinkRedirectAllowed(int next_hop_index, int max_hops,
                                 const char *text, size_t length);

/**
 * Extracts the first coordinate pair from a URL string. Returns 1 and writes the
 * values on success; returns 0 when no supported coordinate pattern is present or
 * the values are out of range.
 */
int GPSLabMapLinkParseURLCoordinates(const char *text, size_t length,
                                     double *latitude, double *longitude);

/**
 * Classifies a search-field string. Never allocates and never touches the
 * network; the caller decides whether to resolve a `ShortLink` result.
 */
GPSLabMapLink GPSLabMapLinkParseText(const char *text, size_t length);

/**
 * Writes a normalized absolute HTTPS URL for a recognised link into `out`
 * (NUL-terminated). A bare allowlisted host is prefixed with `https://`.
 * Returns the written length (excluding the NUL) or 0 when `text` is not a
 * trusted public link (non-HTTPS, untrusted host, credentials, port or too
 * large for `out_size`).
 */
size_t GPSLabMapLinkNormalizedURL(const char *text, size_t length, char *out, size_t out_size);

#ifdef __cplusplus
}
#endif

#endif /* GPSLAB_MAP_LINK_CORE_H */
