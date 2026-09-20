# GPSLab — Reference UI rebuild notes

This document records the deliberate, unavoidable differences between the
approved visual reference (`UI_REFERENCE_FINAL.html`) and the native UIKit
implementation, plus the persistence/schedule/simulation limits of the rebuild.

Authoritative reference: `UI_REFERENCE_FINAL.html`
SHA-256 `85C73D4137FC4DCB11817E06841593443931D1EDA8B90B33852ACA99B6F10EC7`
(unchanged by this work).

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

## Frozen / unchanged

The CoreLocation hook layer, stream intent, engine, drift model, geodesy,
configuration, store, Keychain/secure store, token verifier, license manager,
license config/policy/build config, entitlement, types, location factory,
diagnostics, status log and localization core/wrapper behaviour are unchanged.
Only the localization catalog was appended with new UI keys.
