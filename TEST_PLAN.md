# GPSLab v1.0 — Test Plan

This plan separates what can be proven automatically from what requires a device.
**No runtime success is claimed by the repository tooling.** The automated layers
prove the source/build contract; only the device layer proves behavior.

Layers:

1. **Static (no toolchain, runs anywhere):** `bash scripts/validate.sh`
2. **CI build contract:** the `static` and `build` jobs in
   `.github/workflows/build.yml`
3. **Device manual:** the matrix below on a real device or signed IPA

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

## Pass/fail recording

Record, per row: device model, iOS version, IPA variant ([Clean]/[Re-tested]),
result, and the `os_log` excerpt (redacted of coordinates where relevant). Do not
mark a row as passed based on CI alone.
