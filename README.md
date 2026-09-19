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
  ├─ GPSLabGestureActivator    3-finger ~0.9 s hold on the key window
  ├─ GPSLabOverlayPresenter    floating UIWindow on the active UIWindowScene
  └─ GPSLabOverlayViewController  MapKit map + all controls
GPSLabStatusLog            bounded, non-sensitive status text for the overlay
Diagnostics                os_log only; allowed events; never logs coordinates
```

## Behavior

- **Master switch.** When enabled is OFF, every intercepted selector forwards to its
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
  with existing gestures.
- **Contents:** enable switch, validated latitude/longitude/altitude/course fields,
  keep-last toggle, drift toggle + radius, route mode / custom speed / stop behavior,
  route start/end/play/pause/stop with progress, bookmarks (add/rename via name
  prompt/select/delete) and recents (select/delete/clear), plus a "Show real user
  location" switch that is display-only and uses a bypassed manager (never persisted,
  never logged). Search results are generation-guarded so a stale response never
  replaces a newer one.
- **Dismissal:** the in-panel **Close** button removes the overlay window entirely;
  the host app becomes fully interactive again with no restart.
- **Scenes:** the window is created on the active `UIWindowScene` and re-created if
  the scene changes. Layout follows the safe area, supports both orientations, and
  adapts to dark/light mode through system materials and dynamic colors.

## Persistence allow-list

Only these values are ever written, to the `com.gpslab.runtime` `NSUserDefaults`
suite, under `GPSLab.*` keys:

- `enabled`
- `driftEnabled`, `driftRadiusMeters`
- `keepLastCoordinate`
- route `routeMode`, `routeCustomSpeedKmh`, `stopBehavior`
- bookmarks (name + coordinate + altitude)
- recents (coordinate + altitude, capped at 20, de-duplicated within 5 m)
- anchor `latitude`, `longitude`, `altitude`, `heading` — **only while
  `keepLastCoordinate` is on**

Corrupted entries are validated field-by-field and fall back to safe defaults; a bad
payload never crashes the host. Host application data and real device location are
never stored or logged.

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
dylib load, hook installation count, overlay open/close, engine enable/disable,
route start/stop, manager register/unregister and synthetic-location generation.

Internal errors are logged as a **stable numeric code only** (no
`NSError.localizedDescription`, no search query, no coordinate, no host data).
Coordinates, host data and real location are never logged. Codes: `2` route failure,
`10` no active scene for the overlay, `11` no key window for the activator,
`12` a required CoreLocation original IMP was not captured.
