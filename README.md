# GPSLab

`GPSLab` is a clean-room Objective-C dylib that provides a deterministic, synthetic
CoreLocation stream for **authorized testing on devices you own** (for example, QA
builds that need a fixed or simulated coordinate without touching real location
hardware). It ships a floating, gesture-activated overlay so the synthetic state can
be configured from inside the host app.

> Intended exclusively for testing in environments you are authorized to modify.
> Do not use it to deceive users or violate any service's terms.

## Clean-room statement

- Written from scratch against Apple's public headers, the Objective-C runtime
  documentation (`<objc/runtime.h>`), CoreLocation, UIKit and MapKit.
- No source code was copied from, or derived from, any existing tweak or location
  spoofing project.
- It does not link or load any hooking framework (no Substrate, ElleKit, or
  libhooker). Method interception uses only the public Objective-C runtime
  (`class_getInstanceMethod`, `class_replaceMethod`, ...).
- No private frameworks, no `dlopen`/`dlsym`, no external package dependencies.

## Requirements

- Theos with an iOS SDK >= 16.0
- `arm64` toolchain (the Theos Linux toolchain works)

## Build

```sh
make clean
make
```

The product is written to `.theos/obj/GPSLab.dylib` with the install name
`@executable_path/Frameworks/GPSLab.dylib`.

Then:

1. Copy the dylib to `<App.app>/Frameworks/GPSLab.dylib`.
2. Add an `LC_LOAD_DYLIB` entry (for example with `insert_dylib`) in a build you own.
3. Re-sign the app.

See `TEST_PLAN.md` for the full validation matrix (static, automated and
device-manual cases, including clean and previously-tested IPAs).

## Architecture (v1.0)

```
GPSLabConfiguration        validated in-memory state (allow-listed fields)
GPSLabStore                NSUserDefaults suite persistence (config/bookmarks/recents)
GPSLabEngine               thread-safe engine: enabled switch, anchor, drift, route
  ├─ GPSLabDriftModel      bounded correlated random walk around the anchor
  ├─ GPSLabRouteSimulator  MKDirections / straight-line route, time-driven progress
  └─ GPSLabLocationFactory synthetic CLLocation with fresh timestamp + accuracy bands
GPSLabLocationStream       per-manager streams; intent preserved across suspend/resume
GPSLabCoreLocationHooks    runtime-only swizzling; captured originals; per-manager bypass
GPSLabRuntime              lifecycle coordinator (scene/window/foreground/background)
  ├─ GPSLabGestureActivator    3-finger ~0.9 s hold (constants centralized in the header)
  ├─ GPSLabOverlayPresenter    floating UIWindow on the active UIWindowScene
  │    └─ GPSLabPrimaryInterface  single selection point (overlay today; subscription seam later)
  └─ GPSLabOverlayViewController  map-first canvas: MKMapView owns the safe area
       ├─ GPSLabManualEntryViewController   validated lat/lon/alt/course sheet
       ├─ GPSLabFavoritesViewController     add / select / rename / delete
       ├─ GPSLabRecentsViewController       select / delete / clear (cap 20, 5 m de-dupe)
       ├─ GPSLabFluctuationViewController   drift toggle + radius
       ├─ GPSLabRouteViewController         mode / speed / endpoints / playback
       ├─ GPSLabOptionsViewController       keep-last, map style, real-location
       └─ GPSLabSearchResultsViewController MKLocalSearch results (stale-guarded)
GPSLabLicenseManager       fail-closed entitlement coordinator (engine gate + states)
  ├─ GPSLabLicensePolicy   pure-C bounded state/time/rollback policy (shared with tests)
  ├─ GPSLabLicenseConfig   macros -> Info.plist -> EMPTY (independent build config)
  ├─ GPSLabTokenVerifier   Security.framework P-256 / SHA-256 envelope verification
  ├─ GPSLabSecureStore     Keychain-only installation UUID/token/meta/refresh
  ├─ GPSLabEntitlement     resolved state snapshot (Active/Grace = unlocked)
  └─ GPSLabSubscriptionViewController  status + Activate/Sign In/Restore/Try Again/Manage
GPSLabStatusLog            bounded, non-sensitive status text for the overlay
Diagnostics                os_log only; allowed events; never logs coordinates
```

## Behavior

