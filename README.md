# GPSLab

`GPSLab` is a clean-room Objective-C dylib that provides a deterministic, synthetic
CoreLocation stream for **authorized testing on devices you own** (for example,
QA builds that need a fixed coordinate without touching real location hardware).

It is built with [Theos](https://theos.dev) as a standalone library and is intended
to be injected into an application binary at `Frameworks/GPSLab.dylib`.

## Clean-room statement

- Written from scratch against Apple's public headers and the Objective-C runtime
  documentation (`<objc/runtime.h>`).
- No source code was copied from, or derived from, any existing tweak or location
  spoofing project.
- It does not link or load any hooking framework (no Substrate, ElleKit, or
  libhooker). Method interception is done exclusively with the public
  Objective-C runtime (`class_getInstanceMethod`, `class_replaceMethod`, ...).
- There is no UI: the dylib never presents alerts, views, or prompts.

## Build

Requirements:

- Theos with an iOS SDK >= 16.0
- `arm64` toolchain (Theos Linux toolchain works)

```sh
make clean
make
```

The product is written to `.theos/obj/GPSLab.dylib` with the install name
`@executable_path/Frameworks/GPSLab.dylib`.

The `GPSLab` folder must be the repository root for the GitHub Actions workflow
(`.github/workflows/build.yml`) to run, because GitHub only executes workflows that
live at the repository root.

To use it, place the dylib at `<App.app>/Frameworks/GPSLab.dylib` and add an
`LC_LOAD_DYLIB` entry (for example with `insert_dylib`) in a build you own.

## Behavior

- Base coordinate is configurable in code via
  `+[GPSLabEngine setBaseLatitude:longitude:altitude:]` (defaults to `0, 0, 0`).
- Every generated location walks a bounded random path of at most ~8 meters
  (geodesic) around the base coordinate, with a live timestamp.
- Reported `speed` is `0` and `course` is invalid (`-1`), i.e. a stationary
  receiver.
- Accuracy values vary inside a realistic band (`horizontalAccuracy` 5-20 m,
  `verticalAccuracy` 8-25 m).
- Standard updates arrive immediately and then once per second; significant-change
  updates arrive immediately and then once every 30 seconds.

## Limits

- `arm64` / iOS 16.0+ only.
- No configuration UI, persistence, or logging of real device data.
- Intended exclusively for testing in environments you are authorized to modify.
  Do not use it to deceive users or violate any service's terms.
