//
//  GPSLabPortalPolicy.c
//  GPSLab
//
//  Portable, Foundation-free implementation of the web-portal security policy.
//  Compiled into the dylib and into the portable CI tests; no secrets live here.
//

#include "GPSLabPortalPolicy.h"

#include <ctype.h>
#include <string.h>

/* --- Small ASCII helpers (never locale-dependent) --- */

static char gpslab_ascii_lower(char c) {
    if (c >= 'A' && c <= 'Z') {
        return (char)(c - 'A' + 'a');
    }
    return c;
}

static int gpslab_prefix_ci(const char *string, const char *prefix) {
    while (*prefix != '\0') {
        if (*string == '\0' || gpslab_ascii_lower(*string) != gpslab_ascii_lower(*prefix)) {
            return 0;
        }
        string++;
        prefix++;
    }
    return 1;
}

static int gpslab_contains_ci(const char *haystack, const char *needle) {
    if (haystack == NULL || needle == NULL || *needle == '\0') {
        return 0;
    }
    size_t needleLength = strlen(needle);
    for (const char *cursor = haystack; *cursor != '\0'; cursor++) {
        size_t matched = 0;
        while (matched < needleLength &&
               cursor[matched] != '\0' &&
               gpslab_ascii_lower(cursor[matched]) == gpslab_ascii_lower(needle[matched])) {
            matched++;
        }
        if (matched == needleLength) {
            return 1;
        }
    }
    return 0;
}

static int gpslab_is_host_char(char c) {
    if (c >= 'a' && c <= 'z') return 1;
    if (c >= 'A' && c <= 'Z') return 1;
    if (c >= '0' && c <= '9') return 1;
    return c == '.' || c == '-';
}

static int gpslab_is_unsafe_url_char(char c) {
    unsigned char byte = (unsigned char)c;
    if (byte <= 0x20 || byte == 0x7F) return 1; /* control + space */
    return c == '\\' || c == '"' || c == '\'' || c == '<' || c == '>';
}

/* Query/fragment parameter names that must never reach a browser URL. */
static int gpslab_has_identifier_parameter(const char *url) {
    static const char * const tokens[] = {
        "installationid=",
        "devicesecret=",
        "refreshtoken=",
        "activationcode=",
        "entitlementid=",
    };
    for (size_t index = 0; index < sizeof(tokens) / sizeof(tokens[0]); index++) {
        if (gpslab_contains_ci(url, tokens[index])) {
            return 1;
        }
    }
    return 0;
}

/* --- Origin parsing --- */

static const char *gpslab_url_authority(const char *url, const char **outEnd) {
    if (url == NULL || !gpslab_prefix_ci(url, "https://")) {
        return NULL;
    }
    const char *authority = url + 8;
    const char *end = authority;
    while (*end != '\0' && *end != '/' && *end != '?' && *end != '#') {
        end++;
    }
    if (end == authority) {
        return NULL;
    }
    if (outEnd != NULL) {
        *outEnd = end;
    }
    return authority;
}

size_t GPSLabPortalOriginFromURL(const char *url, char *out, size_t outSize) {
    if (url == NULL || out == NULL || outSize == 0) {
        return 0;
    }
    const char *end = NULL;
    const char *authority = gpslab_url_authority(url, &end);
    if (authority == NULL) {
        return 0;
    }

    /* Reject userinfo: no '@' before the end of the authority. */
    for (const char *cursor = authority; cursor < end; cursor++) {
        if (*cursor == '@') {
            return 0;
        }
    }

    /* Split host[:port]. */
    const char *colon = NULL;
    for (const char *cursor = authority; cursor < end; cursor++) {
        if (*cursor == ':') {
            colon = cursor;
            break;
        }
    }
    const char *hostEnd = (colon != NULL) ? colon : end;
    if (hostEnd == authority) {
        return 0;
    }

    size_t hostLength = (size_t)(hostEnd - authority);
    if (hostLength > 253) {
        return 0;
    }
    if (authority[0] == '.' || authority[0] == '-' ||
        hostEnd[-1] == '.' || hostEnd[-1] == '-') {
        return 0;
    }
    for (const char *cursor = authority; cursor < hostEnd; cursor++) {
        if (!gpslab_is_host_char(*cursor)) {
            return 0;
        }
        if (cursor + 1 < hostEnd && cursor[0] == '.' && cursor[1] == '.') {
            return 0;
        }
    }

    size_t portLength = 0;
    if (colon != NULL) {
        if (colon + 1 == end) {
            return 0;
        }
        unsigned long port = 0;
        for (const char *cursor = colon + 1; cursor < end; cursor++) {
            if (*cursor < '0' || *cursor > '9') {
                return 0;
            }
            port = port * 10UL + (unsigned long)(*cursor - '0');
            if (port > 65535UL) {
                return 0;
            }
        }
        if (port == 0) {
            return 0;
        }
        portLength = (size_t)(end - (colon + 1));
    }

    size_t needed = 8 + (size_t)(end - authority);
    (void)portLength;
    if (outSize < needed + 1) {
        return 0;
    }
    memcpy(out, "https://", 8);
    memcpy(out + 8, authority, (size_t)(end - authority));
    out[needed] = '\0';
    return needed;
}

