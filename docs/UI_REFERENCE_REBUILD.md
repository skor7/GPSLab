# GPSLab — Reference UI rebuild notes

This document records the deliberate, unavoidable differences between the
approved visual reference and the native UIKit implementation, plus the
persistence/schedule/simulation limits of the rebuild.

Authoritative reference: `MAWQIE_UI_REFERENCE_FINAL.html` (Arabic-default RTL
rebrand to **موقع**), SHA-256
`bc7659e6a59dfe055213c33ac41425e6bf3ba372a135199c4762324fe6ee1616`. The earlier
`UI_REFERENCE_FINAL.html` (SHA-256
`85C73D4137FC4DCB11817E06841593443931D1EDA8B90B33852ACA99B6F10EC7`) is superseded
by it. Both HTML files are design previews only and are unchanged by this work.

## Reference → UIKit mapping

| Reference | Native implementation | Why |
|---|---|---|
| Fake status bar (clock `3:42`, Wi-Fi/battery glyphs) | The **real** iOS status bar / safe area | A hosted dylib must never draw a fake status bar. |
| Fixed dark palette (`#111116`, `#19191e`, violet `#8e5cff`, green `#30d158`, red `#ff375f`) | `GPSLabTheme` tokens; overlay forces `UIUserInterfaceStyleDark` | The reference is a fixed dark design; system controls are rendered on a dark surface. |
| `-apple-system` / SF Pro | `UIFont systemFontOfSize:weight:` at the reference sizes | No bundled or remote fonts; no WebView. |
| Custom `.segment` buttons | `UISegmentedControl` with `selectedSegmentTintColor = accent` | Native, accessible, matches the two-column segment look. |
| Custom `.toggle` div | `UISwitch` | Native control. |
| Custom `.map-bg` gradient | Lightweight `MKMapSnapshotter` image, dimmed, refreshed debounced | The card itself hosts a real interactive `MKMapView`; the background is a snapshot, not a second live map. |
| HTML `alert()` preview handlers | Real, typed GPSLab actions | The HTML JS was preview-only. |

The single panel uses the reference geometry: 28pt panel radius, 24pt card
radius, 278pt map card, 62pt search row, violet-accent borders, and 8pt insets on
narrow widths (<460pt, matching the reference `@media (max-width:460px)`),
otherwise 20pt.

The search bar keeps the existing standalone `UISearchBar` + GPSLab-owned child
results policy (never `UISearchController`), with the pure-C fixed-height and
bounded-results rules.

Two small adaptive technical differences from the HTML reference:

- **Header title**: the title/subtitle keep the reference nominal sizes
  (34pt Heavy / 15pt) and use native `adjustsFontSizeToFitWidth`
  (min scale 0.6 / 0.7, single line) so "GPSLab" is never truncated on narrow
  iPhones (360/375pt). The header row height and element order, the `EN` pill and
  the 44pt tap targets are unchanged.
- **Sheet keyboard avoidance**: every GPSLab form sheet binds its scroll
  viewport bottom to `view.keyboardLayoutGuide.topAnchor` (safe-area bottom when
  the keyboard is hidden), so Save/Apply remain reachable while typing. No host
  keyboard ownership or global notification is touched.

## Profiles persistence

- Location: `<Application Support>/GPSLab/Profiles/profiles.json` (GPSLab-owned
  folder, `NSURLIsExcludedFromBackupKey`).
- Writes: serialized on a private queue, `NSDataWritingAtomic`, with
  `NSFileProtectionCompleteUntilFirstUserAuthentication` on iOS.
- Schema: `schemaVersion` is exactly `1`; unknown keys are ignored; a
  present-but-invalid value rejects that profile.
- Corruption: a file that is not valid JSON, has the wrong schema version, or
  has a non-array `profiles` value is quarantined to
  `profiles.corrupt-<epoch>.json` and an empty store is returned. Malformed
  array entries are skipped individually. The host never crashes.
- Caps: 50 profiles, 64-byte names, 128-byte text fields, bounded arrays.
- The file stores **user-provided synthetic** profile data — including the
  synthetic anchor/route coordinates and altitude/course the user explicitly
  saved — plus optional synthetic Wi-Fi/Bluetooth test strings and schedules.
  It never stores **real** device coordinates, host data, device identifiers,
  MAC/BSSID values or network data, and it performs no network access.

## Schedule limits (foreground / best-effort only)

- The schedule is a **once** or **time-window** event with a native
  `UIDatePicker`. UTC epoch seconds are stored, plus a display-only timezone
  offset.
- **iOS cannot guarantee that a host app is launched or woken on the user's
  behalf.** The schedule therefore runs only while GPSLab is running and is
  re-evaluated deterministically when the app becomes active again: if the due
  instant was missed while the window is still open it applies **exactly once**;
  if the window is over it is **skipped**.
- The scheduler applies a profile only when the synthetic engine is **already
  enabled** and the license is unlocked. It **never re-enables GPSLab after a
  manual Disable**.
- At the end of a window it stops GPSLab's own scheduled profile
  (`stopRoute` + `setEnabledAndNotify:NO`) **only while that profile still owns
  the current selection**; a user-chosen manual profile is never stopped.
