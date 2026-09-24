//
//  GPSLabPortalPolicy.h
//  GPSLab
//
//  Pure C security policy for the web-portal UX that supports the signed
//  entitlement: browser account/sign-in/manage/trial/help links, the device
//  pairing proof and the in-app feedback payload.
//
//  Why a shared C policy: both the dylib and the portable Linux tests compile
//  this exact file, so the "HTTPS only, same origin, no embedded credentials,
//  no identifiers/tokens in the URL" rules are unit-tested without Foundation.
//
//  Rules enforced here (fail closed):
//    * a portal URL must be exactly https://, contain no userinfo ('@') and no
//      control/whitespace/quote characters;
//    * its origin (scheme + host + optional port) must equal the license
//      endpoint origin, so a compromised host plist cannot redirect the signed
//      user to an attacker or exfiltrate the installation;
//    * the query/fragment must not carry installationId/deviceSecret/
//      refreshToken/activationCode (the app never builds such URLs);
//    * pairing codes are display-only, length-bounded and charset-restricted;
//    * feedback categories are a fixed allow-list and messages are byte-bounded
//      on a UTF-8 boundary.
//
//  No Foundation/UIKit dependency; no secret ever lives here.
//

#ifndef GPSLAB_PORTAL_POLICY_H
#define GPSLAB_PORTAL_POLICY_H

#include <stddef.h>

/** Upper bound accepted for any portal URL (bytes). */
#define GPSLAB_PORTAL_MAX_URL 512

/** Upper bound accepted for an in-app feedback message (UTF-8 bytes). */
#define GPSLAB_PORTAL_MAX_FEEDBACK_BYTES 2000

/** Pairing code bounds (printable ASCII only). */
#define GPSLAB_PORTAL_MIN_PAIRING_CODE 4
#define GPSLAB_PORTAL_MAX_PAIRING_CODE 128

/**
 * Extracts the canonical origin ("https://host[:port]") of `url`.
 * Returns the written length (excluding the NUL) or 0 when `url` is not exactly
 * HTTPS, has no host, carries userinfo, or contains a non-origin character.
 * The port is preserved when present; a default port is not synthesized.
 */
size_t GPSLabPortalOriginFromURL(const char *url, char *out, size_t outSize);

/**
 * Returns 1 only when `url` is a safe HTTPS URL whose origin exactly equals
 * `allowedOrigin` and that embeds no identifier/token query parameter.
 */
int GPSLabPortalURLIsSafe(const char *url, const char *allowedOrigin);

/**
 * Returns 1 when `url` carries userinfo ("user@host") or a query/fragment
 * parameter that would leak the installation id, device secret, refresh token
 * or activation code. Independent of origin checking.
 */
int GPSLabPortalURLHasEmbeddedCredential(const char *url);

/**
 * Returns 1 when `statusCode` is any HTTP 2xx success. The device endpoints
 * answer 200 (pairing) and 201 Created (feedback), so the client must never
 * special-case HTTP 200 as the only success.
 */
int GPSLabPortalStatusIsSuccess(int statusCode);

/** Number of feedback categories in the fixed allow-list. */
int GPSLabPortalFeedbackCategoryCount(void);

/** Category token at `index` (e.g. "bug"), or NULL when out of range. */
const char *GPSLabPortalFeedbackCategoryAt(int index);

/** Returns 1 when `category` is one of the fixed allow-listed tokens. */
int GPSLabPortalFeedbackCategoryIsValid(const char *category);

/**
 * Copies `message` into `out`, truncating on a UTF-8 code point boundary so the
 * result is always at most `outSize - 1` bytes plus the NUL. Control bytes other
 * than tab/newline are dropped. Returns the written length or 0 on bad input.
 */
size_t GPSLabPortalBoundFeedback(const char *message, char *out, size_t outSize);

/**
 * Returns 1 when `code` is a plausible display-only one-time pairing code:
 * length-bounded and composed solely of ASCII letters, digits and '-'/'_'.
 */
int GPSLabPortalPairingCodeIsSafe(const char *code);

#endif /* GPSLAB_PORTAL_POLICY_H */
