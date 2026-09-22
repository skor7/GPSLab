//
//  GPSLabMapLinkCore.c
//  GPSLab
//
//  Portable implementation of the map-link policy core (see the header).
//  No Foundation, no UIKit, no allocation, no network.
//

#include "GPSLabMapLinkCore.h"

#include <string.h>

/* ---------------------------------------------------------------- helpers -- */

static int gpl_is_space(unsigned char c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\v' || c == '\f';
}

static unsigned char gpl_lower(unsigned char c) {
    if (c >= 'A' && c <= 'Z') {
        return (unsigned char)(c - 'A' + 'a');
    }
    return c;
}

static int gpl_ci_eq(const char *a, size_t na, const char *b) {
    size_t nb = strlen(b);
    if (na != nb) {
        return 0;
    }
    for (size_t i = 0; i < na; i++) {
        if (gpl_lower((unsigned char)a[i]) != gpl_lower((unsigned char)b[i])) {
            return 0;
        }
    }
    return 1;
}

/** Case-insensitive literal match at `pos` (literal must be lowercase). */
static int gpl_ci_at(const char *s, size_t n, size_t pos, const char *literal) {
    for (size_t i = 0; literal[i] != '\0'; i++) {
        if (pos + i >= n) {
            return 0;
        }
        if (gpl_lower((unsigned char)s[pos + i]) != (unsigned char)literal[i]) {
            return 0;
        }
    }
    return 1;
}

static int gpl_contains(const char *s, size_t n, const char *literal) {
    size_t m = strlen(literal);
    if (m == 0 || n < m) {
        return 0;
    }
    for (size_t i = 0; i + m <= n; i++) {
        if (gpl_ci_at(s, n, i, literal)) {
            return 1;
        }
    }
    return 0;
}

static size_t gpl_trim_start(const char *s, size_t n) {
    size_t i = 0;
    while (i < n && gpl_is_space((unsigned char)s[i])) {
        i++;
    }
    return i;
}

static size_t gpl_trim_end(const char *s, size_t n) {
    while (n > 0 && gpl_is_space((unsigned char)s[n - 1])) {
        n--;
    }
    return n;
}

/** Parses `-?digits(.digits)?` without touching the locale. Returns 1 on a match. */
static int gpl_parse_double(const char *s, size_t n, size_t pos, double *out, size_t *consumed) {
    size_t i = pos;
    int negative = 0;
    if (i < n && (s[i] == '-' || s[i] == '+')) {
        negative = (s[i] == '-');
        i++;
    }
    double value = 0.0;
    size_t digits = 0;
    while (i < n && s[i] >= '0' && s[i] <= '9') {
        value = value * 10.0 + (double)(s[i] - '0');
        i++;
        digits++;
    }
    if (i < n && s[i] == '.') {
        i++;
        double scale = 0.1;
        while (i < n && s[i] >= '0' && s[i] <= '9') {
            value += (double)(s[i] - '0') * scale;
            scale *= 0.1;
            i++;
            digits++;
        }
    }
    if (digits == 0) {
        return 0;
    }
    if (out != NULL) {
        *out = negative ? -value : value;
    }
    if (consumed != NULL) {
        *consumed = i - pos;
    }
    return 1;
}

/** Parses "lat , lon" starting at `pos`. Returns 1 and the used byte count. */
static int gpl_parse_pair(const char *s, size_t n, size_t pos,
                          double *latitude, double *longitude, size_t *consumed) {
    size_t i = pos;
    size_t used = 0;
    double lat = 0.0;
    double lon = 0.0;

    if (!gpl_parse_double(s, n, i, &lat, &used)) {
        return 0;
    }
    i += used;
    while (i < n && gpl_is_space((unsigned char)s[i])) {
        i++;
    }
    if (i >= n || s[i] != ',') {
        return 0;
    }
    i++;
    while (i < n && gpl_is_space((unsigned char)s[i])) {
        i++;
    }
    if (!gpl_parse_double(s, n, i, &lon, &used)) {
        return 0;
    }
    i += used;

    if (latitude != NULL) {
        *latitude = lat;
    }
    if (longitude != NULL) {
        *longitude = lon;
    }
    if (consumed != NULL) {
        *consumed = i - pos;
    }
    return 1;
}

static int gpl_in_range(double latitude, double longitude) {
    return latitude >= -90.0 && latitude <= 90.0 && longitude >= -180.0 && longitude <= 180.0;
}

/**
 * Splits a strict `https://` URL and returns the host span. Rejects any byte
 * <= 0x20 or 0x7f anywhere, and rejects userinfo (`@`) or a port (`:`) inside
 * the authority.
 */