- A profile must be applied (one click) at least once for its schedule to arm.
- Schedules are **definitions only**: they are not auto-restored on relaunch.
  After a new launch the user applies the profile again to arm its schedule
  (best effort while GPSLab is running). A manual Disable cancels pending work
  and is latched until the next **explicit** apply; re-enabling or returning to
  the foreground never silently re-arms a schedule.

## Simulation / test modules

- The Wi-Fi and Bluetooth modules are **test settings only**. There is no Wi-Fi
  or Bluetooth hardware API, scan, association, advertisement, pairing or
  identity usage, and no host networking change.
- Only user-supplied synthetic strings are stored (profile name, SSID, device
  name, signal/RSSI, an arbitrary advertisement "pattern" that is documented
  metadata and is never emitted). No MAC/BSSID or device identity is stored or
  impersonated.
- An unavailable capability returns a typed `Unsupported` result and the UI
  states the limitation; nothing is faked and nothing crashes.

## Mawqie rebrand, service row, map links, altitude, profile switch

- **Visible brand**: every tool-owned *visible* title/subtitle/banner/text now
  renders **موقع** in both languages. Internal identifiers, class names, bundle
  ids, the license code/protocol/identity and the secure store are untouched.
- **Service row**: the reference's `service-control` row hosts the single master
  engine switch. It reuses the existing `setEnabledAndNotify:` path (including the
  scheduler's manual-disable intent). OFF is passthrough only: it never stops the
  host manager or app, never erases configuration/profiles/history/licensing and
  never introduces a second engine.
- **Map-link search**: the same search field accepts a place/address (unchanged
  `MKLocalSearch` flow), a direct `lat, lon` pair, a Google `@lat,lon` /
  `!3dlat!4dlon` link and an Apple `ll=` / `coordinate=` (or other
  coordinate-bearing) link. A light Google/Apple Maps banner reports recognition.
  Parsed coordinates move the map pin and coordinate readout as a **preview**; the
  synthetic engine is written only when the user taps Apply.
- **URL resolution is strict**: HTTPS only, the exact allowlist
  `maps.app.goo.gl`, `google.com`, `www.google.com`, `maps.google.com`,
  `maps.apple.com` (no wildcard domains, no plain `goo.gl`), no credentials, no
  explicit ports. The resolver uses an isolated ephemeral session (no cookies,
  cache, credential storage or custom headers), bounds redirects/time/bytes, and
  validates **every** redirect before following it. The response body is never
  read (the task is cancelled on headers); only the final URL is parsed — there is
  no scraping. Work is asynchronous, cancellable and stale-safe.
- **Altitude**: the reference altitude box opens a **reference-styled sheet card**
  (`GPSLabAltitudeViewController`, presented through the existing sheet/modal
  coordinator — not a `UIAlertController`): a signed, finite meter field with a
  unit label and zero/apply/cancel. Editing previews the value only; it never
  writes the engine and never adds new clamping (the existing engine/profile range
  policy owns it). Apply passes the value through the existing configuration →
  `CLLocation` path. The numeric field is explicitly LTR.
- **Profile switch (backward compatible)**: a profile may carry an optional
  `enabled` boolean that records the master-switch state **at save time**. Absent
  (legacy profiles) keeps the original semantics exactly — applying never changes
  the switch and never silently disables. When present, applying the profile
  restores the switch through the same existing `setEnabledAndNotify:` path; the
  coordinator and the scheduler still never toggle the engine. `schemaVersion`
  stays `1`; every existing field and profile is preserved. Wi-Fi/BLE are
  unchanged. Validation and license gates run **before** any state change; a
  failed apply/stage rolls the switch back **only while that intent still owns the
  switch** (`GPSLabMasterIntentGuard`): a superseded or cancelled apply, or a
  manual switch change during an async apply, is ignored entirely and never rolls
  back or mutates newer state. An explicitly disabled profile is
  switched OFF, then its saved coordinate (a route profile uses its start
  coordinate), altitude, heading and drift are staged while OFF, and its route
  endpoints/schedule are restored in the UI for an explicit later start. A route
  **never auto-starts on enable** — the engine has no such behaviour, so the user
  must start it explicitly after turning the service back on.
- **Tests**: portable `tests/gpslab_map_link_test.c` (formats/security/policy/
  redirect cap) and `tests/gpslab_altitude_test.c`; Foundation
  `tests/GPSLabMapLinkResolverTests.m` drives the resolver through an **injected
  offline mock transport** (synchronous classification, the async short-link
  path, hostile/late-superseded callbacks, cancellation and the transport's
  session/redirect/challenge policy — no network I/O); `tests/GPSLabEngineTests.m`
  covers the master ON/OFF/passthrough/OFF→ON settings-preservation contract;
  `tests/GPSLabProfileApplicationTests.m` covers the optional `stageProfile:`
  adapter (staging while OFF never enables and never starts a route); and
  `tests/GPSLabProfileTests.m` covers `enabled` round-trip/backward compatibility.
  The iOS/macOS compilation of these Objective-C tests is verified in CI only.

## Frozen / unchanged

The CoreLocation hook layer, stream intent, engine, drift model, geodesy,
configuration, store, Keychain/secure store, token verifier, license manager,
license config/policy/build config, entitlement, types, location factory,
diagnostics, status log and localization wrapper behaviour are unchanged. The
localization catalog kept all existing keys (values rebranded where the visible
brand appeared) and gained new UI keys. The profile model gained one optional,
backward-compatible `enabled` field; the schema version and all prior fields are
unchanged.
