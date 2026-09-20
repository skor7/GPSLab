# GPSLab v1.0 — Test Plan

This plan separates what can be proven automatically from what requires a device.
**No runtime success is claimed by the repository tooling.** The automated layers
prove the source/build contract; only the device layer proves behavior.

Layers:

1. **Static (no toolchain, runs anywhere):** `bash scripts/validate.sh`
2. **Portable policy + macOS crypto tests:** the `policy-tests` and `crypto-tests`
   jobs in `.github/workflows/tests.yml`
3. **CI build contract:** the `static` and `build` jobs in
   `.github/workflows/build.yml`
4. **Device manual:** the matrix below on a real device or signed IPA

---

## 1. Static checks (automated, no SDK)

```sh
bash scripts/validate.sh
```

Expected: exits 0 and prints "All GPSLab static checks passed."

Covers: Makefile arch/target/ARC/frameworks/install path, every `.m` compiled,
no hooking-framework references, no private frameworks, no `dlopen`/`dlsym`, no
Swift, no manual `retain/release`, diagnostics never receive coordinates.

## 2. CI build contract (automated)

The workflow must:

- [ ] Run the `static` job successfully.
- [ ] Build `GPSLab.dylib` with Theos on `ubuntu-22.04`.
- [ ] Prove `arch: arm64`.
- [ ] Prove `install_name: @executable_path/Frameworks/GPSLab.dylib`.
- [ ] Prove `min_os: 16.x` from `LC_BUILD_VERSION`/`LC_VERSION_MIN_IPHONEOS`.
- [ ] Prove dependencies contain no banned hooking framework.
- [ ] Prove the binary contains no banned string.
- [ ] Upload the `GPSLab-dylib` artifact.

## 3. Device manual matrix

Legend: **[Clean]** = injected into a freshly installed IPA never previously tested;
**[Re-tested]** = an IPA that previously had GPSLab injected.

### 3.1 Injection and load

| # | Steps | Expected |
|---|-------|----------|
| 3.1.1 | [Clean] Install injected IPA, launch app. | App launches normally; `os_log` shows "GPSLab dylib loaded" and a hook count. |
| 3.1.2 | [Re-tested] Reinstall over a previously injected IPA. | Same as above with exactly one hook-install event; no duplicate swizzling. |
| 3.1.3 | Launch with the overlay never opened. | Host app is unaffected; no overlay visible; host gestures work. |

### 3.2 Overlay activation and dismissal

| # | Steps | Expected |
|---|-------|----------|
| 3.2.1 | Exactly three fingers held ~0.9 s in the app. | Overlay appears above the host UI. |
| 3.2.2 | Single-finger and two-finger holds. | Nothing happens. |
| 3.2.3 | Three fingers held but moved > 10 pt. | No activation. |
| 3.2.4 | Three-finger **tap** (no hold). | No activation. |
| 3.2.5 | Three fingers, lift one before ~0.9 s. | No activation. |
| 3.2.6 | Reopen immediately after closing (within ~1 s). | Blocked by cooldown; opens only after ~1 s. |
| 3.2.7 | Keep fingers down after the overlay opens. | No repeat activation. |
| 3.2.8 | Trigger a host gesture (scroll/pinch) during the hold. | Host gesture still works (no cancellation). |
| 3.2.9 | Tap **Close**. | Overlay disappears; host fully interactive; no restart. |
| 3.2.10 | Re-open the overlay after closing. | Reopens with the persisted state intact. |

### 3.3 Anchor, manual entry, recents, bookmarks

| # | Steps | Expected |
|---|-------|----------|
| 3.3.1 | Enter valid lat/lon/alt/course, tap Apply. | Anchor updates; field values persist; app sees synthetic coordinate. |
| 3.3.2 | Enter lat 91 / lon 500. | Validation alert; nothing changes. |
| 3.3.3 | Tap map, drag the pin, long-press the map. | Anchor follows; recents get an entry. |
| 3.3.4 | Search a place, select a result. | Anchor moves to it; search dismisses. |
| 3.3.5 | Toggle **Keep last coordinate**, relaunch, reopen overlay. | Anchor matches the last synthetic coordinate. |
| 3.3.6 | Add, rename (via name prompt), select, swipe-delete a bookmark. | Each action reflected and persisted across relaunch. |
| 3.3.7 | Delete one recent; clear all recents. | Entries removed; list empty after clear. |