static int gpl_url_host(const char *s, size_t n, size_t *host_offset, size_t *host_length) {
    if (s == NULL || n == 0) {
        return 0;
    }
    for (size_t i = 0; i < n; i++) {
        unsigned char c = (unsigned char)s[i];
        if (c <= 0x20 || c == 0x7f) {
            return 0;
        }
    }
    if (!gpl_ci_at(s, n, 0, "https://")) {
        return 0;
    }
    size_t i = 8;
    size_t start = i;
    while (i < n && s[i] != '/' && s[i] != '?' && s[i] != '#') {
        if (s[i] == '@' || s[i] == ':') {
            return 0;
        }
        i++;
    }
    if (i == start) {
        return 0;
    }
    if (host_offset != NULL) {
        *host_offset = start;
    }
    if (host_length != NULL) {
        *host_length = i - start;
    }
    return 1;
}

/** Provider kind for an allowlisted host. */
static GPSLabMapLinkKind gpl_kind_for_host(const char *host, size_t length) {
    if (gpl_ci_eq(host, length, "maps.apple.com")) {
        return GPSLabMapLinkKindApple;
    }
    if (gpl_ci_eq(host, length, "maps.app.goo.gl") ||
        gpl_ci_eq(host, length, "google.com") ||
        gpl_ci_eq(host, length, "www.google.com") ||
        gpl_ci_eq(host, length, "maps.google.com")) {
        return GPSLabMapLinkKindGoogle;
    }
    return GPSLabMapLinkKindNone;
}

/* -------------------------------------------------------------- public API -- */

int GPSLabMapLinkHostAllowed(const char *host, size_t length) {
    if (host == NULL || length == 0) {
        return 0;
    }
    return gpl_kind_for_host(host, length) != GPSLabMapLinkKindNone ? 1 : 0;
}

int GPSLabMapLinkURLIsTrusted(const char *text, size_t length) {
    size_t host_offset = 0;
    size_t host_length = 0;
    if (!gpl_url_host(text, length, &host_offset, &host_length)) {
        return 0;
    }
    return GPSLabMapLinkHostAllowed(text + host_offset, host_length);
}

int GPSLabMapLinkRedirectAllowed(int next_hop_index, int max_hops,
                                 const char *text, size_t length) {
    if (next_hop_index < 0 || max_hops <= 0 || next_hop_index >= max_hops) {
        return 0;
    }
    return GPSLabMapLinkURLIsTrusted(text, length);
}

int GPSLabMapLinkParseURLCoordinates(const char *s, size_t n,
                                     double *latitude, double *longitude) {
    if (s == NULL || n == 0) {
        return 0;
    }
    double lat = 0.0;
    double lon = 0.0;
    size_t used = 0;

    /* Google: @lat,lon */
    for (size_t i = 0; i < n; i++) {
        if (s[i] == '@' && gpl_parse_pair(s, n, i + 1, &lat, &lon, &used) &&
            gpl_in_range(lat, lon)) {
            if (latitude != NULL) {
                *latitude = lat;
            }
            if (longitude != NULL) {
                *longitude = lon;
            }
            return 1;
        }
    }

    /* Google: !3dlat ... !4dlon */
    for (size_t i = 0; i + 3 < n; i++) {
        if (s[i] == '!' && s[i + 1] == '3' && s[i + 2] == 'd') {
            double found = 0.0;
            if (!gpl_parse_double(s, n, i + 3, &found, &used)) {
                continue;
            }
            for (size_t j = i + 3 + used; j + 3 < n; j++) {
                if (s[j] == '!' && s[j + 1] == '4' && s[j + 2] == 'd') {
                    double foundLon = 0.0;
                    if (gpl_parse_double(s, n, j + 3, &foundLon, &used) &&
                        gpl_in_range(found, foundLon)) {
                        if (latitude != NULL) {
                            *latitude = found;
                        }
                        if (longitude != NULL) {
                            *longitude = foundLon;
                        }
                        return 1;
                    }
                    break;
                }
            }
        }
    }

    /* Query forms: ll=, coordinate=, q=, sll=, center=, daddr=, destination= */
    static const char *const keys[] = {
        "ll", "coordinate", "q", "sll", "center", "daddr", "destination",
    };
    const size_t key_count = sizeof(keys) / sizeof(keys[0]);
    for (size_t i = 0; i < n; i++) {
        if (i != 0 && s[i - 1] != '?' && s[i - 1] != '&') {
            continue;
        }
        for (size_t k = 0; k < key_count; k++) {
            size_t key_length = strlen(keys[k]);
            if (!gpl_ci_at(s, n, i, keys[k])) {
                continue;
            }
            size_t eq = i + key_length;
            if (eq >= n || s[eq] != '=') {
                continue;
            }
            if (gpl_parse_pair(s, n, eq + 1, &lat, &lon, &used) && gpl_in_range(lat, lon)) {
                if (latitude != NULL) {
                    *latitude = lat;
                }
                if (longitude != NULL) {
                    *longitude = lon;
                }
                return 1;
            }
        }
    }

    return 0;
}

