# GPSLab — Deliverable A: Release Protection Report

Scope: harden the GPSLab injected dylib release (build flags, strip/debug/string
hygiene, deterministic validation), audit the existing GPSLab + KeychainFix
binaries, and add a reproducible macOS release script for the protected
KeychainFix artifact. KeychainFix **functionality, licensing and location
semantics were not touched**, and the sibling `KeychainFix-Builder` repository was
**not read or modified** by the release script (it consumes an already-built,
already-verified binary only).

Environment: Windows 10 host, PowerShell 5.1 + WSL2 (Ubuntu 22.04). No iOS SDK, no
Theos, no `clang`/`otool`/`lipo`/`ldid` and no macOS/iOS runtime are available on
this host, so a hardened **build** and a real **load** could not be produced here.
Those are marked **NOT MEASURED / UNVERIFIED** below; CI performs the build and
runs the same audit gate.

---

## 1. Changes applied

| File | Purpose |
| --- | --- |
| `Makefile` | Explicit **DEV/PRODUCTION** build-mode selector. Defaults to **DEV** (`DEBUG=1`, Theos debug schema, no hardening) so a plain `make` is readable/debuggable; `make MODE=production` applies the release flags. Consumes `GPSLAB_MODE_CFLAGS`/`GPSLAB_MODE_LDFLAGS` from `scripts/build_mode.mk`. |
| `scripts/build_mode.mk` | **New.** Self-contained mode → flag mapping (no Theos include): DEV = `DEBUG=1`, no hardening; PRODUCTION = `DEBUG=0`, `-fvisibility=hidden -fno-ident -g0 -DNDEBUG`, `GPSLab_LDFLAGS = -Wl,-x -Wl,-S`. An unknown `MODE` is rejected at parse time. |
| `scripts/audit_build_modes.sh` | **New.** Deterministic, offline audit that evaluates BOTH modes with plain GNU make and asserts: dev is readable/debuggable (`DEBUG=1`, no visibility/`-g0`/NDEBUG/strip), production is hardened (`DEBUG=0` + all release flags), a plain `make` defaults to dev, an unknown mode fails, and the Makefile consumes the mapping. |
| `scripts/audit_macho.py` | Deterministic, read-only Mach-O audit (arch, install_name, min OS, deps, sections, symbol/STAB counts, code-signature flag, string count, leak scan). `--symbols` optionally lists defined symbol names. Never prints matched string values. |
| `scripts/release_protection.sh` | Deterministic gate: build-mode audit for both modes + source hygiene (static) and binary hardening invariants (when a dylib path is given). **Fails when an explicitly supplied binary path does not exist** (previously it silently downgraded to static-only and exited 0). Offending source files are listed by name only, never by line content. |
| `scripts/keychainfix_release.sh` | **New.** macOS/Xcode release script for the protected KeychainFix artifact: consumes an existing verified `KeychainFix.dylib`, gates on its identity, strips a **copy** (original untouched) with `xcrun strip -x -S`, audits before/after (hash/size/arch/install_name/min OS/deps/symbol counts/leaks), and prints signing + runtime/device verification steps. **Fail closed:** any strip/audit failure deletes the newly created output and exits non-zero; the output must end with **zero local symbols**; a code-signature-invalidated result is refused; `--out` is compared to the input after canonicalization (symlinks/`..`/`.` folded) so it can never alias the input. `--self-check` runs anywhere. |
| `.github/workflows/build.yml` | The `static` job (ubuntu) runs the both-mode audit, the release-protection static checks and the KeychainFix script self-check. The `build` job runs on a **macOS runner** with the Theos environment set up for macOS (**no Ubuntu apt steps**), builds and audits a **DEV** baseline, then `make MODE=production`, and enforces the arm64 / iOS 16+ / install-name / dependency / debug-symbol / leak / secret-scan / sensitive-string contract. It uploads `GPSLab-production-dylib` (the production output only) and `GPSLab-production-report` (machine-readable JSON + Markdown generated from the actual artifacts by `scripts/ci_production_report.py`, plus the CI-updated `RELEASE_PROTECTION_REPORT.ci.md`). The Theos action is **pinned to its v1 commit** and its real macOS behaviour was verified from its source: it supports macOS (`brew install ldid make`), clones `theos/theos`, and clones `theos/sdks@master`, which ships `iPhoneOS16.5.sdk` (iOS 16+). Two action defects are compensated in the workflow: its macOS `PATH=... >> $GITHUB_ENV` line is a no-op, so GNU make is added explicitly via `$GITHUB_PATH`; and its Xcode-SDK fallback names the symlink from the SDK path basename, so the workflow names it from `xcrun --show-sdk-version` instead. |
| `scripts/ci_production_report.py` | **New.** Consumes the `audit_macho.py --json` DEV and PRODUCTION audits, enforces the production contract, runs a narrow high-confidence secret scan over the production binary, runs the protected-string **binary** audit for an explicit sensitive-string verdict, and writes the JSON + Markdown report. The Markdown explicitly shows the DEV/PRODUCTION **exported** symbol counts, full SHA-256 and size of both artifacts, the source commit, the secret-scan verdict and the sensitive-string binary-audit verdict. Every value is read from the supplied audits / the actual binary; nothing is hardcoded. |
| `.github/workflows/keychainfix-release.yml` | **New, separate and optional.** Consumes an already-verified `KeychainFix.dylib` supplied as a **same-repository artifact** and runs `scripts/keychainfix_release.sh` on macOS. It **refuses to download-and-publish unless this repository is private** (artifacts of a public repository are public, so publishing there would expose the operator's private binary); with no input it is a no-op that reports `BLOCKED_BY_MISSING_INPUT`. It never downloads from a public URL or public file host. On success it uploads `KeychainFix-production-dylib` plus a `KeychainFix-production-report` JSON containing the real before/after hash, size and symbol counts. |
| `scripts/keychainfix_release.sh` | (see above) now also emits an optional `--report-json` before/after report (input/output SHA-256, size, arch, install_name, min OS, dependency count, exported/local/source-STAB counts) only after the gate has passed. |
| `tests/test_ci_production_report.py` | **New.** Fixture-based tests for the reporter: synthetic DEV/PRODUCTION audits plus a synthetic binary whose SHA-256 is computed by the test. Asserts the Markdown/JSON surface the real exported counts, full hashes, size and commit (no fabricated metrics), and that the gate fails closed on SHA mismatch, a banned dependency, an embedded secret, a binary leak, a failing sensitive-string audit and a missing audit script. |
| `RELEASE_PROTECTION_REPORT.md` | This report (tracked baseline). The **CI-updated** copy is generated per run as the `RELEASE_PROTECTION_REPORT.ci.md` artifact by appending a CI-verified section to this baseline; it is gitignored and never committed. |

At the time of this Deliverable A audit, no `Source/` file was changed and no
KeychainFix file was changed. Nothing was staged, committed or pushed. (A later,
separate task integrated the KeychainFix hook into `Source/` — see **§11**; the
findings in §1–§10 remain the historical audit baseline for their scope.)

### Build modes (explicit selector)
- **DEV (default)** — `make`. Theos' debug schema is kept (`DEBUG=1`), so the
  artifact is readable/debuggable: full debug symbols, `-DDEBUG`, `-O0`, `-ggdb`,
  assertions and diagnostics intact, and no link-time stripping. A plain `make`
  therefore never produces a hardened release artifact.
- **PRODUCTION** — `make MODE=production` (CI selects it explicitly). `DEBUG=0`
  removes the debug schema and the release flags below remove the remaining
  symbol / ident / debug / assert surface. The canonical `Source/` tree is not
  touched: hardening is entirely build-time.
- The mapping lives in `scripts/build_mode.mk`; `scripts/audit_build_modes.sh`
  proves both modes and the default without an iOS toolchain, and an unknown
  `MODE` fails the build instead of silently falling through.

### Flags rationale (PRODUCTION only)
- `-fvisibility=hidden` — an injected dylib needs no exported C ABI; Objective-C
  classes are still discovered via `__objc_classlist`, so this only shrinks the
  external symbol surface.
- `-g0` + `DEBUG = 0` + `-Wl,-S` — no DWARF/STABS, therefore no source paths or
  source-file names in the shipped binary.
- `-Wl,-x` — no local symbols in the symbol table.
- `-fno-ident` — no compiler identification string.
- `-DNDEBUG` — compile out `NSAssert`/`assert` in release. Verified safe: the
  only asserts in `Source/` are `NSAssert([NSThread isMainThread], …)` guards in
  `GPSLabLicenseManager.m`; no load-bearing `assert()` exists.

### String protection — what is and is not implemented
- **Implemented (production-only, safe):** compiler-identifier removal
  (`-fno-ident`), debug-info/path removal (`-g0`, `-Wl,-S`), assert-string removal
  (`-DNDEBUG`), local-symbol removal (`-Wl,-x`), and a post-build leak scan
  (`audit_macho.py`) that fails the release gate on embedded build paths, source
  file names, private-key markers or banned hooking references.
- **Implemented (production-only, scoped):** a manifest-driven protected-string
  facility for implementation-revealing *client* literals
  (`Source/GPSLabProtectedStrings.def` -> `scripts/gen_protected_strings.py` ->
  `Source/GPSLabProtectedStringsGenerated.h`). `GPSLAB_PROTECTED_STRING(Symbol)`
  expands to the readable literal in DEV and to a runtime XOR decode in
  PRODUCTION (`-DGPSLAB_PRODUCTION=1`, set by `scripts/build_mode.mk`), so the
  plaintext never reaches the production compiler. Scope is deliberately narrow:
  the defaults-suite namespace and client persistence keys
  (`GPSLab.configuration`, `GPSLab.bookmarks`, `GPSLab.recents`,
  `GPSLab.committedSelection`, `GPSLab.mapStyle`, `GPSLab.pendingSelection`,
  `GPSLab.language`, `GPSLab.simulation.*`). UI/legal/localization copy,
  selectors, class/method/notification names, exported error-domain symbols, the
  build-overridable license endpoint and the Keychain service/account identifiers
  (whose values coincide with method selector names, so they would remain in
  `__objc_methname` regardless) are **not** protected. `scripts/audit_protected_strings.{sh,py}` proves DEV
  readability, PRODUCTION plaintext-freedom and manifest/header sync;
  `tests/gpslab_protected_strings_test.c` proves the decode core and blobs.
- **NOT implemented:** general literal obfuscation/encryption. A literal is only
  protected when it is listed in the manifest; everything else keeps its readable
  string by design. No post-link rewrite of the artifact is performed. DEV builds
  keep all strings by design.

---

## 2. Measured BEFORE state (read-only audit, full hashes)

| Artifact | Size (bytes) | SHA-256 (full) | Arch | install_name | Min OS | Deps | Exported | Local | Source STABS | Signed | Strings | Leaks |
| --- | ---: | --- | --- | --- | --- | ---: | ---: | ---: | ---: | --- | ---: | --- |
| `GPSLab.dylib` (local artifact copy, **debug**) | 1 528 928 | `a76f7330554a8bbe30638207935690997f38d470dba572ee51e2cb868033cd71` | arm64 | `@executable_path/Frameworks/GPSLab.dylib` | 16.0.0 | 12 | 245 | 3 271 | 9 711 | yes | 11 708 | build paths ×63, source files ×62 |
| `.theos/obj/GPSLab.dylib` (stale local) | 786 784 | `f1bbbdf4c4d6aee428902d2432fa2a8857ea4dde73edb70a7c2ce0830d1fac61` | arm64 | `@executable_path/Frameworks/GPSLab.dylib` | 16.0.0 | 10 | 238 | 0 | 0 | yes | 4 829 | none |
| `.theos/obj/arm64/GPSLab.dylib` (stale local) | 780 296 | `0c9d559436c371e1066f3f58acc04ea1bbe47b259c7f8102a57e7b45849d3c6b` | arm64 | `@executable_path/Frameworks/GPSLab.dylib` | 16.0.0 | 10 | 238 | 0 | 0 | no | 4 818 | none |

Key findings:
- The `GPSLab.dylib` copy on disk is a **debug build** — it leaks 63 absolute
  developer build paths and 62 `Source/*.m` names, carries 9 711 source STABS and
  3 271 local symbols, and **is code-signed** (`code_signature: true`).
- The two `.theos/obj` objects are already stripped (0 local symbols, 0 source
  STABS) but are **stale** (10 dependencies vs. the current 12; missing
  `CoreBluetooth` and `NetworkExtension`). They are **not** the release build.
- `dwarf_debug_segment: false` for all three (no `__DWARF` section).
- Every artifact reports `note[credential_literal]: 2` — this is the Security
  framework constant `kSecClassGenericPassword` (matches `password`); it is
  informational, not a leak, and does not fail the gate.

## 3. AFTER state — hardened release build

| Metric | Status |
| --- | --- |
| Build with new flags | **UNVERIFIED — NOT MEASURED.** No iOS SDK/Theos/clang on this host. CI builds it and runs `release_protection.sh` on the produced dylib. |
| size / sha256 / arch / min OS / install_name | **UNVERIFIED.** Expected to stay arm64 / 16.0.0 / `@executable_path/Frameworks/GPSLab.dylib`; no hardened binary exists to measure yet. |
| Strip / debug / leak counts | **ENFORCED BY CI, not yet observed.** `release_protection.sh` fails the build if `dwarf_debug_segment != false`, `symbols_stab_source != 0`, `symbols_local != 0`, or any leak pattern remains. |
| Exported symbol surface | **UNVERIFIED.** Baseline exported count is 238–245; `-fvisibility=hidden` is expected to reduce it, but the hardened count has not been measured. |

Lower-bound evidence that the strip target is achievable: the existing stripped
`.theos/obj` objects already reach 0 local symbols / 0 source STABS / no leaks,
so the stricter flags must meet at least that bar and additionally reduce the
external symbol surface.

## 4. Verification run (this host) — explicit statuses

| Command | Result | Meaning |
| --- | --- | --- |
| `bash scripts/audit_build_modes.sh` | **PASS** | DEV is readable (`DEBUG=1`, no hardening), PRODUCTION is hardened (`DEBUG=0` + all release flags), the default is dev, and an unknown `MODE` is rejected. Evaluated with GNU make only — no iOS toolchain. |
| `bash scripts/release_protection.sh` (static) | **PASS** | Both build modes + source hygiene hold. |
| `make -f Makefile ... verify-mode` (Theos stub, both modes) | **PASS** | The top-level Makefile passes `DEBUG=1`/no-hardening for dev and `DEBUG=0` + release flags for `MODE=production`; `MODE=PRODUCTION` (uppercase) and `MODE=bogus` behave correctly. |
| `bash scripts/release_protection.sh .theos/obj/arm64/GPSLab.dylib` | **PASS (stale artifact only)** | Proves the binary gate *can* pass on a stripped Mach-O. **Does NOT verify the hardened build** — this is a stale local object. |
| `bash scripts/release_protection.sh GPSLab.dylib` | **FAIL (expected)** | 9 711 source STABS, 3 271 local symbols, 63 build paths, 62 source names → the gate detects the debug artifact. |
| `bash scripts/release_protection.sh /nonexistent/GPSLab.dylib` | **FAIL (correct)** | An explicitly supplied missing path now fails instead of silently reporting green. |
| `bash scripts/keychainfix_release.sh --self-check` | **PASS** | Argument/flow contract, `--report-json` arity and canonical `--out`-vs-input collision validated on any host. |
| `bash scripts/keychainfix_release.sh <KeychainFix.dylib>` | **NOT RUN (host limitation)** | Requires macOS `xcrun strip`; no Mach-O toolchain on Windows. The script refuses to run and explains this on non-Darwin hosts. |
| `python3 tests/test_ci_production_report.py` | **PASS** | 9 fixture tests: real exported counts / full hashes / size / commit are surfaced, and the gate fails closed on SHA mismatch, banned dependency, embedded secret, binary leak, failing sensitive-string audit and missing audit script. |
| `bash scripts/validate.sh` (on an LF checkout of the repo + these changes) | **PASS** | All existing static checks still pass. |
| `python scripts/audit_macho.py <binary>` | **PASS** | Works on all GPSLab and KeychainFix arm64 dylibs. |
| Theos action macOS support/SDK | **VERIFIED (source)** | `Randomblock1/theos-action@v1` supports macOS (`brew install ldid make`), clones `theos/theos` and `theos/sdks@master`, which ships `iPhoneOS16.5.sdk`. Its macOS PATH export is a no-op and its SDK fallback naming is fragile; both are compensated in the workflow. |
| Portable C / ObjC unit tests | **NOT RUN** | No C compiler on this host; CI runs them (`tests.yml`). |
| Hardened dylib load / runtime | **UNVERIFIED** | See §5. |

## 5. Load / runtime verification

**NOT PROVEN.** An arm64 iOS Mach-O cannot be `dlopen`-ed on this Windows host,
and there is no iOS device or macOS dyld here. Static invariants only
(arm64, install_name, min OS, dependencies, no banned hooking refs) are checked.
Do not claim the dylib loads until it is run on a device/simulator or macOS.

## 6. KeychainFix audit + protected-artifact release (no Keychain behaviour change)

Source of the input artifacts (audited read-only; **not** modified):
`E:\Project\KeychainFix-Builder\KeychainFix.m` (+ vendored `fishhook.c/h`). Its
build workflow is a single `xcrun … clang -arch arm64 -miphoneos-version-min=14.0
-fobjc-arc -shared …` command, and its `tests/verify.ps1` pins that exact command
string. **That sibling repository and its verified contract were left untouched.**

### 6.1 Audited artifacts (full hashes)

| Artifact | Size (bytes) | SHA-256 (full) | Arch | install_name | Min OS | Deps | Exported | Local | Source STABS | Signed | Strings | Leaks |
| --- | ---: | --- | --- | --- | --- | ---: | ---: | ---: | ---: | --- | ---: | --- |
| `KeychainFix-Builder/output/KeychainFix.dylib` | 67 792 | `8bbcda98136b77b8cc11c1d7f001b337c9fe2127e3e30000969089508ee7fd1d` | arm64 | `KeychainFix.dylib` | 14.0.0 | 5 | 0 | 20 | 0 | no | 103 | none |
| `E:\Project\ipa\KeychainFix.dylib` | 68 056 | `9e9bf9bc7cd6aa26c80a824cfa8440f5208ef0eb8c60dcc92e88938a172bf301` | arm64 | `KeychainFix.dylib` | 14.0.0 | 5 | 0 | 19 | 0 | no | 109 | none |

Observations (no action taken on the sibling repo):
- No debug/string leaks. Debug symbols are already absent (`-shared` default + no
  `-g`), so the release-protection gap is small: only local symbols remain.
- `symbols_external_defined` is **0** for both: the hook/`rebind_symbols` symbols
  are private externs (`N_PEXT`), so the dylib exports no public C ABI. That is
  correct for an injected dylib.
- The two copies differ (67 792 vs 68 056 bytes; 20 vs 19 local symbols), so they
  are **not byte-identical builds**. The release script's `--expect-sha256` flag
  exists precisely to pin which verified input is being promoted.

### 6.2 The release script (`scripts/keychainfix_release.sh`)

Reproducible macOS step that consumes an **existing, already-verified**
`KeychainFix.dylib` and writes `KeychainFix-Release.dylib`:

1. **Protected-artifact gate (input, before anything is written).** Fails unless:
   arm64; `install_name == KeychainFix.dylib`; min OS ≥ 14.0; no `__DWARF`; no
   source STABS; no leak patterns; the six required hook symbols are present
   (`_init_universal_keychain_hook`, `_my_SecItemCopyMatching`, `_my_SecItemAdd`,
   `_my_SecItemUpdate`, `_my_SecItemDelete`, `_rebind_symbols`); `Foundation` and
   `Security` are linked; and, when `--expect-sha256` is supplied, the input hash
   matches. A code-signed input is refused unless `--allow-invalidate-signature`
   is passed.
2. **Mach-O-safe strip on a COPY.** `xcrun strip -x -S` removes local + debug
   symbols only; load commands (install_name/min OS/deps) and global/undefined
   symbols are preserved, so hook behaviour is unchanged. The original is never
   modified; the output path may not equal the input **after canonicalization**
   and must not already exist.
3. **Before/after audit, fail closed.** Prints size/hash/arch/install_name/min
   OS/deps/symbol counts before and after, and fails if arch, install_name, min
   OS or the dependency list changed, if leaks/DWARF/STABS remain, if **any local
   symbol remains** (`strip -x` must reach zero), or if a code signature is still
   present (a stripped signed input leaves a stale/invalid signature command and
   is refused). On ANY failure the newly created output is deleted, so a partial,
   code-signature-invalidated or under-stripped file can never be mistaken for a
   finished release. The produced file is **unsigned**; re-signing and device
   verification are still required (printed by the script).
4. **Runtime/device verification instructions** are printed (re-sign with `ldid`
   if needed, inject into a test IPA, exercise Keychain flows expecting no
   `-34018`/access-group error, confirm installed SHA-256, record device/iOS).

**Runtime verification remains UNVERIFIED.** The script proves *structure* only;
it does not and cannot prove the hook works on a device. The produced artifact has
**not** been generated on this host (no macOS toolchain).

## 7. Secret / string findings

- Log hygiene: release removes debug asserts via `-DNDEBUG`. The only logging is
  `Diagnostics.m`, which uses `os_log` with a strict allow-list and only emits
  counts / state codes (`%{public}d`); no coordinates, identifiers, tokens,
  queries or error descriptions. Left as-is (intentional and allow-listed).
- No private key, `PRIVATE_KEY`, credential literal or signing secret in
  `Source/` (existing `validate.sh` backdoor check also passes).
- `release_protection.sh` now lists offending **file names only** on hygiene
  failures and never echoes matched source lines, so a gate failure cannot print a
  secret to logs. `audit_macho.py` still never prints matched string values
  (`--symbols` is opt-in and symbol names are not secrets).
- License material stays Keychain-only; no token/secret is written to
  `NSUserDefaults`.

## 8. Website / license backend location observation

- `Source/GPSLabLicenseBuildConfig.h` seeds the production endpoint
  `https://vps-6f128567.vps.ovh.net:8443/api/v1/license/check`, issuer `GPSLab`,
  audience `GPSLab-iOS`, and a public ECDSA P-256 verification key (public by
  design). No private key is present.
- The endpoint host appears as a literal string inside the local `GPSLab.dylib`.
  This is intended build configuration but means a shipped binary discloses the
  license backend host/port/path. Public key values are not reproduced here.
- The website/account URLs (`GPSLabSignInURL`, `GPSLabManageAccountURL`) are
  commented out / unset, so no sign-in/manage site is baked in.
- **Claim-alignment note for the web portal (Mawqie-Web):** the portal's default
  `LICENSE_ISSUER`/`LICENSE_AUDIENCE` were aligned to `GPSLab`/`GPSLab-iOS` to
  match this build config, and a `LICENSE_EXPECTED_PUBLIC_KEY` pin now fails
  startup on a signing-key mismatch. The portal must still sign with a private key
  whose public key equals the app's embedded `GPSLabLicensePublicKey`.
- **Web portal production is refused (fail closed).** The portal ships only
  staging components (single-process JSON/in-memory store, mock payment provider,
  unverified `LICENSE_MODE=remote` adapter). Production startup now refuses to
  start until a persistent database, a real payment provider and a verified
  license integration exist, and production local signing requires the
  `LICENSE_EXPECTED_PUBLIC_KEY` pin. Local/staging behavior is unchanged. Trial
  duplicate prevention is best-effort only: emails are never verified and the
  email/installation id are client-supplied. These limitations are stated in
  `Mawqie-Web/README.md`.

## 9. Blockers / decisions for the orchestrator

1. **Hardened GPSLab build + runtime UNVERIFIED.** Run the CI build (or a macOS
   host), confirm `release_protection.sh` passes on the produced dylib, then load
   it on a device/simulator. Until then load is NOT PROVEN.
2. **KeychainFix release artifact NOT generated here.** Run
   `bash scripts/keychainfix_release.sh <verified KeychainFix.dylib>` on macOS
   against an already-verified local artifact, then **re-sign** the unsigned output
   (`ldid -S`) and complete the printed device verification. Structure only has
   been validated; hook behaviour is unchanged by design but unproven at runtime.
3. **Stale/signed debug artifact on disk.** The local `GPSLab.dylib`
   (1 528 928 B, code-signed) and `GPSLab-dylib.zip` are debug builds that leak
   build paths. They are gitignored and were not deleted or replaced; rebuild via
   CI and redistribute.
4. **KeychainFix hardening flags not applied to the sibling repo.** Equivalent
   flags are documented above but deliberately not applied, because its
   `verify.ps1` pins the exact build command and the task forbids altering
   KeychainFix's verified contract. The release script hardens the *artifact*
   instead, without touching the source repo.

---

## 10. Static baseline vs CI-generated actual data

The tables in §2 are a **static, read-only baseline** measured on this Windows
host. They are intentionally *not* updated with invented numbers. The §3 "AFTER"
state is produced by CI from the actual build and is not hardcoded anywhere:

- `.github/workflows/build.yml` builds the DEV baseline and the PRODUCTION
  artifact on a macOS runner, then `scripts/ci_production_report.py` writes
  `GPSLab-production-report.json` (machine-readable) and
  `GPSLab-production-report.md` (human-readable) containing the real SHA-256,
  size, exported/local/source-STAB symbol counts, string count, leak scan, secret
  scan and the sensitive-string binary-audit verdict.
- The same job assembles the **CI-updated** `RELEASE_PROTECTION_REPORT.ci.md` by
  appending a "CI-verified run" section (commit, run URL, the generated report,
  and the explicit device-verification status) to this tracked baseline. The
  generated file is gitignored and is **never committed**: it is uploaded as part
  of the `GPSLab-production-report` artifact only.
- The `GPSLab-production-dylib` artifact contains the production dylib only.
- When a run has completed, treat its uploaded report as the source of truth for
  the "AFTER" metrics; do not quote fixed values from this document for a build
  that has not been measured.

### Device / runtime verification: NOT VERIFIED

CI proves the static build and artifact contract only. Loading the dylib on a
device/simulator and exercising its runtime behaviour are **NOT performed in CI**
and remain **NOT VERIFIED** until an operator completes the steps in §5.

### KeychainFix input safety

The separate `.github/workflows/keychainfix-release.yml` consumes an
already-verified `KeychainFix.dylib` from a **same-repository artifact** only, and
only when this repository is private (artifacts of a public repository are
public). On a public repository it refuses to download-and-publish, so the
operator's private binary can never be exposed there. It never publishes or
downloads the operator's private binary to/from a public URL or public file host.
If no input is supplied it is a no-op that reports `BLOCKED_BY_MISSING_INPUT`, and
the operator runs `scripts/keychainfix_release.sh` locally on macOS; GPSLab's
build is never blocked by KeychainFix. On success it uploads a
`KeychainFix-production-dylib` artifact containing `KeychainFix-Release.dylib`,
and a `KeychainFix-production-report` JSON with the real before/after hash, size
and symbol counts.

---

## 11. Integrated KeychainFix behaviour into GPSLab.dylib (2026-09-24)

New requirement: **one `GPSLab.dylib` must include the behaviour of the
on-device-verified standalone KeychainFix.** This section is additive; the audit
findings in §1–§10 remain valid for their scope.

### 11.1 Changes applied

| File | Purpose |
| --- | --- |
| `Source/fishhook.c`, `Source/fishhook.h` | **New.** Vendored **verbatim** from facebook/fishhook (BSD-3 licence text preserved in the files). The CRLF-normalized SHA-256 matches the builder's pinned contract exactly: `fishhook.h = 5432b81b…620120`, `fishhook.c = 48f51e1a…9b61b`. |
| `Source/GPSLabKeychainCompat.m`, `Source/GPSLabKeychainCompat.h` | **New.** Near-verbatim port of the builder's `KeychainFix.m`: C rebinding of `SecItemCopyMatching`/`Add`/`Update`/`Delete`, `kSecAttrAccessGroup` stripped from a +1 copy, original `OSStatus` returned unchanged, caller dictionaries never mutated. Adds a **hidden, idempotent (`dispatch_once`) explicit install** (`GPSLabKeychainCompatInstall`) that returns whether the rebinding succeeded. |
| `Source/dylib_init.m` | Installs the hook **before** the license manager performs any Keychain access; no other constructor ordering changed. |
| `Makefile` | Compiles both new sources; `Security.framework` was already linked. Header comment corrected (no third-party injection framework; vendored BSD-3 fishhook). |
| `tests/gpslab_keychain_compat_test.c` | **New.** Portable-C source-validated wiring test (50 assertions): provenance/licence, hidden API, all four rebinds, copy-only access-group stripping, balanced CoreFoundation ownership, idempotent hidden install, **unconditional** semantics (no engine/license gate), constructor ordering and Makefile wiring. |
| `scripts/validate.sh` | New "Integrated Keychain compatibility hook" gate: compiled wiring, licence/hidden, un-gated semantics, ordering before `loadAndStart`, Security linkage and CI wiring. |
| `.github/workflows/tests.yml` | New `keychain-compat-wiring-tests` job that compiles and runs the wiring test (portable C, ubuntu). |
| `README.md` | Replaced the inaccurate clean-room claims with a precise **provenance** statement; documented the embedded hook and that the original standalone artifact/builder remain preserved. |
| `RELEASE_PROTECTION_REPORT.md` | This section. |

**No other Keychain logic changed and no check was weakened.**
`Source/GPSLabSecureStore.m`, `Source/GPSLabLicenseManager.m`, the token verifier
and the entitlement gate are untouched, and the hook is deliberately **not** gated
by the engine switch or the license state (identical to the verified standalone
artifact).

### 11.2 Immutable standalone artifacts preserved (unchanged)

| Artifact | SHA-256 / state |
| --- | --- |
| `E:\Project\KeychainFix-Builder\output\KeychainFix.dylib` | `8bbcda98136b77b8cc11c1d7f001b337c9fe2127e3e30000969089508ee7fd1d` (as required) |
| `…\output\KeychainFix.dylib.bak-20260924-044037` | untouched (67 792 B) |
| `E:\Project\GPSLab\KeychainFix.dylib` (read-only copy) | same `8bbcda98…` hash, untouched |
| sibling `KeychainFix-Builder` sources (`KeychainFix.m`, `fishhook.*`, `tests/verify.ps1`) | untouched |

The standalone release script/workflow at `HEAD` was not removed. The corrected
provenance note in §1 and this section are the only places that reference the
builder; the release script itself still consumes an already-built binary and
never reads the builder.

### 11.3 Static verification (this host: Windows 10 + WSL2 Ubuntu 24.04, gcc 13.3)

| Command | Result |
| --- | --- |
| `bash scripts/validate.sh` | **PASS** (includes the new integrated-hook gate) |
| `bash scripts/audit_build_modes.sh` | **PASS** (dev readable; production hardened) |
| `bash scripts/release_protection.sh` | **PASS** (static; no dylib supplied) |
| `cc -I Source tests/gpslab_keychain_compat_test.c && ./…` | **PASS** (50/50) |
| `python3 tests/test_ci_production_report.py` | **PASS** (9/9) |
| vendored fishhook normalized SHA-256 | **MATCHES** the builder's pinned contract |

### 11.4 Build + runtime: NOT MEASURED (exact blocker)

The integrated dylib **could not be built on this host**. There is no macOS, no
Xcode/iOS SDK, no Theos, no `xcrun` and no `clang` for arm64/iOS. Running
`make MODE=production` (or `MODE=dev`) fails at the Theos include:

```
Makefile:108: /library.mk: No such file or directory
make: *** No rule to make target '/library.mk'.  Stop.
```

`$(THEOS)` is unset and no iOS `clang` exists on the host or in WSL. CI on
`macos-latest` (`build.yml`) performs the production build and Mach-O gate. The
hook's on-device behaviour is proven only by the original standalone artifact and
remains **NOT VERIFIED** for this integrated build until it is run on a device.

### 11.5 Canceled standalone-only edits (isolated, recoverable, not integrated)

The canceled standalone-only edits (unrelated to this integration) are parked in a
single stash and are **not** part of the integrated changes:

- stash: `stash@{0}` — commit `37d60e79abb97485b8ec024aedcbe6455cd570eb`,
  message `canceled-standalone-keychainfix-edits-20260924`
- files: `scripts/keychainfix_release.sh`,
  `.github/workflows/keychainfix-release.yml`, `.github/workflows/tests.yml`,
  `README.md`, `RELEASE_PROTECTION_REPORT.md`
- the untracked `tests/test_keychainfix_release.py` was left untouched and is not
  part of the integrated commit.

Nothing was staged, committed or pushed by this integration.