### 3.4 Drift

| # | Steps | Expected |
|---|-------|----------|
| 3.4.1 | Drift off. | Every fix equals the anchor exactly. |
| 3.4.2 | Drift on, radius 8 m, watch for several minutes. | Points move smoothly and never exceed 8 m from the anchor. |
| 3.4.3 | Drift on, change radius while running. | Walk resets and respects the new radius. |

### 3.5 Route simulation

| # | Steps | Expected |
|---|-------|----------|
| 3.5.1 | Set start and end on the map, mode Driving, Start route. | Status shows "Loading route" then "Playing"; progress increases; speed/course reported. |
| 3.5.2 | Pause then Resume. | Progress freezes then continues from the same point. |
| 3.5.3 | Stop with **Stay**. | Anchor stays at the last route point. |
| 3.5.4 | Stop with **Return**. | Anchor returns to the route start. |
| 3.5.5 | Start a second route while one is running. | The first is cancelled; no duplicate timers; UI reflects the second. |
| 3.5.6 | Walking / Cycling modes. | Walking uses the pedestrian network; Cycling uses the same network at 15 km/h (documented approximation). |
| 3.5.7 | Custom mode with a custom speed. | Straight line start→end at the configured speed. |
| 3.5.8 | Set the same coordinate as start and end. | No crash; route completes or is handled gracefully. |
| 3.5.9 | Clear the route end mid-simulation / cancel from the map. | Cancellation is clean; no further updates. |

### 3.6 Enable / disable and host impact

| # | Steps | Expected |
|---|-------|----------|
| 3.6.1 | Disable the engine. | No synthetic updates; host receives original CoreLocation behavior. |
| 3.6.2 | Disable while a route is running. | Route stops; anchor persisted. |
| 3.6.3 | Re-enable. | Synthetic updates resume; `os_log` shows the transition. |
| 3.6.4 | Host starts updates, then the engine is disabled from the overlay. | Synthetic timers stop; the intent is kept; the manager is handed back to real CoreLocation (no synthetic fixes). |
| 3.6.5 | Disable, then re-enable, without the host touching anything. | Synthetic delivery resumes for the same manager automatically. |
| 3.6.6 | Host starts updates **while** the engine is disabled. | The call reaches the original implementation; the request is recorded and resumes synthetically once enabled. |
| 3.6.7 | Host calls stop **while** the engine is disabled. | Forwards to the original and clears the recorded intent (no synthetic resume on re-enable). |
| 3.6.8 | Launch with persisted `enabled = NO`. | No synthetic delivery at launch; host gets real CoreLocation; enabling later activates synthetic exactly once. |
| 3.6.9 | Start-before-toggle: host calls `startUpdatingLocation` while enabled, then the overlay is disabled immediately. | The synthetic timer is suspended, the intent is kept, exactly one original stream starts; no real + synthetic duplication. |
| 3.6.10 | Host requests only significant updates, then the engine is disabled. | Only the significant original stream is handed back (standard is not started); re-enabling stops it and resumes synthetic. |
| 3.6.11 | Host requests standard updates while disabled, then enables; then disables again with nothing else running. | Each transition records/flips intent exactly once and never leaves a synthetic timer alongside an original stream. |

### 3.7 Hooks and coverage