- **Master switch.** Synthetic output requires both this switch and a verified,
  unlocked entitlement (see Licensing); a persisted `enabled` value can never bypass
  the gate. When enabled is OFF, every intercepted selector forwards to its
  captured original CoreLocation implementation and no synthetic data is produced.
  Synthetic timers are suspended while the recorded per-manager intent is kept; the
  managers that had requested updates are handed back to real CoreLocation. Turning
  it back on stops those original streams and resumes the synthetic ones. A request
  made while disabled is forwarded to the original implementation **and** recorded, so
  it resumes synthetically on enable; a stop made while disabled forwards to the
  original and clears the recorded intent.
- **Per-manager intent.** What the host requested (standard / significant) is tracked
  independently from whether a synthetic timer is running, so background/foreground and
  enable/disable never lose the request. Backgrounding suspends synthetic timers and
  keeps the intent; foreground resumes them when the engine is enabled.
- **Anchor.** The synthetic coordinate, altitude and course are configurable from the
  overlay (validated manual entry, map tap/long-press/draggable pin, `MKLocalSearch`,
  bookmarks, recents) and persisted with the allow-listed fields only.
- **Keep last coordinate.** Only while this toggle is on are latitude/longitude/
  altitude/heading persisted and restored at next launch. Turning it off erases the
  stored coordinate keys and resets the anchor to safe defaults; the rest of the
  allow-list (bookmarks, recents, route prefs, drift, enabled) is unaffected.
- **Drift.** A bounded correlated random walk around the anchor. The generated point
  never exceeds the configured radius (default 8 m, geodesically clamped twice).
- **Route simulation.** Driving/Walking use `MKDirections`; Cycling is approximated
  with the walking pedestrian network because the public `MKDirectionsTransportType`
  has no cycling constant, while still using the configured cycling speed
  (15 km/h default). Custom interpolates a straight line. Default speeds are
  5/15/50 km/h for walking/cycling/driving. Play/pause/stop, progress and
  cancellation are supported; stop behavior is "stay at current" or "return to
  start". Route fixes derive `course` and `speed` from the geometry.
- **Stationary fixes.** `speed` is 0 and `course` is the configured course (or -1 when
  set to an invalid value). Timestamps are always fresh. Horizontal/vertical accuracy
  vary inside realistic bands.
- **Streams.** Standard updates arrive immediately and then once per second;
  significant-change updates arrive immediately and then once every 30 seconds;
  `requestLocation` delivers exactly one fix.
- **Multiple managers.** Every `CLLocationManager` is held weakly and owns its own
  timers; stopping one never affects another. Nil delegates are safe.
- **Real-location display.** The overlay's "Show real user location" switch uses a
  dedicated, bypassed `CLLocationManager`: the hook layer routes every call for it to
  the original implementation, and its coordinate is drawn on a separate annotation
  (never via `MKMapView.showsUserLocation`) without being persisted or logged. It is
  only shown while the user has the switch on.

## Overlay

- **Activation:** press and hold with **exactly three fingers for about 0.9 s**
  anywhere in the host app. A three-finger tap does not activate; lifting any finger
  before the duration cancels; movement beyond a conservative threshold cancels; a
  ~1 s cooldown prevents retriggering from leftover fingers. The recognizer does not
  cancel host touches (`cancelsTouchesInView = NO`) and recognizes simultaneously
  with existing gestures. The constants live in `GPSLabGestureActivator.h`.
- **Map-first canvas:** the `MKMapView` owns the remaining safe area (it is a direct
  subview, never inside a scrolling panel). The header (status, master enable, search,
  settings, close), a real always-visible `UISearchBar` (the `UISearchController`'s own
  bar, not a magnifier button), the floating circular controls (center, favorites,
  route, options) and the route-pick banner float above it using native materials, SF
  Symbols and rounded corners. Tap/long-press select the anchor immediately and a
  draggable synthetic pin does the same; MapKit pan/zoom/rotate/pitch keep working.
- **Sheets:** configuration lives in small native sheets: manual coordinate (validated
  lat/lon/alt/course), favorites (add/select/rename/delete), recents (select/delete/
  clear; the 20-entry cap and 5 m de-duplication live in the store), location
  fluctuation (drift toggle + radius), route (walking 5 / cycling 15 / driving 50 km/h
  or custom; map start/end selection with annotations and a traversed polyline;
  play/pause/resume/stop/progress) and options (keep-last, map style, real-location
  display). Search results are concise title/subtitle rows and are generation-guarded
  so a stale response never replaces a newer one.