int GPSLabPortalURLHasEmbeddedCredential(const char *url) {
    if (url == NULL) {
        return 1;
    }
    size_t length = strlen(url);
    if (length == 0 || length > GPSLAB_PORTAL_MAX_URL) {
        return 1;
    }
    for (size_t index = 0; index < length; index++) {
        if (gpslab_is_unsafe_url_char(url[index])) {
            return 1;
        }
    }

    const char *separator = strstr(url, "://");
    if (separator != NULL) {
        const char *authority = separator + 3;
        const char *end = authority;
        while (*end != '\0' && *end != '/' && *end != '?' && *end != '#') {
            end++;
        }
        for (const char *cursor = authority; cursor < end; cursor++) {
            if (*cursor == '@') {
                return 1;
            }
        }
    } else {
        const char *end = url;
        while (*end != '\0' && *end != '/' && *end != '?' && *end != '#') {
            end++;
        }
        for (const char *cursor = url; cursor < end; cursor++) {
            if (*cursor == '@') {
                return 1;
            }
        }
    }

    return gpslab_has_identifier_parameter(url);
}

int GPSLabPortalURLIsSafe(const char *url, const char *allowedOrigin) {
    if (url == NULL || allowedOrigin == NULL) {
        return 0;
    }
    size_t length = strlen(url);
    if (length == 0 || length > GPSLAB_PORTAL_MAX_URL) {
        return 0;
    }
    if (!gpslab_prefix_ci(url, "https://")) {
        return 0;
    }
    if (GPSLabPortalURLHasEmbeddedCredential(url)) {
        return 0;
    }

    char origin[GPSLAB_PORTAL_MAX_URL + 1];
    size_t originLength = GPSLabPortalOriginFromURL(url, origin, sizeof(origin));
    if (originLength == 0) {
        return 0;
    }

    char allowed[GPSLAB_PORTAL_MAX_URL + 1];
    size_t allowedLength = GPSLabPortalOriginFromURL(allowedOrigin, allowed, sizeof(allowed));
    if (allowedLength == 0 || allowedLength != originLength) {
        return 0;
    }
    for (size_t index = 0; index < originLength; index++) {
        if (gpslab_ascii_lower(origin[index]) != gpslab_ascii_lower(allowed[index])) {
            return 0;
        }
    }
    return 1;
}

/* --- Transport success --- */

int GPSLabPortalStatusIsSuccess(int statusCode) {
    return statusCode >= 200 && statusCode <= 299;
}

/* --- Feedback policy --- */

/* Must match the server's fixed category enum exactly
 * (`bug|feature|billing|account|trial|other`). */
static const char * const kGPSLabFeedbackCategories[] = {
    "bug",
    "feature",
    "billing",
    "account",
    "trial",
    "other",
};

int GPSLabPortalFeedbackCategoryCount(void) {
    return (int)(sizeof(kGPSLabFeedbackCategories) / sizeof(kGPSLabFeedbackCategories[0]));
}

const char *GPSLabPortalFeedbackCategoryAt(int index) {
    if (index < 0 || index >= GPSLabPortalFeedbackCategoryCount()) {
        return NULL;
    }
    return kGPSLabFeedbackCategories[index];
}

int GPSLabPortalFeedbackCategoryIsValid(const char *category) {
    if (category == NULL) {
        return 0;
    }
    for (int index = 0; index < GPSLabPortalFeedbackCategoryCount(); index++) {
        if (strcmp(category, kGPSLabFeedbackCategories[index]) == 0) {
            return 1;
        }
    }
    return 0;
}

size_t GPSLabPortalBoundFeedback(const char *message, char *out, size_t outSize) {
    if (message == NULL || out == NULL || outSize == 0) {
        return 0;
    }
    if (outSize > GPSLAB_PORTAL_MAX_FEEDBACK_BYTES + 1) {
        outSize = GPSLAB_PORTAL_MAX_FEEDBACK_BYTES + 1;
    }

    size_t inputLength = strlen(message);
    size_t written = 0;
    size_t index = 0;
    while (index < inputLength) {
        unsigned char lead = (unsigned char)message[index];
        size_t sequenceLength = 1;
        if (lead < 0x80) {
            if ((lead < 0x20 && lead != '\t' && lead != '\n') || lead == 0x7F) {
                index++;
                continue;
            }
            sequenceLength = 1;
        } else if ((lead & 0xE0) == 0xC0) {
            sequenceLength = 2;
        } else if ((lead & 0xF0) == 0xE0) {
            sequenceLength = 3;
        } else if ((lead & 0xF8) == 0xF0) {
            sequenceLength = 4;
        }
        if (index + sequenceLength > inputLength) {
            sequenceLength = 1;
        }
        if (written + sequenceLength >= outSize) {
            break;
        }
        memcpy(out + written, message + index, sequenceLength);
        written += sequenceLength;
        index += sequenceLength;
    }
    out[written] = '\0';
    return written;
}

/* --- Pairing code --- */

int GPSLabPortalPairingCodeIsSafe(const char *code) {
    if (code == NULL) {
        return 0;
    }
    size_t length = strlen(code);
    if (length < GPSLAB_PORTAL_MIN_PAIRING_CODE || length > GPSLAB_PORTAL_MAX_PAIRING_CODE) {
        return 0;
    }
    for (size_t index = 0; index < length; index++) {
        unsigned char byte = (unsigned char)code[index];
        if ((byte >= '0' && byte <= '9') ||
            (byte >= 'a' && byte <= 'z') ||
            (byte >= 'A' && byte <= 'Z') ||
            byte == '-' || byte == '_') {
            continue;
        }
        return 0;
    }
    return 1;
}