/** Bare allowlisted-host link (no scheme): host = bytes up to `/ ? #` or end. */
static int gpl_bare_host_kind(const char *s, size_t n, GPSLabMapLinkKind *kind) {
    if (n == 0) {
        return 0;
    }
    size_t i = 0;
    while (i < n && s[i] != '/' && s[i] != '?' && s[i] != '#') {
        if (gpl_is_space((unsigned char)s[i])) {
            return 0;
        }
        i++;
    }
    if (i == 0) {
        return 0;
    }
    GPSLabMapLinkKind found = gpl_kind_for_host(s, i);
    if (found == GPSLabMapLinkKindNone) {
        return 0;
    }
    if (kind != NULL) {
        *kind = found;
    }
    return 1;
}

size_t GPSLabMapLinkNormalizedURL(const char *text, size_t length, char *out, size_t out_size) {
    if (text == NULL || out == NULL || out_size == 0) {
        return 0;
    }
    size_t start = gpl_trim_start(text, length);
    size_t end = gpl_trim_end(text + start, length - start);
    const char *s = text + start;
    size_t n = end;
    if (n == 0) {
        return 0;
    }

    static const char *const scheme = "https://";
    size_t scheme_length = strlen(scheme);
    size_t host_offset = 0;
    size_t host_length = 0;

    if (gpl_url_host(s, n, &host_offset, &host_length)) {
        /* Already an absolute URL: only keep it when the host is trusted. */
        if (!GPSLabMapLinkHostAllowed(s + host_offset, host_length)) {
            return 0;
        }
        if (n + 1 > out_size) {
            return 0;
        }
        memcpy(out, s, n);
        out[n] = '\0';
        return n;
    }
    if (gpl_contains(s, n, "://")) {
        return 0; /* explicit but non-https / malformed */
    }
    /* Bare allowlisted host: prefix with https:// after re-checking the host. */
    if (!gpl_bare_host_kind(s, n, NULL)) {
        return 0;
    }
    if (scheme_length + n + 1 > out_size) {
        return 0;
    }
    memcpy(out, scheme, scheme_length);
    memcpy(out + scheme_length, s, n);
    out[scheme_length + n] = '\0';
    return scheme_length + n;
}

GPSLabMapLink GPSLabMapLinkParseText(const char *text, size_t length) {
    GPSLabMapLink link;
    link.result = GPSLabMapLinkParseNone;
    link.kind = GPSLabMapLinkKindNone;
    link.latitude = 0.0;
    link.longitude = 0.0;

    if (text == NULL || length == 0) {
        return link;
    }
    size_t start = gpl_trim_start(text, length);
    size_t end = gpl_trim_end(text + start, length - start);
    const char *s = text + start;
    size_t n = end;

    if (n == 0) {
        return link;
    }

    /* 1) A plain "lat, lon" pair typed directly. */
    double lat = 0.0;
    double lon = 0.0;
    size_t used = 0;
    if (gpl_parse_pair(s, n, 0, &lat, &lon, &used)) {
        size_t rest = used;
        while (rest < n && gpl_is_space((unsigned char)s[rest])) {
            rest++;
        }
        if (rest == n) {
            if (gpl_in_range(lat, lon)) {
                link.result = GPSLabMapLinkParseCoordinates;
                link.kind = GPSLabMapLinkKindCoordinates;
                link.latitude = lat;
                link.longitude = lon;
            } else {
                link.result = GPSLabMapLinkParseRejected;
            }
            return link;
        }
    }

    /* 2) A strict https:// URL on the allowlist. */
    size_t host_offset = 0;
    size_t host_length = 0;
    if (gpl_url_host(s, n, &host_offset, &host_length)) {
        if (!GPSLabMapLinkHostAllowed(s + host_offset, host_length)) {
            link.result = GPSLabMapLinkParseRejected;
            return link;
        }
        link.kind = gpl_kind_for_host(s + host_offset, host_length);
        if (GPSLabMapLinkParseURLCoordinates(s, n, &lat, &lon)) {
            link.result = GPSLabMapLinkParseURLWithCoordinates;
            link.latitude = lat;
            link.longitude = lon;
        } else {
            link.result = GPSLabMapLinkParseShortLink;
        }
        return link;
    }

    /* 3) A bare allowlisted host link ("maps.apple.com/?ll=..."). */
    if (gpl_contains(s, n, "://")) {
        link.result = GPSLabMapLinkParseRejected;
        return link;
    }
    GPSLabMapLinkKind bare_kind = GPSLabMapLinkKindNone;
    if (gpl_bare_host_kind(s, n, &bare_kind)) {
        link.kind = bare_kind;
        if (GPSLabMapLinkParseURLCoordinates(s, n, &lat, &lon)) {
            link.result = GPSLabMapLinkParseURLWithCoordinates;
            link.latitude = lat;
            link.longitude = lon;
        } else {
            link.result = GPSLabMapLinkParseShortLink;
        }
        return link;
    }

    return link;
}