- **Real location:** the "Show real user location" option uses a dedicated bypassed
  `CLLocationManager` (never persisted, never logged, no automatic authorization
  request) and draws a distinct green annotation; `MKMapView.showsUserLocation` is
  never used.
- **Dismissal:** the header **Close** button removes the overlay window entirely;
  the host app becomes fully interactive again with no restart.
- **Scenes:** the window is created on the active `UIWindowScene` and re-created if
  the scene changes. Layout follows the safe area, supports both orientations and
  Dynamic Type, and adapts to dark/light mode through system materials and dynamic
  colors. The presenter selects the primary interface through `GPSLabPrimaryInterface`,
  the single seam for a future subscription screen.

## Persistence allow-list

Only these values are ever written, to the `com.gpslab.runtime` `NSUserDefaults`
suite, under `GPSLab.*` keys:

- `enabled`
- `driftEnabled`, `driftRadiusMeters`
- `keepLastCoordinate`
- route `routeMode`, `routeCustomSpeedKmh`, `stopBehavior`
- bookmarks (name + coordinate + altitude)
- recents (coordinate + altitude, capped at 20, de-duplicated within 5 m)
- UI language (`GPSLab.language`: `ar`/`en`; GPSLab-scoped, defaults to Arabic)
- anchor `latitude`, `longitude`, `altitude`, `heading` — **only while
  `keepLastCoordinate` is on**

Corrupted entries are validated field-by-field and fall back to safe defaults; a bad
payload never crashes the host. Host application data and real device location are
never stored or logged.

## Licensing (signed subscription)

GPSLab is fail-closed: the synthetic engine never runs without a verified entitlement.

### Configuration (host app Info.plist; all optional, all EMPTY by default)

| Key | Meaning |
|-----|---------|
| `GPSLabLicenseEndpoint` | HTTPS endpoint that returns a signed entitlement envelope |
| `GPSLabLicensePublicKey` | base64 DER SubjectPublicKeyInfo, or raw X9.63 point |
| `GPSLabSignInURL` | external sign-in page |
| `GPSLabManageAccountURL` | external account management page |
| `GPSLabLicenseIssuer` | expected `issuer` claim (recommended) |
| `GPSLabLicenseAudience` | expected `audience` claim (recommended) |
| `GPSLabMaxOfflineGraceSeconds` | local cap on `graceUntil - expiresAt` (default 604800) |
| `GPSLabMaxClockSkewSeconds` | allowed future skew for `issuedAt` (default 300) |

Resolution order: **GPSLab build-time macros** (`Source/GPSLabLicenseBuildConfig.h`,
generated at package time, or `-DGPSLAB_LICENSE_BUILD_*` flags) override the host
Info.plist, which overrides empty defaults. This lets one GPSLab build carry its own
public configuration without editing the host app; the header ships empty and contains
no private key.

A verification public key is public material, not a secret; never ship a signing
private key or a pre-baked token. With no endpoint or key, the app is locked and the
subscription screen states plainly that the service is not configured in this build.

### Wire contract

Request: `POST` (HTTPS) `{"installationId": "<UUID>", "refreshToken": "...", "activationCode": "..."}`.

Response envelope:

```json
{
  "version": 1,
  "alg": "ES256",
  "payload": "<base64url of the UTF-8 payload JSON>",
  "signature": "<base64url DER ECDSA P-256 SHA-256 signature over the payload bytes>",
  "refreshToken": "<optional>"
}
```

Payload claims: `entitlementId`, `installationId`, `plan`, `status`
(`active|grace|expired|revoked`), `issuedAt`, `expiresAt`, `graceUntil`, `issuer`,
`audience`. Timestamps are Unix seconds and must be integral, positive and within
`2100-01-01`; `issuedAt` may not exceed local time by more than the configured skew.
The server signs its truthful current time, so for the already-lapsed states `grace`,
`expired` and `revoked`, `issuedAt` may legitimately exceed `expiresAt`; `grace` still
requires `graceUntil > expiresAt`, and `active` with `issuedAt > expiresAt` (or any other
inconsistent state/time combination) is rejected. The optional envelope `keyId` is a
diagnostic hint and is ignored.

The raw envelope is capped (256 KiB default) and rejected **before** any JSON/base64
work; the payload, encoded payload string, signature string and public key all have
explicit bounds. The public key must be an exact P-256 SubjectPublicKeyInfo
(26-byte prefix + 65-byte X9.63 point) or the raw 65-byte point — arbitrary DER tails
are rejected, and only the extracted point is imported.