| # | Steps | Expected |
|---|-------|----------|
| 3.7.1 | Host calls `startUpdatingLocation`. | Exactly one immediate fix, then one per second. |
| 3.7.2 | Host calls `startMonitoringSignificantLocationChanges`. | One immediate fix, then one every 30 s. |
| 3.7.3 | Host calls `requestLocation`. | Exactly one fix (no retained intent). |
| 3.7.4 | Host reads `CLLocationManager.location`. | Returns the synthetic current location. |
| 3.7.5 | Host reads `authorizationStatus` (class and instance). | Returns `authorizedAlways` while enabled; original value while disabled. |
| 3.7.6 | Host reads `accuracyAuthorization`. | Returns `fullAccuracy` while enabled; original while disabled. |
| 3.7.7 | Host reads `locationServicesEnabled`. | Returns YES while enabled; original while disabled. |
| 3.7.8 | Host calls `requestWhenInUseAuthorization` / `requestAlwaysAuthorization`. | Delegate receives an authorization-granted callback without a system prompt (original path while disabled). |
| 3.7.9 | Host calls `setDelegate:` and then sets a nil delegate. | Delegate assignment always reaches the original (never a silent no-op); nil is safe. |
| 3.7.10 | Host sets a nil delegate, then stops updates. | No crash. |
| 3.7.11 | Non-SwiftUI CoreLocation consumer. | Synthetic fixes delivered; SwiftUI `liveUpdates` documented as out of scope. |

### 3.8 Multiple managers and lifecycle

| # | Steps | Expected |
|---|-------|----------|
| 3.8.1 | Two managers started, stop one. | The other keeps receiving updates. |
| 3.8.2 | Release one manager. | Its timers are cancelled; no leak; no crash. |
| 3.8.3 | Background the app, wait, foreground it (engine enabled). | Synthetic delivery suspended in background, intent kept, resumes on foreground; no crash. |
| 3.8.4 | Background with the engine enabled, disable it while backgrounded, foreground. | Intent preserved; no synthetic delivery until explicitly enabled again. |
| 3.8.5 | Rotate the device. | Overlay reflows within the safe area. |
| 3.8.6 | Switch light/dark mode. | Overlay follows the system appearance. |
| 3.8.7 | Multi-scene: open/close/switch scenes while the overlay is showing. | Window is re-created on the active scene; no crash on a disappearing window. |
| 3.8.8 | "Show real user location" on, then off. | A separate green annotation appears (not `showsUserLocation`); no synthetic fix to the display manager; annotation removed on stop; coordinate not persisted/logged. |
| 3.8.9 | Real-location switch off. | No real coordinate is ever displayed. |
| 3.8.10 | Two managers started; background then foreground the app (engine enabled). | Both managers suspend in background with intent kept and resume synthetic on foreground; no duplicate deliveries and no original streams running alongside. |
| 3.8.11 | Engine enabled and a host manager streaming; enable "Show real user location". | The bypassed display manager keeps receiving real fixes only and never a synthetic fix; the synthetic host manager is unaffected. |

### 3.9 Persistence: keep-last and corruption

| # | Steps | Expected |
|---|-------|----------|
| 3.9.1 | Keep-last ON, change the anchor, relaunch. | Anchor restored to the last coordinate/altitude/heading. |
| 3.9.2 | Keep-last OFF, change the anchor, relaunch. | Anchor returns to safe defaults; the coordinate keys were erased. |
| 3.9.3 | Toggle keep-last ON -> OFF while running. | Persisted coordinate keys are cleared immediately; other allow-list values remain. |
| 3.9.4 | Corrupt the stored configuration payload. | Loads safe defaults; host does not crash. |
| 3.9.5 | Corrupt bookmarks/recents. | Invalid entries skipped; valid ones retained. |
| 3.9.6 | Uninstall/reinstall. | Suite data cleared or recreated cleanly; defaults apply. |

### 3.10 Search and diagnostics hygiene

| # | Steps | Expected |
|---|-------|----------|
| 3.10.1 | Type a query, then quickly type a different query. | Only the newest query's results are shown; stale responses are ignored. |
| 3.10.2 | Type a query shorter than 3 characters. | Previous search cancelled; results cleared. |
| 3.10.3 | Close the overlay mid-search. | In-flight search is cancelled; no crash. |
| 3.10.4 | Stream `os_log` for the subsystem while using every feature. | Only allowed events; internal errors are code-only (no coordinate, query, host data or `localizedDescription`). |
| 3.10.5 | Inspect the injected binary. | No banned hooking strings; install name correct. |

