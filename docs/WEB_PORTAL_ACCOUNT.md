# Web portal, account, trial pairing and feedback

This document describes the client-side UX and APIs added around the signed-license
backend. It does **not** replace the entitlement design in the README; the license
provider, the ES256 verification, the foreground reconcile and the fail-closed gate
are unchanged.

## UX surface

`GPSLabPortalViewController` (an account/support sheet) is reachable in every state:

| State    | Entry point                                             |
|----------|---------------------------------------------------------|
| Locked   | Subscription screen → **Account & Support** (`subscription.account`) |
| Unlocked | Map canvas → Options sheet → **Account & Support** (`options.account`) |

It contains:

- Subscription status, plan and expiry (read from `GPSLabLicenseManager`; unchanged).
- **Refresh status** – an explicit, localized state at tapping, then `Refresh status`
  again in the existing foreground reconcile flow.
- **Sign In** / **Manage Account** – open the configured safe browser URLs.
- **Trial & device pairing** – requests a one-time pairing code, displays it, copies it
  in-app, and opens the browser `/account/pair` page. The code is never appended to the
  URL and never logged.
- **Help** – opens the configured help URL.
- **Feedback & support** – a category picker and a bounded message posted through the
  device client, with localized loading / offline / error / sent states.

Every browser action is disabled when its safe URL is not configured, with a
plain-language localized reason. Buttons show a spinner while a network call is in
flight.

## HTTP APIs

Both calls are `POST`, `Content-Type: application/json`, `Cache-Control: no-store`,
with a bounded request timeout, an explicit redirect rejection and a streamed response
size cap. They never touch entitlement state. Any HTTP `2xx` is accepted as success
(pairing answers `200`, feedback answers `201 Created`); `200` is not special-cased.

### `POST /api/v1/device/pair`

Request:

```json
{ "installationId": "<uuid>", "deviceSecret": "<base64 32 bytes>" }
```

Response (200):
`{ "installationId": "<uuid>", "code": "<one-time code>", "expiresAt": "<ISO-8601 UTC>" }`.
`expiresAt` is an ISO-8601 UTC timestamp (`Date.toISOString()`); the client does not
gate on it. The client accepts the code only when it is length-bounded and
charset-restricted, then shows it as display-only text.

### `POST /api/v1/device/feedback`

Request:

```json
{ "installationId": "<uuid>", "deviceSecret": "<base64 32 bytes>",
  "category": "bug|feature|billing|account|trial|other", "message": "<bounded UTF-8>" }
```

Response (201 Created). The message is truncated on a UTF-8 boundary at 2000 bytes;
the category must be one of the fixed allow-list tokens of the server enum.

## Configuration

All portal values are HTTPS-only, must share the license endpoint's **exact origin**
(`scheme://host[:port]`), and are rejected when they carry userinfo or a
`installationId` / `refreshToken` / `deviceSecret` / `activationCode` query. When a
value is absent it is derived from the endpoint origin.

Build macros (see `Source/GPSLabLicenseBuildConfig.h`):

- `GPSLAB_LICENSE_BUILD_PORTAL_URL` → `/account`
- `GPSLAB_LICENSE_BUILD_TRIAL_URL` → `/account/pair`
- `GPSLAB_LICENSE_BUILD_HELP_URL` → `/help`
- `GPSLAB_LICENSE_BUILD_PAIR_ENDPOINT` → `/api/v1/device/pair`
- `GPSLAB_LICENSE_BUILD_FEEDBACK_ENDPOINT` → `/api/v1/device/feedback`
- (`GPSLAB_LICENSE_BUILD_SIGN_IN_URL`, `GPSLAB_LICENSE_BUILD_MANAGE_URL` as before)

Host `Info.plist` keys: `GPSLabPortalURL`, `GPSLabTrialPairingURL`, `GPSLabHelpURL`,
`GPSLabPairingEndpoint`, `GPSLabFeedbackEndpoint` (plus the existing `GPSLabSignInURL`,
`GPSLabManageAccountURL`, `GPSLabLicenseEndpoint`).

Never place a signing key, password or API secret in any of these.

## Security posture

- `deviceSecret` is a per-installation 32-byte Keychain value (`SecRandomCopyBytes`),
  separate from license material; `clearLicenseMaterial` does not remove it.
- The proof is sent only in the JSON request body over HTTPS to the license origin.
- Redirects are never followed, so the proof cannot be forwarded to another host.
- Pairing codes and feedback messages are never written to the console; the diagnostics
  allow-list is unchanged.
- No new license provider, no private key, no on-device signing.

## Tests

- `tests/gpslab_portal_policy_test.c` – portable unit tests for the URL/feedback/code
  policy.
- `tests/GPSLabPortalTests.m` – macOS Foundation tests for the config derivation and the
  device request builders.
- `tests/gpslab_portal_ui_wiring_test.c` – source-validated UI wiring assertions.

## Limitations

- The pairing/feedback server endpoints are implemented by the sibling backend project
  (in progress); this repository defines and tests only the client contract.
- The pairing response is authenticated by the device proof, not a signed envelope; a
  successful code therefore does not by itself change entitlement — the user completes
  pairing in the browser and the app learns the result through the existing license
  reconcile.
- Browser URLs and the device secret are validated, but the portal page itself is
  outside this app's trust boundary.