Rejected as invalid: malformed JSON, unsupported/ fractional/boolean version or alg,
oversized envelope/payload/signature/key, bad key shape, invalid signature,
missing/invalid claims, installation mismatch, issuer/audience mismatch, or unsafe
timestamps (a future-dated `issuedAt`, an `active` token whose `issuedAt > expiresAt`, or
a `grace` token without a real `graceUntil > expiresAt` window).

### Secure flow

- States (exact): `Unknown, Checking, Active, Grace, Expired, Invalid, Offline`.
  Only `Active` and `Grace` unlock the engine.
- **Async, non-blocking:** the dylib constructor never blocks. All Keychain, crypto,
  JSON and network work runs on a dedicated serial license queue; the engine gate,
  deadline timer and notifications are main-thread only, and results carry a
  monotonically increasing revision so a slow earlier result can never overwrite a
  newer one. The engine defaults to locked until the first async result is published.
- The random installation UUID, the verified token envelope, the metadata clock and
  the refresh token live only in the Keychain
  (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, never synced, never in
  `NSUserDefaults`). The metadata blob is the minimal anti-rollback record
  (last-seen wall/uptime, verification time, authenticated status) and carries no
  host data, PII or coordinates.
- **Bounded network:** only one task is in flight (superseded tasks are cancelled);
  HTTP redirects are rejected outright so an activation code or refresh token is never
  forwarded to another host; the response body is length-capped while streaming and
  the task is cancelled as soon as the cap is exceeded.
- On launch and foreground the verified cache is applied first; a bounded HTTPS check
  runs afterwards. A still-valid cache is never revoked just because a re-check is in
  flight. A signed `revoked` response purges the token; unsigned/malformed responses
  and network failures keep a valid cache while preserving an already-authenticated
  `revoked`/`expired` status (so it cannot decay to Offline).
- A present-but-untrusted token resolves to Invalid, which is deliberately distinct
  from Offline (no service reachable and nothing cached).
- The metadata clock stores wall + uptime so a wall-clock rollback cannot extend an
  entitlement; it is re-observed and persisted on launch, foreground, background and
  at deadline boundaries. This is best-effort tamper deterrence, not hardware
  attestation.
- Offline grace is server-driven (`graceUntil`) and capped locally.
- The gate covers every engine entrypoint and hook: `isEnabled` requires the
  entitlement, route start and synthetic generation are refused while locked, and an
  expiration tears route/drift/streams down and hands requested managers back to real
  CoreLocation without closing the host app or touching host data.
- When locked, the presenter shows `GPSLabSubscriptionViewController` instead of the
  map canvas (Activate / Sign In / Restore / Try Again / Manage Account; every button
  is either genuinely wired or visibly disabled with a plain-language reason).
  `GPSLabPrimaryInterface` is the single overlay-vs-subscription selection seam.

### Production setup (blocker)

There is no production endpoint, verification key, sign-in provider or payment backend
in this repository, and runtime behavior can only be verified by CI plus device
testing. Until a host app configures the keys above and a real signing backend exists,
the license stays locked — by design.

## Known limitations

- `arm64` / iOS 16.0+ only. Verified by the static checks and the CI Mach-O checks.
- Cycling follows the walking network (documented approximation above).
- SwiftUI `Map` / `liveUpdates` is out of reach of this hook set: those APIs read
  from the same `CLLocationManager` but bypass the delegate callbacks in some code
  paths. Non-SwiftUI CoreLocation consumers are covered.
- Runtime behavior (overlay rendering, MapKit tiles, hook delivery) can only be
  validated on a real device or a signed IPA; CI proves the binary contract only.

## Diagnostics

`os_log` under the subsystem `com.gpslab.runtime`, category `GPSLab`. Allowed events:
dylib load, hook installation count, overlay open/close, engine enable/disable, route
start/stop, license check started, license state changed (numeric code only), and
internal errors (stable numeric code only).

Internal errors are logged as a **stable numeric code only** (no
`NSError.localizedDescription`, no search query, no coordinate, no host data).
Coordinates, host data and real location are never logged. Codes: `2` route failure,
`10` no active scene for the overlay, `11` no key window for the activator,
`12` a required CoreLocation original IMP was not captured.