---

## 4. Subscription / entitlement matrix (v2)

These rows require a host app configured with `GPSLabLicenseEndpoint`,
`GPSLabLicensePublicKey`, and (optionally) the sign-in/manage URLs, plus a real signing
backend. **CI proves the crypto and state contract only; no row below may be marked
passed from CI alone.** All rows are device-manual.

### 4.1 States and gating

| # | Steps | Expected |
|---|-------|----------|
| 4.1.1 | Launch with no endpoint/key configured. | Locked; subscription screen states the service is unavailable in this build; no synthetic fixes; host gets real CoreLocation. |
| 4.1.2 | Launch with a valid verified cache. | Active immediately (cache-first), engine unlocked; a silent refresh runs. |
| 4.1.3 | Launch with no cache, endpoint configured. | Checking, then Active on a valid signed response; engine unlocks at that point. |
| 4.1.4 | Persisted `enabled = YES`, then launch locked. | Engine stays off; enabling has no effect until unlocked; no synthetic fixes. |
| 4.1.5 | Host starts updates while locked. | Original CoreLocation is used; no synthetic timer. |
| 4.1.6 | Unlock while host is running. | Synthetic delivery resumes for the requested managers; originals stop (no duplication). |
| 4.1.7 | Activation code submitted from the subscription screen. | Server is called; success shows Active and swaps to the map canvas; failure shows the server reason, never a fake success. |
| 4.1.8 | Sign In / Manage Account with URLs configured. | The external page opens. |
| 4.1.9 | Sign In / Manage Account without URLs configured. | Buttons are visibly disabled with a plain-language reason; nothing opens. |

### 4.2 Signed token / tamper rejection

| # | Steps | Expected |
|---|-------|----------|
| 4.2.1 | Serve a valid envelope signed by the configured key. | Verifies; claims applied. |
| 4.2.2 | Tamper the payload (proxy). | Rejected; a valid cache is not revoked by an invalid response. |
| 4.2.3 | Tamper the signature. | Rejected. |
| 4.2.4 | Token bound to a different installation UUID. | Rejected (binding mismatch); locked. |
| 4.2.5 | Wrong issuer/audience. | Rejected when the corresponding config is set. |
| 4.2.6 | Oversized payload / malformed JSON / unsupported `alg`. | Rejected; fail-closed. |
| 4.2.7 | Signed `status = revoked`. | Enters Invalid; cached token is purged; engine tears down to passthrough. |
| 4.2.8 | Signed `status = expired`. | Enters Expired; engine locked. |
| 4.2.9 | Inspect the Keychain and `NSUserDefaults`. | License material only in the Keychain; no token/UUID in defaults. |
| 4.2.10 | Serve an envelope above the size cap, or a fractional/boolean `version` or timestamp. | Rejected before/without trusting content; fail-closed. |
| 4.2.11 | Configure a malformed or arbitrary-tail public key. | Rejected as an invalid key; nothing verifies. |
| 4.2.12 | Server returns a token whose `issuedAt` is far in the future. | Rejected beyond the allowed skew; a valid cache is not revoked. |
| 4.2.13 | Proxy inserts an HTTP/HTTPS redirect to another host. | Redirect is not followed; the code/token is never forwarded. |
| 4.2.14 | Response body exceeds the cap while streaming. | The task is cancelled as soon as the cap is exceeded; treated as a failed check. |
| 4.2.15 | Serve a signed `grace`/`expired`/`revoked` token whose `expiresAt` is in the past (the server signs its truthful current `issuedAt`). | Verifies; `grace` unlocks only inside a real `graceUntil`, `expired`/`revoked` lock. |
| 4.2.16 | Serve an `active` token with `issuedAt > expiresAt`, or a `grace` token with `graceUntil <= expiresAt`. | Rejected as unsafe time; fail-closed. |

### 4.3 Offline, clock and grace

| # | Steps | Expected |
|---|-------|----------|
| 4.3.1 | Verified Active, then airplane mode, relaunch. | Active preserved from cache; no network needed. |
| 4.3.2 | Verified Grace within the configured cap, offline. | Grace preserved (unlocked); status shows grace. |
| 4.3.3 | Grace window larger than the configured cap. | Treated as Expired (locked). |
| 4.3.4 | No valid cache and offline. | Offline (locked); subscription screen explains connectivity. |
| 4.3.5 | Move the device clock backwards while Active. | The entitlement does not extend; a time cross-check keeps the deadline. |
| 4.3.6 | Reach the expiry deadline while running. | Route/drift/streams tear down; managers fall back to real CoreLocation; host is not closed; data untouched. |
| 4.3.7 | Foreground reconciliation after the deadline. | State re-resolved from the effective clock; a refresh runs when configured. |
| 4.3.8 | Re-check while a valid cache exists. | A still-valid cache is not revoked merely because revalidation is in flight. |
| 4.3.9 | Move the clock back, relaunch, with a token that expired in between. | Remains expired; the persisted metadata clock prevents extension. |
| 4.3.10 | Receive a signed `revoked`, then go offline and relaunch. | Still Invalid (authenticated revocation preserved), never Offline. |
| 4.3.11 | Corrupt the Keychain metadata (garbage/Null/wrong types). | Ignored safely; no crash; the license resolves conservatively. |
| 4.3.12 | Build with no build macros and no host Info.plist keys. | Locked; the subscription screen states the service is unavailable. |

### 4.4 UI / lifecycle / scenes

| # | Steps | Expected |
|---|-------|----------|
| 4.4.1 | Open the overlay while locked. | The subscription screen appears instead of the map canvas. |
| 4.4.2 | Entitlement expires while the map canvas is open. | The window root swaps in place to the subscription screen; no new window, no focus/scene glitch. |
| 4.4.3 | Activate while the subscription screen is open. | Root swaps in place to the map canvas with the persisted state intact. |
| 4.4.4 | Rotate / light-dark / Dynamic Type on both screens. | Layout reflows within the safe area; no clipping. |
| 4.4.5 | Multi-scene: move the overlay between scenes while locked and unlocked. | The window is re-created on the active scene; root selection stays correct; no crash. |
| 4.4.6 | Stream `os_log` through every subscription transition. | Only allow-listed events; license states are numeric; no ids, tokens or messages. |

### 5. UI/locale device matrix (v3) — PENDING, device-only

These rows cover the keyboard/presentation and localization work. CI proves the
catalog, numeric normalization and persistence contract only; **every row below
is device-manual and must be recorded as pending until run on hardware.**

Clarified search-only root cause: Settings/Favorites present normally **before**
search. Tapping Search starts a `UISearchController` session whose results
presentation owns the layer above the canvas (the overlay window has no host
navigation bar to host the search bar), so the search bar/keyboard and the map
controls interact. The targeted fix keeps an explicit always-visible Cancel on
the search bar, activates the controller only after editing begins, and cancels
through the controller delegate. The lower rows (sheets, localization,
lifecycle) are unchanged.

| # | Steps | Expected |
|---|-------|----------|
| 5.1 | Fresh overlay; tap Settings, dismiss; tap Favorites, dismiss. | Both present and dismiss normally (baseline before search). |
| 5.2 | Tap the search bar. | Keyboard appears; the GPSLab window owns input; typing filters results. |
| 5.3 | While search is active, confirm the explicit Cancel is visible; tap it. | Search deactivates; the results layer is removed; map/header/floating controls return and are tappable. |
| 5.4 | Repeat search; tap outside the results (map/header area). | Search deactivates (or the keyboard hides) without consuming map pan/zoom/drag. |
| 5.5 | Repeat search; tap a result. | Anchor updates; search deactivates; map/controls return. |
| 5.6 | After each search exit, tap Settings then Favorites again. | Both still present exactly once (regression check for the search session). |
| 5.7 | With search active, tap a control if reachable. | Search ends first, then the requested sheet appears exactly once. |
| 5.8 | Double-tap settings/favorites quickly. | Only one sheet is presented; no orphaned or stacked duplicate modal. |
| 5.9 | Open Settings, Favorites, Recents, Manual, Fluctuation, Route in turn. | Each presents on the GPSLab window; nested confirm/rename alerts appear above their sheet. |
| 5.10 | Dismiss every sheet and alert, then tap Close. | Overlay closes; the host app is fully interactive and its keyboard/gestures are restored. |
| 5.11 | Open Settings → Manual while Settings is open. | Settings dismisses first, then Manual opens (no two sheets at once). |
| 5.12 | Rotate the device with a sheet open. | Sheet and canvas reflow within the safe area; no clipping. |
| 5.13 | Light/dark and Dynamic Type with a sheet open. | System materials/colors and text scaling apply; no clipping. |
| 5.14 | First launch, no stored language, host device in any locale. | GPSLab UI is Arabic by default; host app language is unchanged. |
| 5.15 | Switch language to English then back to Arabic in Settings. | All active GPSLab screens update immediately; no root rebuild; map position and unsaved form values are preserved. |
| 5.16 | Relaunch after choosing a language. | The chosen language persists; the host app locale/appearance is never modified. |
| 5.17 | Arabic UI. | RTL applies to nav bars, rows, alerts and sheets; coordinates, course, altitude and map geography stay LTR/Latin and the map is not mirrored. |
| 5.18 | Manual entry with Arabic-Indic digits and the Arabic decimal separator. | Coordinates/altitude/course parse correctly; rounded corners and clamping unchanged. |
| 5.19 | Manual entry with trailing garbage (e.g. "12abc") or "nan". | Rejected with the localized invalid-number alert; nothing changes. |
| 5.20 | Favorites/recents coordinate rows and route status in Arabic. | Digits use Latin/POSIX format, values remain readable LTR. |
| 5.21 | Locked session (no configured service). | Subscription screen strings are localized; activation/restore/sign-in behavior is byte-for-byte unchanged. |
| 5.22 | Multi-scene: move the overlay between scenes while a sheet is open. | Window re-created on the active scene; no crash; key lease released/restored conservatively. |
| 5.23 | Background the app with the overlay open, then foreground. | Host is not left behind a non-interactive window; tapping a GPSLab text field re-acquires the keyboard. |
| 5.24 | `os_log` review through every UI/locale action. | Only allow-listed events; no coordinates, names, queries or tokens logged. |
| 5.25 | In search, press the keyboard Search key. | The query runs, the keyboard hides, and Cancel stays visible; overlapping results never trap the user. |
| 5.26 | Tap Cancel while results are still dismissing, then immediately tap Settings. | The sheet is deferred until search actually dismisses, then presents once from the canvas (never from the search controller). |
| 5.27 | Rapidly tap Settings then Favorites while the first sheet animates in. | Exactly one sheet presents; the duplicate is dropped after the first settles (no faked completion, no orphan). |
| 5.28 | Interactively pull a sheet down halfway, cancel it, then immediately open another. | The next sheet presents only after the interactive transition settles; no stuck busy state. |
| 5.29 | Interactively pull a sheet down to dismiss, then immediately tap Settings. | One dismissal completes, then Settings presents from the canvas. |
| 5.30 | Open Manual entry, focus a coordinate field, background the app, foreground it, focus the field again. | Field values are preserved; the keyboard appears again (key lease re-acquired on scene activation, host scope untouched). |
| 5.31 | With a sheet open, swap the GPSLab root in place (entitlement transition). | Queued modal work from the old root is invalidated by the session generation; no stale sheet presents on the new root. |

## Pass/fail recording

Record, per row: device model, iOS version, IPA variant ([Clean]/[Re-tested]),
result, and the `os_log` excerpt (redacted of coordinates where relevant). Do not
mark a row as passed based on CI alone.
