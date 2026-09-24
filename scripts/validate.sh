#!/usr/bin/env bash
# GPSLab static validation.
#
# Runs without any iOS SDK or Apple toolchain. It enforces the clean-room and
# configuration invariants that would otherwise only fail at build/install time:
#   * every source file is listed in the Makefile;
#   * banned hooking frameworks/dependencies never appear in source;
#   * private Apple frameworks are never imported/linked;
#   * ARC is enabled and the target is arm64/iOS 16+;
#   * the install_name matches the injection contract;
#   * no source file is empty or missing a header guard/import sanity check.
#
# Exit code 0 means every static check passed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAKEFILE="$ROOT/Makefile"
SOURCE_DIR="$ROOT/Source"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

pass() {
    echo "ok: $*"
}

[[ -f "$MAKEFILE" ]] || fail "Makefile not found at $MAKEFILE"
[[ -d "$SOURCE_DIR" ]] || fail "Source directory not found at $SOURCE_DIR"

# ---------------------------------------------------------------- Makefile ----
echo "== Makefile invariants =="
grep -q '^ARCHS = arm64$' "$MAKEFILE" || fail "ARCHS must be exactly 'arm64'"
grep -q 'TARGET = iphone:clang:latest:16.0' "$MAKEFILE" || fail "TARGET must be ios 16.0+"
grep -q 'GPSLab_CFLAGS = -fobjc-arc' "$MAKEFILE" || fail "ARC flag missing from GPSLab_CFLAGS"
grep -q 'Foundation CoreLocation UIKit MapKit' "$MAKEFILE" || fail "expected frameworks missing"
grep -q 'GPSLab_INSTALL_PATH = @executable_path/Frameworks' "$MAKEFILE" \
    || fail "install path must be @executable_path/Frameworks"
grep -q 'scripts/build_mode.mk' "$MAKEFILE" \
    || fail "the Makefile must include scripts/build_mode.mk (DEV/PRODUCTION selector)"
if grep -qE '^[[:space:]]*DEBUG[[:space:]]*=' "$MAKEFILE"; then
    fail "the Makefile must not hardcode DEBUG; the build-mode mapping owns it"
fi
pass "Makefile declares arm64/iOS16/ARC/frameworks/install path + build-mode selector"

# Every .m file on disk must be compiled.
echo "== Source coverage =="
while IFS= read -r file; do
    relative="Source/${file#"$SOURCE_DIR"/}"
    relative="${relative//\\//}"
    grep -q -F "$relative \\\\" "$MAKEFILE" || grep -q -F "$relative" "$MAKEFILE" \
        || fail "source file not listed in Makefile: $relative"
done < <(find "$SOURCE_DIR" -name '*.m' -type f)
pass "every source file is compiled by the Makefile"

# ------------------------------------------------- Shared helper imports ------
echo "== Shared helper declaration imports =="
# A translation unit that calls a shared FOUNDATION_EXPORT helper must be able to
# see its declaration, otherwise clang fails with "call to undeclared function"
# (implicit declarations are errors in C99+). This resolves each unit's transitive
# "#import \"...\"" closure and requires the declaring header to be reachable.
# Non-brittle: the (symbol, header) pairs below are the only rules, the check only
# fires when the symbol is actually referenced, and a transitive import satisfies
# it instead of forcing a specific direct-import line.
import_closure() {
    local -a queue=("$1")
    local -A seen=()
    while ((${#queue[@]})); do
        local name="${queue[0]}"
        queue=("${queue[@]:1}")
        [[ -n "${seen[$name]:-}" ]] && continue
        seen[$name]=1
        local path="$SOURCE_DIR/$name"
        [[ -f "$path" ]] || continue
        local dep
        while IFS= read -r dep; do
            [[ -n "$dep" ]] && queue+=("$dep")
        done < <(grep -hoE '#import "[^"]+"' "$path" 2>/dev/null \
            | sed -E 's/#import "(.*)"/\1/')
    done
    printf '%s\n' "${!seen[@]}"
}

require_declaring_import() {
    local unit="$1" symbol="$2" header="$3"
    local path="$SOURCE_DIR/$unit"
    [[ -f "$path" ]] || fail "translation unit missing: Source/$unit"
    grep -q -F "$symbol" "$path" || return 0
    local closure
    closure="$(import_closure "$unit")"
    grep -qx -F "$header" <<<"$closure" \
        || fail "Source/$unit uses $symbol but cannot see its declaration in $header"
    pass "Source/$unit sees $symbol via $header"
}

require_declaring_import "GPSLabGeodesy.m" "GPSLabClampDouble" "GPSLabTypes.h"
require_declaring_import "GPSLabDriftModel.m" "GPSLabClampDouble" "GPSLabTypes.h"
require_declaring_import "GPSLabConfiguration.m" "GPSLabNormalizeHeading" "GPSLabGeodesy.h"
require_declaring_import "GPSLabOverlayViewController.m" "GPSLabSearchSessionBegin" "GPSLabSearchLayoutCore.h"
require_declaring_import "GPSLabSearchResultsViewController.m" "GPSLabSearchQueryIsSearchable" "GPSLabSearchLayoutCore.h"
require_declaring_import "GPSLabProfileStore.m" "GPSLabProfileCountValid" "GPSLabProfileCore.h"
require_declaring_import "GPSLabScheduler.m" "GPSLabProfileScheduleShouldApply" "GPSLabProfileCore.h"
require_declaring_import "GPSLabEngineProfileBackend.m" "GPSLabClampDouble" "GPSLabTypes.h"
require_declaring_import "GPSLabScheduler.m" "GPSLabSchedulerNextAction" "GPSLabSchedulerCore.h"

# ------------------------------------------------- Declared-API usage ----------
echo "== Declared-API usage invariants =="
# These are deny-list guards for names that look plausible but do not exist in
# the public SDK / the project. Each check only fires on the exact bad token, so
# it stays non-brittle: any correct spelling passes untouched. They prevent the
# same class of "implicit declaration"/"undeclared identifier" build breaks.
STATUS_LOG="$SOURCE_DIR/GPSLabStatusLog.h"

grep -q -F "+ (void)append:(NSString *)message;" "$STATUS_LOG" \
    || fail "GPSLabStatusLog must declare +append:"
if grep -r -n -F "GPSLabStatusLogAppend" "$SOURCE_DIR" >/dev/null 2>&1; then
    grep -r -n -F "GPSLabStatusLogAppend" "$SOURCE_DIR" >&2 || true
    fail "GPSLabStatusLogAppend is undeclared; call [GPSLabStatusLog append:]"
fi
pass "status log only uses the declared +append: API"

if grep -r -n -F "MKPointOfInterestFilterIncludingAll" "$SOURCE_DIR" >/dev/null 2>&1; then
    fail "MKPointOfInterestFilterIncludingAll is not a public MapKit symbol; use [MKPointOfInterestFilter filterIncludingAllCategories]"
fi
pass "MapKit point-of-interest filter uses the public class method"

# currentCoordinate:course: is declared under NS_ASSUME_NONNULL_BEGIN, so a NULL
# out-param is a -Wnonnull error under -Werror. A local variable must be passed.
if grep -r -n -E 'course:[[:space:]]*NULL' "$SOURCE_DIR" >/dev/null 2>&1; then
    grep -r -n -E 'course:[[:space:]]*NULL' "$SOURCE_DIR" >&2 || true
    fail "currentCoordinate:course: rejects NULL; pass a local out-param variable"
fi
pass "no NULL passed to currentCoordinate:course:"

# ------------------------------------------------------------- Clean-room -----
echo "== Clean-room / dependency bans =="
BANNED='substrate|ellekit|libhooker|cydia'
if grep -r -n -i -E "$BANNED" "$SOURCE_DIR" "$MAKEFILE" >/dev/null 2>&1; then
    grep -r -n -i -E "$BANNED" "$SOURCE_DIR" "$MAKEFILE" >&2 || true
    fail "banned hooking framework referenced"
fi
pass "no banned hooking framework references"

BANNED_IMPORTS='CydiaSubstrate|substrate\.h|ellekit|libhooker'
if grep -r -n -i -E "$BANNED_IMPORTS" "$SOURCE_DIR" >/dev/null 2>&1; then
    grep -r -n -i -E "$BANNED_IMPORTS" "$SOURCE_DIR" >&2 || true
    fail "banned hooking framework import found"
fi
pass "no banned hooking framework imports"

PRIVATE_FRAMEWORKS='PrivateFramework|/System/Library/PrivateFrameworks|CLLocationInternal|MKLocationManager'
if grep -r -n -E "$PRIVATE_FRAMEWORKS" "$SOURCE_DIR" >/dev/null 2>&1; then
    fail "private framework reference found"
fi
pass "no private framework references"

if grep -r -n -E 'dlopen|dlsym' "$SOURCE_DIR" >/dev/null 2>&1; then
    fail "dynamic loading (dlopen/dlsym) is not allowed"
fi
pass "no dynamic loading"

if grep -r -n -E '\bSwift\b|import SwiftUI' "$SOURCE_DIR" >/dev/null 2>&1; then
    fail "Swift sources are out of scope; GPSLab is Objective-C only"
fi
pass "Objective-C only"

# ------------------------------------------------------------------- ARC ------
echo "== ARC safety =="
if grep -r -n -E '\bretain\b|\brelease\b|\bautorelease\b' "$SOURCE_DIR" \
        --include='*.m' | grep -v -E '^[^:]+:[0-9]+: *//' >/dev/null 2>&1; then
    grep -r -n -E '\bretain\b|\brelease\b|\bautorelease\b' "$SOURCE_DIR" --include='*.m' >&2 || true
    fail "manual retain/release found under ARC"
fi
pass "no manual retain/release under ARC"

# --------------------------------------------------------------- Diagnostics --
echo "== Diagnostics allow-list =="
if grep -r -n -E 'GPSLabDiag[A-Za-z]*\([^)]*(latitude|longitude|coordinate)' "$SOURCE_DIR" \
        --include='*.m' >/dev/null 2>&1; then
    fail "diagnostics must never receive coordinates"
fi
if grep -r -n -E 'GPSLabDiagInternalError\([^)]*,' "$SOURCE_DIR" --include='*.m' >/dev/null 2>&1; then
    fail "GPSLabDiagInternalError must take a code only (no dynamic text)"
fi
if grep -r -n -E 'GPSLabDiag[A-Za-z]*\([^)]*localizedDescription' "$SOURCE_DIR" \
        --include='*.m' >/dev/null 2>&1; then
    fail "diagnostics must never log NSError.localizedDescription"
fi
DIAG_H="$SOURCE_DIR/Diagnostics.h"
grep -q -F "void GPSLabDiagInternalError(NSInteger code);" "$DIAG_H" \
    || fail "GPSLabDiagInternalError must take a stable numeric code only"
if grep -r -n -E 'GPSLabDiag[A-Za-z]*\([^)]*query' "$SOURCE_DIR" --include='*.m' >/dev/null 2>&1; then
    fail "diagnostics must never log a search query"
fi
pass "diagnostics receive no coordinates, text or error descriptions"

# ------------------------------------------------------- CoreLocation hooks ----
echo "== Hook passthrough contract =="
HOOKS="$SOURCE_DIR/CoreLocationHooks.m"
[[ -f "$HOOKS" ]] || fail "CoreLocationHooks.m missing"

require_capture() {
    local selector="$1" pointer="$2"
    grep -q -F "@selector($selector)" "$HOOKS" || fail "hook selector missing: $selector"
    grep -q -F "$pointer" "$HOOKS" || fail "original IMP not captured for $selector ($pointer)"
}
require_capture "setDelegate:" "gGPSLabOriginalSetDelegate"
require_capture "location" "gGPSLabOriginalLocation"
require_capture "startUpdatingLocation" "gGPSLabOriginalStartUpdatingLocation"
require_capture "stopUpdatingLocation" "gGPSLabOriginalStopUpdatingLocation"
require_capture "requestLocation" "gGPSLabOriginalRequestLocation"
require_capture "startMonitoringSignificantLocationChanges" "gGPSLabOriginalStartSignificant"
require_capture "stopMonitoringSignificantLocationChanges" "gGPSLabOriginalStopSignificant"
require_capture "requestWhenInUseAuthorization" "gGPSLabOriginalRequestWhenInUse"
require_capture "requestAlwaysAuthorization" "gGPSLabOriginalRequestAlways"
require_capture "authorizationStatus" "gGPSLabOriginalAuthorizationStatusClass"
require_capture "authorizationStatus" "gGPSLabOriginalAuthorizationStatusInstance"
require_capture "accuracyAuthorization" "gGPSLabOriginalAccuracyAuthorization"
require_capture "locationServicesEnabled" "gGPSLabOriginalLocationServicesEnabled"

# Every original pointer must be both declared and actually passed to a swizzle.
for pointer in gGPSLabOriginalLocation gGPSLabOriginalSetDelegate \
    gGPSLabOriginalStartUpdatingLocation gGPSLabOriginalStopUpdatingLocation \
    gGPSLabOriginalRequestLocation gGPSLabOriginalStartSignificant \
    gGPSLabOriginalStopSignificant gGPSLabOriginalRequestWhenInUse \
    gGPSLabOriginalRequestAlways gGPSLabOriginalAuthorizationStatusClass \
    gGPSLabOriginalAuthorizationStatusInstance gGPSLabOriginalAccuracyAuthorization \
    gGPSLabOriginalLocationServicesEnabled; do
    grep -q -F "$pointer" "$HOOKS" || fail "original pointer missing: $pointer"
    grep -q -F "&$pointer" "$HOOKS" || fail "original pointer never captured: $pointer"
done
pass "every intercepted selector captures its original IMP (incl. setDelegate:)"

grep -q -F "gGPSLabOriginalSetDelegate(self, _cmd, delegate)" "$HOOKS" \
    || fail "setDelegate: must always forward to the captured original"
grep -q -F "forwardSelector:" "$HOOKS" || fail "original-IMP forward API missing"
grep -q -F "setBypassed:" "$HOOKS" || fail "per-manager bypass API missing"
pass "setDelegate always forwards; bypass + forward APIs present"

# --------------------------------------------------- Stream intent transitions --
echo "== Stream intent transitions =="
STREAM="$SOURCE_DIR/LocationStream.m"
ENGINE="$SOURCE_DIR/GPSLabEngine.m"
[[ -f "$STREAM" ]] || fail "LocationStream.m missing"
[[ -f "$ENGINE" ]] || fail "GPSLabEngine.m missing"

for symbol in requestStandardForManager cancelStandardForManager \
    requestSignificantForManager cancelSignificantForManager \
    suspendAllSyntheticPreservingIntent resumeAllRequestedSynthetic \
    standardRequestedManagers significantRequestedManagers requestedManagers; do
    grep -q -F "$symbol" "$STREAM" || fail "stream intent API missing: $symbol"
done
# Both start hooks must record intent before the enable/bypass decision.
grep -q -F "requestStandardForManager:manager]" "$HOOKS" \
    || fail "standard start hook must record intent (even while disabled)"
grep -q -F "requestSignificantForManager:manager]" "$HOOKS" \
    || fail "significant start hook must record intent (even while disabled)"
# Both stop hooks must clear intent.
grep -q -F "cancelStandardForManager:manager]" "$HOOKS" || fail "standard stop hook must clear intent"
grep -q -F "cancelSignificantForManager:manager]" "$HOOKS" || fail "significant stop hook must clear intent"
# Transitions must hand back / take back the original streams and resume synthetic.
grep -q -F "standardRequestedManagers" "$ENGINE" || fail "engine must start only the requested originals"
grep -q -F "significantRequestedManagers" "$ENGINE" || fail "engine must start only the requested originals"
grep -q -F "resumeAllRequestedSynthetic" "$ENGINE" || fail "engine must resume synthetic on enable"
grep -q -F "resumeAllRequestedSynthetic" "$SOURCE_DIR/GPSLabRuntime.m" \
    || fail "runtime must resume synthetic on foreground"
grep -q -F "suspendAllSyntheticPreservingIntent" "$SOURCE_DIR/GPSLabRuntime.m" \
    || fail "runtime must suspend preserving intent on background"
pass "intent is recorded independent of timer state and survives suspend/resume"

# -------------------------------------------------- Bypass / real-location ------
echo "== Bypass and real-location display =="
OVERLAY="$SOURCE_DIR/GPSLabOverlayViewController.m"
[[ -f "$OVERLAY" ]] || fail "GPSLabOverlayViewController.m missing"
# Any direct use of the hook class in this TU must be paired with a direct import.
if grep -q -F "GPSLabCoreLocationHooks" "$OVERLAY"; then
    grep -q -F '#import "CoreLocationHooks.h"' "$OVERLAY" \
        || fail "GPSLabOverlayViewController.m uses GPSLabCoreLocationHooks without importing CoreLocationHooks.h"
fi
grep -q -F "showsUserLocation = NO" "$OVERLAY" \
    || fail "overlay must not use MKMapView.showsUserLocation"
grep -q -F "setBypassed:YES forManager:" "$OVERLAY" \
    || fail "the real-location display manager must be bypassed"
grep -q -F "didUpdateLocations" "$OVERLAY" || fail "real location must update from didUpdateLocations"
grep -q -F "removeAnnotation:self.realLocationAnnotation" "$OVERLAY" \
    || fail "the real-location annotation must be removed when display is turned off"
pass "real location uses a bypassed manager + separate annotation, never showsUserLocation"

# ------------------------------------------------- Reference panel layout -----
echo "== Reference panel layout =="
# The approved reference is ONE compact floating panel over a lightweight map
# snapshot background. The header and the standalone search bar are pinned; the
# scrolling body starts with a real, interactive 278pt MKMapView card. This
# supersedes the earlier "map owns the whole safe area" guard (explicitly
# overridden by the user-approved reference rebuild).
if grep -r -n -F "GPSLabOverlayScrollView" "$SOURCE_DIR" >/dev/null 2>&1; then
    fail "the old scrolling dashboard container must not be reintroduced"
fi
if grep -n -E 'addArrangedSubview:self\.mapView|initWithArrangedSubviews:@\[self\.mapView' "$OVERLAY" >/dev/null 2>&1; then
    fail "the map must be inside the map card, not a bare arranged subview"
fi
if grep -n -F "controlsStack" "$OVERLAY" >/dev/null 2>&1; then
    fail "the old floating control button stack must not be reintroduced"
fi
grep -q -F "self.panelView.layer.cornerRadius = 28.0" "$OVERLAY" \
    || fail "panel must use the reference 28pt corner radius"
grep -q -F "[self.panelView.topAnchor constraintEqualToAnchor:safe.topAnchor" "$OVERLAY" \
    || fail "panel must be pinned to the safe-area top"
grep -q -F "[self.panelView.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor" "$OVERLAY" \
    || fail "panel must be pinned to the safe-area bottom"
grep -q -F "[self.headerView.topAnchor constraintEqualToAnchor:self.panelView.topAnchor" "$OVERLAY" \
    || fail "header must be pinned inside the panel"
grep -q -F "[self.searchBarContainer.topAnchor constraintEqualToAnchor:self.serviceRowView.bottomAnchor" "$OVERLAY" \
    || fail "search bar must be pinned below the service row"
grep -q -F "[self.serviceRowView.topAnchor constraintEqualToAnchor:self.headerView.bottomAnchor" "$OVERLAY" \
    || fail "service row must be pinned below the header"
grep -q -F "[self.mapCard addSubview:mapView]" "$OVERLAY" \
    || fail "the interactive MKMapView must be added to the visible map card"
grep -q -F "[self.mapCard.heightAnchor constraintEqualToConstant:246.0]" "$OVERLAY" \
    || fail "the map card must be the reference 246pt tall"
grep -q -F "self.mapCard.layer.cornerRadius = 22.0" "$OVERLAY" \
    || fail "map card must use the reference 22pt radius"
grep -q -F "mapView.scrollEnabled = YES" "$OVERLAY" \
    || fail "the map card must remain interactive"
grep -q -F "[self.bodyStack addArrangedSubview:[self mapAreaContainer]]" "$OVERLAY" \
    || fail "the map card must live in the scrolling body"
grep -q -F "GPSLabSearchBarHeight(intrinsicHeight, 54.0)" "$OVERLAY" \
    || fail "the reference search row must be 54pt"
grep -q -F "MKMapSnapshotOptions" "$OVERLAY" \
    || fail "the dimmed map background must use a lightweight MapKit snapshot"
grep -q -F "GPSLabProfilesPanelView" "$OVERLAY" \
    || fail "the reference profiles card must be hosted by the overlay"
grep -q -F "subscription.compact.title" "$OVERLAY" \
    || fail "the compact read-only subscription footer must be present"
pass "one compact panel; pinned header/service/search; real 246pt interactive map card; scroll body"

# ---------------------------------------------- Service / map-link / altitude --
echo "== Service row, map links, altitude =="
# The master switch reuses the single engine path; OFF is passthrough only.
grep -q -F "@selector(masterTapped)" "$OVERLAY" \
    || fail "the service row must reuse the existing master engine toggle"
grep -q -F "setEnabledAndNotify:" "$OVERLAY" \
    || fail "the service row must drive the engine through setEnabledAndNotify:"
grep -q -F "noteManualEngineDisable" "$OVERLAY" \
    || fail "disabling the service must keep the scheduler's manual-disable intent"
if grep -q -F "suspendAllSyntheticPreservingIntent" "$OVERLAY"; then
    fail "the service switch must never suspend/tear down the synthetic runtime"
fi
if grep -q -F "clearPersistedCoordinate" "$OVERLAY"; then
    fail "the service switch must never erase persisted configuration"
fi

# Map-link policy core is the single source of truth, compiled and ref-strict.
[[ -f "$SOURCE_DIR/GPSLabMapLinkCore.c" ]] || fail "GPSLabMapLinkCore.c missing"
[[ -f "$SOURCE_DIR/GPSLabMapLinkCore.h" ]] || fail "GPSLabMapLinkCore.h missing"
grep -q -F "Source/GPSLabMapLinkCore.c" "$MAKEFILE" \
    || fail "map-link core must be compiled by the Makefile"
[[ -f "$SOURCE_DIR/GPSLabMapLinkResolver.m" ]] || fail "GPSLabMapLinkResolver.m missing"
grep -q -F "Source/GPSLabMapLinkResolver.m" "$MAKEFILE" \
    || fail "map-link resolver must be compiled by the Makefile"
[[ -f "$SOURCE_DIR/GPSLabMapLinkURLSessionTransport.m" ]] || fail "GPSLabMapLinkURLSessionTransport.m missing"
grep -q -F "Source/GPSLabMapLinkURLSessionTransport.m" "$MAKEFILE" \
    || fail "map-link transport must be compiled by the Makefile"
TRANSPORT="$SOURCE_DIR/GPSLabMapLinkURLSessionTransport.m"
ALTVC="$SOURCE_DIR/GPSLabAltitudeViewController.m"
INTENT="$SOURCE_DIR/GPSLabMasterIntentGuard.m"
[[ -f "$SOURCE_DIR/GPSLabMapLinkURLSessionTransportTesting.h" ]] \
    || fail "GPSLabMapLinkURLSessionTransportTesting.h missing"
[[ -f "$SOURCE_DIR/GPSLabAltitudeViewController.m" ]] || fail "GPSLabAltitudeViewController.m missing"
grep -q -F "Source/GPSLabAltitudeViewController.m" "$MAKEFILE" \
    || fail "altitude editor must be compiled by the Makefile"
[[ -f "$INTENT" ]] || fail "GPSLabMasterIntentGuard.m missing"
grep -q -F "Source/GPSLabMasterIntentGuard.m" "$MAKEFILE" \
    || fail "master-intent guard must be compiled by the Makefile"
grep -q -F '#import "GPSLabMapLinkCore.h"' "$TRANSPORT" \
    || fail "the transport must reuse the policy core (no duplicated rules)"
grep -q -F '#import "GPSLabMapLinkCore.h"' "$SOURCE_DIR/GPSLabMapLinkResolver.m" \
    || fail "the resolver must reuse the policy core (no duplicated rules)"
# The resolver consumes the transport seam (per-request identity, injectable).
grep -q -F '#import "GPSLabMapLinkTransport.h"' "$SOURCE_DIR/GPSLabMapLinkResolver.m" \
    || fail "the resolver must depend on the transport seam"
grep -q -F "initWithTransport:" "$SOURCE_DIR/GPSLabMapLinkResolver.m" \
    || fail "the resolver must allow an injected transport (offline tests)"
grep -q -F "_activeText" "$SOURCE_DIR/GPSLabMapLinkResolver.m" \
    || fail "the resolver must guard the requested text against stale callbacks"
for host in '"maps.app.goo.gl"' '"google.com"' '"www.google.com"' '"maps.google.com"' '"maps.apple.com"'; do
    grep -q -F "$host" "$SOURCE_DIR/GPSLabMapLinkCore.c" \
        || fail "missing exact allowlisted host: $host"
done
# Strict HTTPS-only ephemeral session; no cookies/cache/credentials; bounded.
grep -q -F "ephemeralSessionConfiguration" "$TRANSPORT" \
    || fail "transport must use an isolated ephemeral session"
grep -q -F "HTTPShouldSetCookies = NO" "$TRANSPORT" \
    || fail "transport must disable cookies"
grep -q -F "URLCache = nil" "$TRANSPORT" \
    || fail "transport must disable the URL cache"
grep -q -F "URLCredentialStorage = nil" "$TRANSPORT" \
    || fail "transport must disable credential storage"
grep -q -F "HTTPAdditionalHeaders = nil" "$TRANSPORT" \
    || fail "transport must not add custom headers"
# Every redirect is validated BEFORE it is followed and rebuilt as a clean GET.
grep -q -F "willPerformHTTPRedirection" "$TRANSPORT" \
    || fail "transport must intercept redirects"
grep -q -F "completionHandler(nil)" "$TRANSPORT" \
    || fail "transport must reject an untrusted redirect instead of following it"
grep -q -F "shouldFollowRedirectToURLString" "$TRANSPORT" \
    || fail "transport must expose the redirect trust decision"
grep -q -F "sanitizedRedirectRequestForTarget" "$TRANSPORT" \
    || fail "transport must rebuild a clean GET for each redirect"
grep -q -F 'HTTPMethod = @"GET"' "$TRANSPORT" \
    || fail "transport must issue GET requests"
grep -q -F "dispositionForAuthenticationMethod" "$TRANSPORT" \
    || fail "transport must handle challenges explicitly"
grep -q -F "didReceiveChallenge" "$TRANSPORT" \
    || fail "transport must implement challenge handlers"
grep -q -F "HTTP Basic/Digest/NTLM" "$TRANSPORT" \
    || fail "transport must implement the TASK-level challenge handler (HTTP auth)"
grep -q -F "NSURLAuthenticationMethodServerTrust" "$TRANSPORT" \
    || fail "transport must default-handle only server trust"
grep -q -F "NSURLSessionAuthChallengeCancelAuthenticationChallenge" "$TRANSPORT" \
    || fail "transport must cancel non-server-trust challenges"
grep -q -F "NSURLSessionResponseCancel" "$TRANSPORT" \
    || fail "transport must cancel on response headers (never read the body)"
grep -q -F "GPSLAB_MAP_LINK_MAX_REDIRECTS" "$TRANSPORT" \
    || fail "transport must bound the redirect count"
grep -q -F "GPSLabMapLinkTransportErrorUntrustedRedirect" "$TRANSPORT" \
    || fail "an untrusted redirect must finish deterministically (not via later callbacks)"
grep -q -F "delegateQueue" "$TRANSPORT" \
    || fail "transport must serialize delegate state on a single queue"
pass "service reuses the engine path; isolated per-request strict-HTTPS map-link transport"

# Altitude: tappable box + reference-styled sheet editor (NOT UIAlertController).
grep -q -F "altitudeTapped" "$OVERLAY" || fail "altitude box must open the editor"
grep -q -F '@selector(altitudeTapped)' "$OVERLAY" || fail "altitude box must be tappable"
grep -q -F "GPSLabAltitudeViewController" "$OVERLAY" \
    || fail "the altitude editor must use the styled sheet controller"
grep -q -F "presentSheetRoot:editor" "$OVERLAY" \
    || fail "the altitude editor must be presented through the sheet coordinator"
grep -q -F 'altitude.zero' "$ALTVC" || fail "altitude editor must have a zero action"
grep -q -F 'altitude.apply' "$ALTVC" || fail "altitude editor must have an apply action"
grep -q -F "altitude.error.range" "$ALTVC" || fail "altitude must validate the supported range explicitly"
grep -q -F "forceLeftToRight:self.valueField" "$ALTVC" \
    || fail "the altitude numeric field must be explicitly LTR"
grep -q -F "GPSLabProfileAltitudeValid" "$ALTVC" \
    || fail "the altitude editor must reuse the shared range policy"
grep -q -F "altitudeStringForValue" "$OVERLAY" || fail "altitude display must not truncate fractions"
pass "altitude editor is a reference-styled sheet with validation and LTR input"

# Master-switch intent ownership: stale completions never roll back newer state.
grep -q -F "masterIntentGuard" "$OVERLAY" \
    || fail "the overlay must use the master-intent guard"
grep -q -F "invalidateIntents" "$OVERLAY" \
    || fail "a manual switch change must invalidate pending applies"
grep -q -F "GPSLabMasterIntentResolutionIgnoreStale" "$OVERLAY" \
    || fail "a superseded/cancelled apply completion must be ignored"
grep -q -F "beginIntent" "$OVERLAY" || fail "a profile apply must claim the switch intent"
pass "master-switch intents are guarded; stale completions cannot roll back newer state"

# Search transitions must cancel the resolver and the place search.
grep -q -F "[[GPSLabMapLinkResolver sharedResolver] cancel]" "$OVERLAY" \
    || fail "input transitions/lifecycle must cancel the map-link resolver"
grep -q -F "cancelActiveSearch]" "$OVERLAY" \
    || fail "switching to maps mode must cancel the active place search"

# Profiles: optional, backward-compatible enabled preference (never coordinator/scheduler).
grep -q -F 'kGPSLabProfileKeyEnabled = @"enabled"' "$SOURCE_DIR/GPSLabProfile.m" \
    || fail "profile model must define the optional enabled key"
grep -q -F "profileWithEnabledPreference:" "$SOURCE_DIR/GPSLabProfile.m" \
    || fail "profile model must support an explicit enabled preference"
grep -q -F "if (self.hasEnabledPreference)" "$SOURCE_DIR/GPSLabProfile.m" \
    || fail "enabled must only be persisted when explicitly present (backward compatible)"
grep -q -F "if (dictionary[kGPSLabProfileKeyEnabled] != nil)" "$SOURCE_DIR/GPSLabProfile.m" \
    || fail "absent enabled must keep legacy semantics"
grep -q -F "profile.hasEnabledPreference" "$OVERLAY" \
    || fail "the UI adapter must only restore an explicitly saved switch state"
grep -q -F "stageProfile:" "$OVERLAY" \
    || fail "a disabled profile must be staged while the engine stays off"
grep -q -F "applyStagedProfileUI" "$OVERLAY" \
    || fail "a staged disabled profile must restore its saved route/config UI"
grep -q -F "wasEnabled" "$OVERLAY" \
    || fail "the switch change must be rolled back when an apply fails"
grep -q -F "isValidForApplication" "$OVERLAY" \
    || fail "the UI adapter must preflight before touching the switch"
grep -q -F "if (!editing)" "$OVERLAY" \
    || fail "saving an edit must not overwrite the existing enabled preference"
grep -q -F "profileWithEnabledPreference:" "$OVERLAY" \
    || fail "a new profile must capture the live switch state"
grep -q -F "stageProfile:" "$SOURCE_DIR/GPSLabProfileApplicationCoordinator.m" \
    || fail "the coordinator must expose the optional staging adapter"
grep -q -F "profileWithEnabledPreference:" "$SOURCE_DIR/GPSLabProfileFormViewController.m" \
    || fail "the profile form must preserve the optional enabled field on edit"
if grep -q -F "setEnabledAndNotify" "$SOURCE_DIR/GPSLabProfileApplicationCoordinator.m"; then
    fail "the coordinator must still never toggle the engine"
fi
if grep -q -F "setEnabledAndNotify:YES" "$SOURCE_DIR/GPSLabScheduler.m" "$SOURCE_DIR/GPSLabSchedulerDefaultHost.m" >/dev/null 2>&1; then
    fail "the scheduler must still never enable the engine"
fi
pass "profiles carry an optional enabled state; coordinator/scheduler gating unchanged"

for testfile in tests/gpslab_map_link_test.c tests/GPSLabMapLinkResolverTests.m tests/gpslab_altitude_test.c tests/GPSLabEngineTests.m tests/GPSLabMasterIntentGuardTests.m; do
    [[ -f "$ROOT/$testfile" ]] || fail "test missing: $testfile"
done
pass "map-link core, resolver, altitude, engine and master-intent tests are present"

# ------------------------------------------------- Profiles / modules ---------
echo "== Profiles / modules / schedule =="
for file in GPSLabTheme.m GPSLabProfileCore.c GPSLabProfile.m GPSLabProfileStore.m \
    GPSLabSimulationModule.m GPSLabWiFiSimulationModule.m GPSLabBluetoothSimulationModule.m \
    GPSLabSimulationRegistry.m GPSLabProfileApplicationCoordinator.m GPSLabEngineProfileBackend.m \
    GPSLabSchedulerCore.c GPSLabScheduler.m GPSLabSchedulerDefaultHost.m \
    GPSLabProfilesPanelView.m GPSLabProfileFormViewController.m \
    GPSLabSimulationSettingsViewController.m GPSLabScheduleViewController.m; do
    [[ -f "$SOURCE_DIR/$file" ]] || fail "missing new source: $file"
    grep -q -F "Source/$file" "$MAKEFILE" || fail "new source not compiled: $file"
done
# Simulation modules are config-only: no hardware, scan, pairing or identity API.
if grep -r -n -E 'CNCopy|CBCentralManager|CBPeripheral|CBAdvertisement|NEHotspot|CoreBluetooth' \
        "$SOURCE_DIR/GPSLabWiFiSimulationModule.m" "$SOURCE_DIR/GPSLabBluetoothSimulationModule.m" \
        "$SOURCE_DIR/GPSLabSimulationRegistry.m" "$SOURCE_DIR/GPSLabSimulationModule.m" >/dev/null 2>&1; then
    fail "simulation modules must not reference Wi-Fi/Bluetooth hardware or identity APIs"
fi
pass "simulation modules are config-only (no hardware/identity APIs)"
grep -q -F "NSDataWritingAtomic" "$SOURCE_DIR/GPSLabProfileStore.m" \
    || fail "profile store must write atomically"
grep -q -F "NSFileProtectionCompleteUntilFirstUserAuthentication" "$SOURCE_DIR/GPSLabProfileStore.m" \
    || fail "profile store must set file protection"
grep -q -F "NSURLIsExcludedFromBackupKey" "$SOURCE_DIR/GPSLabProfileStore.m" \
    || fail "profile store must exclude backups"
grep -q -F "quarantineOnQueue" "$SOURCE_DIR/GPSLabProfileStore.m" \
    || fail "profile store must quarantine a corrupted file"
pass "profile store is atomic, protected, backup-excluded and quarantines corruption"
grep -q -F "isLicenseUnlocked" "$SOURCE_DIR/GPSLabProfileApplicationCoordinator.m" \
    || fail "profile coordinator must gate on the license"
if grep -q -F "setEnabledAndNotify" "$SOURCE_DIR/GPSLabProfileApplicationCoordinator.m"; then
    fail "profile coordinator must never enable/disable the engine directly"
fi
pass "profile coordinator gates on license and never toggles the engine"
grep -q -F "GPSLabSchedulerNextAction" "$SOURCE_DIR/GPSLabScheduler.m" \
    || fail "scheduler must use the pure C apply gate"
grep -q -F "noteManualEngineDisable" "$SOURCE_DIR/GPSLabScheduler.m" \
    || fail "scheduler must honor a manual disable"
grep -q -F "GPSLabLicenseStateDidChangeNotification" "$SOURCE_DIR/GPSLabSchedulerDefaultHost.m" \
    || fail "scheduler must observe license state read-only"
pass "scheduler is gated, foreground-only and read-only on license"
for testfile in tests/gpslab_profile_test.c tests/gpslab_schedule_test.c \
    tests/GPSLabProfileTests.m tests/GPSLabProfileApplicationTests.m \
    tests/GPSLabSimulationModuleTests.m tests/gpslab_scheduler_test.c \
    tests/GPSLabSchedulerTests.m; do
    [[ -f "$ROOT/$testfile" ]] || fail "test missing: $testfile"
done
pass "profile/schedule/simulation/scheduler tests are present"

# ------------------------------------------------------------- Scheduler -------
echo "== Scheduler policy =="
grep -q -F "Source/GPSLabSchedulerCore.c" "$MAKEFILE" \
    || fail "scheduler core must be compiled by the Makefile"
grep -q -F "Source/GPSLabSchedulerDefaultHost.m" "$MAKEFILE" \
    || fail "scheduler host must be compiled by the Makefile"
grep -q -F "GPSLabSchedulerNextAction" "$SOURCE_DIR/GPSLabScheduler.m" \
    || fail "scheduler must use the pure C decision core"
grep -q -F "handleTimerGeneration" "$SOURCE_DIR/GPSLabScheduler.m" \
    || fail "scheduler must guard stale timer wakes with a generation"
grep -q -F "UIApplicationDidEnterBackgroundNotification" "$SOURCE_DIR/GPSLabSchedulerDefaultHost.m" \
    || fail "scheduler must suspend its timer in the background"
if grep -q -F "setEnabledAndNotify:YES" "$SOURCE_DIR/GPSLabScheduler.m" \
        "$SOURCE_DIR/GPSLabSchedulerDefaultHost.m" >/dev/null 2>&1; then
    fail "scheduler must never enable the engine"
fi
grep -q -F "appliedProfileIdentifier" "$SOURCE_DIR/GPSLabSchedulerDefaultHost.m" \
    || fail "scheduler ownership must come from the coordinator, not UI selection"
pass "scheduler is gated, foreground-only, stale-safe and never enables the engine"

# --------------------------------------------------------------- Search --------
echo "== Search request hygiene =="
SEARCH="$SOURCE_DIR/GPSLabSearchResultsViewController.m"
SEARCH_CORE="$SOURCE_DIR/GPSLabSearchLayoutCore.c"
SEARCH_CORE_H="$SOURCE_DIR/GPSLabSearchLayoutCore.h"
[[ -f "$SEARCH" ]] || fail "GPSLabSearchResultsViewController.m missing"
grep -q -F "MKLocalSearch" "$SEARCH" || fail "search must use MKLocalSearch"
grep -q -F "activeSearch" "$SEARCH" || fail "search must track an active MKLocalSearch"
grep -q -F "cancelActiveSearch" "$SEARCH" || fail "search must cancel the previous request"
grep -q -F "searchGeneration" "$SEARCH" || fail "search must guard against stale responses"
grep -q -F "updateSearchResultsForQuery" "$SEARCH" \
    || fail "results controller must be driven directly with the live query"
grep -q -F "cancelActiveSearch" "$OVERLAY" || fail "overlay must cancel the active search on end"
pass "active search is cancelled on new/short/end/dealloc and stale results are ignored"

# The search bar is a standalone GPSLab view; the results controller is a
# GPSLab-owned child. A UISearchController would reparent the bar into its own
# presentation container and clip the fixed field (the v3 regression).
echo "== Standalone search bar + child results =="
if grep -q -F "UISearchController" "$OVERLAY"; then
    fail "overlay must not use UISearchController (it reparents the fixed search bar)"
fi
if grep -q -F "didDismissSearchController" "$OVERLAY"; then
    fail "overlay must not depend on UISearchController dismissal"
fi
grep -q -F "[[UISearchBar alloc] initWithFrame:" "$OVERLAY" \
    || fail "overlay must own a standalone UISearchBar"
grep -q -F "addChildViewController" "$OVERLAY" \
    || fail "overlay must mount the results controller as a GPSLab child"
grep -q -F "didMoveToParentViewController" "$OVERLAY" \
    || fail "overlay must complete child containment"
grep -q -F "insertSubview" "$OVERLAY" \
    || fail "results child must be inserted below the fixed search container"
grep -q -F 'GPSLabSearchSessionEnd(&_searchSession)' "$OVERLAY" \
    || fail "overlay must end the pure C search session"
grep -q -F "isDescendantOfView:results.view" "$OVERLAY" \
    || fail "outside-tap must exclude the child results descendants"

# Constraint architecture: a FIXED bar height (from the pure C helper) plus an
# explicit results-height equality. The keyboard is only a NON-required upper
# bound; an equality to the keyboard guide would let the solver stretch the
# low-hugging bar/container into a giant blank panel.
grep -q -F "GPSLabSearchBarHeight(" "$OVERLAY" \
    || fail "bar height must come from the pure C GPSLabSearchBarHeight helper"
grep -q -F "bar.heightAnchor constraintEqualToConstant:barHeight" "$OVERLAY" \
    || fail "bar height must be a fixed required equality (not an inequality)"
grep -q -F "resultHeightConstraint = height" "$OVERLAY" \
    || fail "results height must be an explicit equality constraint"
grep -q -F "[resultsView.heightAnchor constraintEqualToConstant:0.0]" "$OVERLAY" \
    || fail "results height equality must be explicit and default to zero"
grep -q -F "constraintLessThanOrEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor" "$OVERLAY" \
    || fail "results bottom must be a less-than-or-equal bound to the keyboard guide"
if grep -q -F "constraintEqualToAnchor:self.view.keyboardLayoutGuide" "$OVERLAY"; then
    fail "results bottom must never EQUAL the keyboard guide (it stretches the bar/container)"
fi
if grep -q -F "resultsMaxHeightConstraint" "$OVERLAY"; then
    fail "the max-height inequality must be replaced by the explicit height equality"
fi
pass "fixed bar height + explicit results-height equality; keyboard is an optional upper bound"

# The pure C search layout/phase core must be compiled and covered by the
# portable test (the same rules the overlay obeys at runtime).
[[ -f "$SEARCH_CORE_H" ]] || fail "GPSLabSearchLayoutCore.h missing"
[[ -f "$SEARCH_CORE" ]] || fail "GPSLabSearchLayoutCore.c missing"
grep -q -F "Source/GPSLabSearchLayoutCore.c" "$MAKEFILE" \
    || fail "search layout core must be compiled by the Makefile"
grep -q -F '#import "GPSLabSearchLayoutCore.h"' "$OVERLAY" \
    || fail "overlay must import the search layout core declaration"
[[ -f "$ROOT/tests/gpslab_search_layout_test.c" ]] \
    || fail "search layout test missing: tests/gpslab_search_layout_test.c"
pass "search layout/phase core compiled and tested"

# ------------------------------------------------------------- Gesture ---------
echo "== Gesture contract =="
GESTURE="$SOURCE_DIR/GPSLabGestureActivator.m"
GESTURE_H="$SOURCE_DIR/GPSLabGestureActivator.h"
[[ -f "$GESTURE" ]] || fail "GPSLabGestureActivator.m missing"
[[ -f "$GESTURE_H" ]] || fail "GPSLabGestureActivator.h missing"
grep -q -F "kGPSLabActivationRequiredTouches" "$GESTURE_H" || fail "gesture touch constant not declared"
grep -q -F "kGPSLabActivationPressDuration = 0.9" "$GESTURE" || fail "press duration must be 0.9s"
grep -q -F "kGPSLabActivationMovementTolerance = 10.0" "$GESTURE" || fail "movement tolerance must be 10pt"
grep -q -F "kGPSLabActivationCooldown = 1.0" "$GESTURE" || fail "cooldown must be ~1s"
grep -q -F "kGPSLabActivationRequiredTouches = 3" "$GESTURE" || fail "gesture must require exactly 3 fingers"
grep -q -F "numberOfTouchesRequired = kGPSLabActivationRequiredTouches" "$GESTURE" \
    || fail "gesture must use the named touch count"
grep -q -F "minimumPressDuration = kGPSLabActivationPressDuration" "$GESTURE" \
    || fail "gesture must use the named press duration"
grep -q -F "allowableMovement = kGPSLabActivationMovementTolerance" "$GESTURE" \
    || fail "gesture must use the named movement tolerance"
grep -q -F "cancelsTouchesInView = NO" "$GESTURE" || fail "gesture must not cancel host touches"
grep -q -F "kGPSLabActivationCooldown" "$GESTURE" || fail "gesture cooldown missing"
pass "gesture requires 3 fingers / 0.9s / movement cancel / cooldown / no host interference"

# --------------------------------------------------------- Persistence ---------
echo "== Persistence allow-list =="
STORE="$SOURCE_DIR/GPSLabStore.m"
grep -q -F "clearPersistedCoordinate" "$STORE" || fail "store must expose coordinate clearing"
grep -q -F "removeObjectForKey:kGPSLabKeyLatitude" "$STORE" \
    || fail "coordinate clearing must erase the persisted latitude key"
grep -q -F "removeObjectForKey:kGPSLabKeyLongitude" "$STORE" \
    || fail "coordinate clearing must erase the persisted longitude key"
grep -q -F "removeObjectForKey:kGPSLabKeyAltitude" "$STORE" \
    || fail "coordinate clearing must erase the persisted altitude key"
grep -q -F "removeObjectForKey:kGPSLabKeyHeading" "$STORE" \
    || fail "coordinate clearing must erase the persisted heading key"
grep -q -F "clearPersistedCoordinate" "$SOURCE_DIR/GPSLabEngine.m" \
    || fail "engine must clear persisted coordinates when keep-last turns off"
grep -q -F "keepLastCoordinate" "$SOURCE_DIR/GPSLabConfiguration.m" \
    || fail "configuration must honor keepLastCoordinate"
# The coordinate block is only persisted while keep-last is on.
grep -q -F "if (self.keepLastCoordinate) {" "$SOURCE_DIR/GPSLabConfiguration.m" \
    || fail "configuration must gate coordinate persistence on keepLastCoordinate"
if grep -r -n -E '@"(latitude|longitude)"' "$SOURCE_DIR/GPSLabOverlayPresenter.m" >/dev/null 2>&1; then
    fail "presenter must not persist coordinates"
fi
pass "keep-last gating and coordinate clearing present"

# ------------------------------------ Pending selection draft + favorite policy --
echo "== Pending selection draft + favorite policy =="
SELECTION_CORE="$SOURCE_DIR/GPSLabSelectionPolicyCore.c"
SELECTION_CORE_H="$SOURCE_DIR/GPSLabSelectionPolicyCore.h"
[[ -f "$SELECTION_CORE" ]] || fail "GPSLabSelectionPolicyCore.c missing"
[[ -f "$SELECTION_CORE_H" ]] || fail "GPSLabSelectionPolicyCore.h missing"
grep -q -F "Source/GPSLabSelectionPolicyCore.c" "$MAKEFILE" \
    || fail "selection policy core must be compiled by the Makefile"
# The runtime wiring reuses the shared policy core (behaviour is proven by the
# portable C test; these guards only pin the production wiring, not the rules).
grep -q -F '#import "GPSLabSelectionPolicyCore.h"' "$SOURCE_DIR/GPSLabStore.m" \
    || fail "store must reuse the selection policy core"
grep -q -F "GPSLabFavoriteSelectionAllowed" "$SOURCE_DIR/GPSLabStore.m" \
    || fail "store must gate favorite creation through the shared policy"
grep -q -F "GPSLabSelectionDistanceMeters" "$SOURCE_DIR/GPSLabStore.m" \
    || fail "store must use the shared geodesic duplicate tolerance"
grep -q -F "GPSLabProfileAltitudeValid" "$SOURCE_DIR/GPSLabStore.m" \
    || fail "store must reject an invalid bookmark altitude before serializing"
grep -q -F 'kGPSLabKeyPendingSelection GPSLAB_PROTECTED_STRING(PendingSelectionKey)' "$SOURCE_DIR/GPSLabStore.m" \
    || fail "pending draft key must use the protected PendingSelectionKey literal"
grep -q -F 'GPSLAB_STRING(PendingSelectionKey, "GPSLab.pendingSelection")' "$SOURCE_DIR/GPSLabProtectedStrings.def" \
    || fail "pending draft key must be exactly GPSLab.pendingSelection in the manifest"
grep -q -F "initWithUserDefaults:" "$SOURCE_DIR/GPSLabStore.m" \
    || fail "store must expose an isolated defaults initializer seam"
grep -q -F "savePendingSelection:" "$SOURCE_DIR/GPSLabOverlayViewController.m" \
    || fail "overlay must persist the pending draft"
grep -q -F "loadPendingSelection" "$SOURCE_DIR/GPSLabOverlayViewController.m" \
    || fail "overlay must restore the pending draft"
grep -q -F "clearPendingSelection" "$SOURCE_DIR/GPSLabOverlayViewController.m" \
    || fail "overlay must clear the pending draft on commit/cancel"
if grep -q -F "clearPersistedCoordinate" "$SOURCE_DIR/GPSLabOverlayViewController.m"; then
    fail "the overlay must never erase the keep-last configuration to clear a draft"
fi
grep -q -F "recordCommittedSelection:" "$SOURCE_DIR/GPSLabOverlayViewController.m" \
    || fail "overlay must record a committed-selection receipt"
grep -q -F "addBookmarkIfNotDuplicate:" "$SOURCE_DIR/GPSLabOverlayViewController.m" \
    || fail "overlay must use the duplicate-aware bookmark insert"
grep -q -F "presentFavoriteMessageKey" "$SOURCE_DIR/GPSLabOverlayViewController.m" \
    || fail "duplicate/origin messages must be visible native alerts (the status log has no UI)"
grep -q -F "__weak UIAlertController" "$SOURCE_DIR/GPSLabOverlayViewController.m" \
    || fail "favorite alerts must use a weak alert ref to avoid a retain cycle"
for key in favorites.manage favorites.added favorites.duplicate favorites.originRequired \
    favorites.delete.title; do
    grep -q -F "\"$key\"" "$SOURCE_DIR/GPSLabLocalizationCore.c" \
        || fail "missing localized key: $key"
done
for testfile in tests/gpslab_selection_policy_test.c tests/gpslab_selection_wiring_test.c \
    tests/GPSLabStoreTests.m; do
    [[ -f "$ROOT/$testfile" ]] || fail "test missing: $testfile"
done
pass "pending draft persists separately; favorite policy is shared, visible and duplicate-aware"

# ------------------------------------------------------------ Drift policy ----
echo "== Bounded drift policy =="
TYPES_M="$SOURCE_DIR/GPSLabTypes.m"
DRIFT_M="$SOURCE_DIR/GPSLabDriftModel.m"
ENGINE_M="$SOURCE_DIR/GPSLabEngine.m"
CONFIG_M="$SOURCE_DIR/GPSLabConfiguration.m"
PROFILE_M="$SOURCE_DIR/GPSLabProfile.m"
FORM_M="$SOURCE_DIR/GPSLabProfileFormViewController.m"
[[ -f "$DRIFT_M" ]] || fail "GPSLabDriftModel.m missing"

grep -q -F "double GPSLabMaxDriftRadiusMeters(void) {" "$TYPES_M" \
    || fail "drift maximum accessor missing"
grep -A2 -F "double GPSLabMaxDriftRadiusMeters(void) {" "$TYPES_M" | grep -q -F "return 20.0;" \
    || fail "drift maximum must be 20 m"
grep -q -F "double GPSLabDefaultDriftRadiusMeters(void) {" "$TYPES_M" \
    || fail "drift default accessor missing"
grep -A2 -F "double GPSLabDefaultDriftRadiusMeters(void) {" "$TYPES_M" | grep -q -F "return 5.0;" \
    || fail "drift default must be 5 m"

# Every clamp site must share the single policy helper.
for unit in "$CONFIG_M" "$ENGINE_M" "$DRIFT_M"; do
    grep -q -F "GPSLabClampDriftRadiusMeters" "$unit" \
        || fail "drift radius must clamp through the shared policy helper"
done

# The old 1..500 m clamp must be gone everywhere.
if grep -r -n -F "driftRadiusMeters, 1.0, 500.0" "$SOURCE_DIR" >/dev/null 2>&1; then
    fail "legacy configuration drift clamp 1..500 still present"
fi
if grep -r -n -F "radius, 1.0, 500.0" "$SOURCE_DIR" >/dev/null 2>&1; then
    fail "legacy engine/model drift clamp 1..500 still present"
fi
if grep -r -n -F "radius >= 1.0 && radius <= 500.0" "$SOURCE_DIR" >/dev/null 2>&1; then
    fail "legacy profile/form drift clamp 1..500 still present"
fi

# The walk must be deterministic/injectable and the engine must expose the seam.
grep -q -F "initWithRandomUnitProvider" "$DRIFT_M" \
    || fail "drift model must accept an injectable RNG"
grep -q -F "setDriftRandomUnitProvider" "$ENGINE_M" \
    || fail "engine must expose a deterministic drift RNG seam"

# Backward compatibility: a profile without a drift radius key must default, not reject.
grep -q -F 'dictionary[kGPSLabProfileKeyDriftRadius] != nil' "$PROFILE_M" \
    || fail "profile parser must default the drift radius when the key is absent"
grep -q -F "GPSLabClampDriftRadiusMeters" "$FORM_M" \
    || fail "profile form must validate the drift radius through the shared policy"
# A historically-valid radius must migrate by clamping, never drop the profile.
grep -q -F "GPSLabDriftRadiusHistoricallyLoadable" "$PROFILE_M" \
    || fail "profile parser must load historically-valid drift radii"
grep -q -F "driftRadius = GPSLabClampDriftRadiusMeters(driftRadius);" "$PROFILE_M" \
    || fail "profile parser must clamp migrated drift radii into the current policy"
# Changing the radius through applyConfiguration must reset the walk (no jump).
grep -q -F "radiusChanged" "$ENGINE_M" \
    || fail "engine must reset the drift walk when the configured radius changes"

[[ -f "$ROOT/tests/GPSLabDriftTests.m" ]] \
    || fail "drift tests missing: tests/GPSLabDriftTests.m"
pass "drift range/default/clamp/RNG/back-compat invariants present"

# ------------------------------------------------------ Dead code / coverage --
echo "== Dead code and Makefile coverage =="
if grep -r -n -F "GPSLabPassthroughView" "$SOURCE_DIR" >/dev/null 2>&1; then
    fail "GPSLabPassthroughView must not be referenced"
fi
# No Makefile entry may point at a missing source file.
while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    [[ -f "$ROOT/$entry" ]] || fail "Makefile lists a missing source file: $entry"
done < <(grep -oE 'Source/[A-Za-z0-9_]+\.m' "$MAKEFILE")
pass "no dead passthrough view; every Makefile source exists"

# ------------------------------------------------------------- Licenses --------
echo "== License / entitlement invariants =="
for file in GPSLabLicensePolicy.h GPSLabLicenseConfig.m GPSLabSecureStore.m \
    GPSLabTokenVerifier.m GPSLabEntitlement.m GPSLabLicenseManager.m \
    GPSLabSubscriptionViewController.m; do
    [[ -f "$SOURCE_DIR/$file" ]] || fail "license source missing: Source/$file"
done
pass "required license classes are present"

POLICY="$SOURCE_DIR/GPSLabLicensePolicy.h"
for state in Unknown Checking Active Grace Expired Invalid Offline; do
    grep -q -F "GPSLabEntitlementState$state" "$POLICY" || fail "policy state missing: $state"
done
pass "entitlement states are exact and complete"

# Token/entitlement material must live in the Keychain, never in NSUserDefaults.
if grep -r -n -F "NSUserDefaults" "$SOURCE_DIR/GPSLabSecureStore.m" \
        "$SOURCE_DIR/GPSLabTokenVerifier.m" "$SOURCE_DIR/GPSLabLicenseManager.m" \
        "$SOURCE_DIR/GPSLabEntitlement.m" "$SOURCE_DIR/GPSLabLicenseConfig.m" >/dev/null 2>&1; then
    fail "license material must use the Keychain, never NSUserDefaults"
fi
grep -q -F "SecItemAdd" "$SOURCE_DIR/GPSLabSecureStore.m" || fail "secure store must write the Keychain"
grep -q -F "SecItemCopyMatching" "$SOURCE_DIR/GPSLabSecureStore.m" || fail "secure store must read the Keychain"
pass "license material is Keychain-only"

# No embedded signing secret or backdoor.
if grep -r -n -i -E 'BEGIN ([A-Z ]*)?PRIVATE KEY|PRIVATE_KEY|allowAll|bypassLicense|debugUnlock|masterKey' \
        "$SOURCE_DIR" >/dev/null 2>&1; then
    fail "no embedded signing secret or license backdoor is allowed"
fi
pass "no embedded signing secret or backdoor"

grep -q -F "SecKeyVerifySignature" "$SOURCE_DIR/GPSLabTokenVerifier.m" \
    || fail "token verifier must verify a signature"
grep -q -F "kSecKeyAlgorithmECDSASignatureMessageX962SHA256" "$SOURCE_DIR/GPSLabTokenVerifier.m" \
    || fail "token verifier must use ECDSA P-256 SHA-256"
pass "signed-token verification present"

grep -q -F "endpoint != nil && self.publicKey.length > 0" "$SOURCE_DIR/GPSLabLicenseConfig.m" \
    || fail "config must fail closed when endpoint/key are missing"
grep -q -F "_configuration.enabled && _entitlementAllowsSynthesis" "$SOURCE_DIR/GPSLabEngine.m" \
    || fail "engine enabled state must be gated by the entitlement"
grep -q -F "setEntitlementAllowsSynthesis" "$SOURCE_DIR/GPSLabLicenseManager.m" \
    || fail "license manager must apply the engine gate"
pass "engine is fail-closed behind the entitlement gate"

MANAGER="$SOURCE_DIR/GPSLabLicenseManager.m"
VERIFIER="$SOURCE_DIR/GPSLabTokenVerifier.m"
grep -q -F 'dispatch_queue_create("com.gpslab.runtime.license"' "$MANAGER" \
    || fail "license work must run on a dedicated serial queue"
grep -q -F "NSAssert([NSThread isMainThread]" "$MANAGER" \
    || fail "license state must be applied on the main thread only"
grep -q -F "willPerformHTTPRedirection" "$MANAGER" || fail "redirects must be rejected explicitly"
grep -q -F "completionHandler(nil)" "$MANAGER" || fail "redirects must not be followed"
grep -q -F "didReceiveData" "$MANAGER" || fail "responses must be length-bounded while streaming"
grep -q -F "envelopeData.length > envelopeCap" "$VERIFIER" \
    || fail "envelope size must be checked before parsing"
if grep -q -F "dataTaskWithRequest:request completionHandler:" "$MANAGER" >/dev/null 2>&1; then
    fail "unbounded completion-handler buffering is not allowed"
fi
[[ -f "$SOURCE_DIR/GPSLabLicenseBuildConfig.h" ]] || fail "independent build config header missing"
pass "license hardening invariants present"

if grep -r -n -E 'GPSLabDiagSpoofActive|GPSLabDiagGeneratedLocation|GPSLabDiagManagerRegistered|GPSLabDiagManagerUnregistered' \
        "$SOURCE_DIR" >/dev/null 2>&1; then
    fail "diagnostics must only use the strict allow-listed events"
fi
pass "diagnostics use only the strict allow-listed events"

for testfile in tests/license_policy_test.c tests/GPSLabLicenseTests.m; do
    [[ -f "$ROOT/$testfile" ]] || fail "test missing: $testfile"
done
pass "license tests are present"

# -------------------------------------------------------------- Localization ---
echo "== Localization invariants =="
LOC_CORE="$SOURCE_DIR/GPSLabLocalizationCore.c"
LOC_WRAPPER="$SOURCE_DIR/GPSLabLocalization.m"
[[ -f "$LOC_CORE" ]] || fail "GPSLabLocalizationCore.c missing"
[[ -f "$LOC_WRAPPER" ]] || fail "GPSLabLocalization.m missing"
grep -q -F "Source/GPSLabLocalizationCore.c" "$MAKEFILE" \
    || fail "localization core must be compiled by the Makefile"
grep -q -F "Source/GPSLabLocalization.m" "$MAKEFILE" \
    || fail "localization wrapper must be compiled by the Makefile"
grep -q -F "Source/GPSLabModalCoordinator.m" "$MAKEFILE" \
    || fail "modal coordinator must be compiled by the Makefile"

# Arabic must be the default: a missing/invalid value resolves to Arabic and
# English is only returned for an explicit "en" prefix.
grep -q -F 'return GPSLabLanguageArabic;' "$LOC_CORE" \
    || fail "localization core must default to Arabic"
grep -q -F 'GPSLabLanguageArabic = 0' "$SOURCE_DIR/GPSLabLocalizationCore.h" \
    || fail "Arabic must be the zero/default language constant"
# The catalog must be embedded in the dylib, not loaded from host bundle
# resources. (LicenseConfig legitimately reads the host Info.plist, so the
# ban below is limited to localized-string/bundle-table lookups.)
if grep -r -n -E 'NSLocalizedString|\.lproj' "$SOURCE_DIR" --include='*.m' >/dev/null 2>&1; then
    fail "localization must use the embedded catalog, not host bundle/strings resources"
fi
if grep -n -F "NSBundle" "$LOC_WRAPPER" >/dev/null 2>&1; then
    fail "localization wrapper must not depend on the host main bundle"
fi
# Never mutate the process-wide language list or global appearance.
if grep -r -n -E 'AppleLanguages|UIAppearance' "$SOURCE_DIR" >/dev/null 2>&1; then
    grep -r -n -E 'AppleLanguages|UIAppearance' "$SOURCE_DIR" >&2 || true
    fail "global language/appearance mutation is not allowed"
fi
pass "embedded catalog, Arabic default, no global language/appearance mutation"

# Scoped key-window lease + serialized presentation hooks must be present.
PRESENTER="$SOURCE_DIR/GPSLabOverlayPresenter.m"
COORDINATOR="$SOURCE_DIR/GPSLabModalCoordinator.m"
[[ -f "$COORDINATOR" ]] || fail "GPSLabModalCoordinator.m missing"
grep -q -F "makeKeyWindow" "$PRESENTER" || fail "presenter must make the overlay window key on demand"
grep -q -F "releaseKeyLease" "$PRESENTER" || fail "presenter must release the scoped key lease"
grep -q -F "UIWindowLevelNormal" "$PRESENTER" \
    || fail "key-lease restore must be limited to a normal-level host window"
grep -q -F "resolvePendingPresentation" "$COORDINATOR" \
    || fail "coordinator must resolve a presentation deferred by search"
grep -q -F "resolvePendingPresentation" "$SOURCE_DIR/GPSLabOverlayViewController.m" \
    || fail "canvas must resume a deferred presentation from didDismissSearchController"
grep -q -F "acquireKeyLease" "$SOURCE_DIR/GPSLabOverlayViewController.m" \
    || fail "canvas must acquire the key lease before search editing"
if grep -r -n -F "canBecomeFirstResponder" "$SOURCE_DIR" >/dev/null 2>&1; then
    fail "no canBecomeFirstResponder window/responder hack is allowed"
fi
pass "scoped key lease and serialized presentation hooks present"

# Modal decision policy: must be a shared helper that the coordinator actually
# obeys, compiled by the Makefile and covered by the portable test.
POLICY_C="$SOURCE_DIR/GPSLabModalPolicy.c"
[[ -f "$POLICY_C" ]] || fail "GPSLabModalPolicy.c missing"
grep -q -F "Source/GPSLabModalPolicy.c" "$MAKEFILE" \
    || fail "modal policy must be compiled by the Makefile"
grep -q -F "GPSLabModalPolicyDecidePresentation" "$COORDINATOR" \
    || fail "coordinator must obey the shared modal policy"
grep -q -F "GPSLabModalSessionIsCurrent" "$COORDINATOR" \
    || fail "coordinator must gate queued work by session generation"
grep -q -F "dismissViewControllerAnimated" "$COORDINATOR" \
    || fail "coordinator must dismiss through UIKit transitions"
if grep -q -F "dismissAllAnimated:animated completion:completion" "$COORDINATOR"; then
    fail "dismissAll must not recurse through itself"
fi
# Tracked transitions must park for the owner completion; untracked ones must
# drain only from a captured coordinator callback (never a nil-coordinator retry).
grep -q -F "GPSLabModalDecisionParkForTrackedTransition" "$COORDINATOR" \
    || fail "tracked transitions must park for the owner completion"
grep -q -F "registerUntrackedTransitionDrain" "$COORDINATOR" \
    || fail "untracked transitions must drain from the coordinator callback"
grep -q -F "drainPendingPresentationIfCurrent" "$COORDINATOR" \
    || fail "coordinator must use a guarded, generation-checked drain"
if grep -q -E "waitForUntrackedTransitionOnAnchor|runPendingPresentationIfCurrent" "$COORDINATOR"; then
    fail "the recursive nil-coordinator retry path must stay removed"
fi
pass "modal policy helper compiled, obeyed and tested"

for testfile in tests/gpslab_localization_test.c tests/GPSLabLocalizationTests.m \
                 tests/gpslab_modal_policy_test.c; do
    [[ -f "$ROOT/$testfile" ]] || fail "localization/policy test missing: $testfile"
done
pass "localization and modal policy tests are present"

# --------------------------------- Overlay drift draft / keyboard / map style --
echo "== Overlay drift draft, keyboard and map-style preference =="
OVERLAY="$SOURCE_DIR/GPSLabOverlayViewController.m"
SHEET="$SOURCE_DIR/GPSLabSheetViewController.m"
STORE="$SOURCE_DIR/GPSLabStore.m"
MAP_TEST="$ROOT/tests/gpslab_overlay_ui_wiring_test.c"
[[ -f "$MAP_TEST" ]] || fail "overlay UI wiring test missing: tests/gpslab_overlay_ui_wiring_test.c"
grep -q -F "gpslab_overlay_ui_wiring_test.c" "$ROOT/.github/workflows/tests.yml" \
    || fail "the overlay UI wiring test must be run by the tests workflow"

# Drift is an overlay-owned draft: the switch and the sheet edit only the draft,
# and Apply commits both values while Cancel discards them.
grep -q -F "pendingDriftEnabled" "$OVERLAY" || fail "overlay must own pendingDriftEnabled"
grep -q -F "pendingDriftRadius" "$OVERLAY" || fail "overlay must own pendingDriftRadius"
grep -q -F "self.pendingDriftEnabled = configuration.driftEnabled" "$OVERLAY" \
    || fail "the drift draft must be seeded from the committed configuration"
grep -q -F "self.pendingDriftRadius = configuration.driftRadiusMeters" "$OVERLAY" \
    || fail "the drift radius draft must be seeded from the committed configuration"
if sed -n '/- (void)driftChanged {/,/^}/p' "$OVERLAY" | grep -q -F "setDriftEnabled"; then
    fail "the drift switch must never toggle the engine on edit"
fi
if sed -n '/- (void)presentFluctuationSheet {/,/^}/p' "$OVERLAY" | grep -q -F "setDriftEnabled"; then
    fail "the fluctuation sheet must only edit the draft"
fi
if sed -n '/- (void)presentFluctuationSheet {/,/^}/p' "$OVERLAY" | grep -q -F "sharedEngine"; then
    fail "the fluctuation sheet must never reach the engine"
fi
grep -q -F "sheet.fluctuationEnabled = self.pendingDriftEnabled" "$OVERLAY" \
    || fail "the fluctuation sheet must be initialized from the draft"
grep -q -F "sheet.radiusMeters = self.pendingDriftRadius" "$OVERLAY" \
    || fail "the fluctuation sheet must be initialized from the draft radius"
if grep -q -F "commitPendingDriftIfNeeded" "$OVERLAY"; then
    fail "the direct drift commit helper must be eliminated"
fi
grep -q -F "driftRangeRowView" "$OVERLAY" \
    || fail "the compact drift range row is missing"
grep -q -F "panel.drift.range" "$OVERLAY" \
    || fail "the drift range row must use the panel.drift.range label key"
grep -q -F '"panel.drift.range", "مدى التذبذب", "Drift range"' "$SOURCE_DIR/GPSLabLocalizationCore.c" \
    || fail "the exact drift-range catalog label (مدى التذبذب / Drift range) is missing"
grep -q -F "driftRangeChevronLabel" "$OVERLAY" \
    || fail "the drift range row must render a visible chevron"
grep -q -F "driftRangeTapped" "$OVERLAY" \
    || fail "the drift range row must open the fluctuation sheet"
# Static/route Apply bundle drift into the SAME validated configuration; a failed
# Apply never writes drift and no direct engine drift setter is used.
grep -q -F "configuration.driftEnabled = self.pendingDriftEnabled" "$OVERLAY" \
    || fail "Apply must bundle the drift enabled flag into the configuration"
grep -q -F "configuration.driftRadiusMeters = GPSLabClampDriftRadiusMeters(self.pendingDriftRadius)" "$OVERLAY" \
    || fail "Apply must bundle the clamped drift radius into the configuration"
for body in \
    '/- (BOOL)applyCoordinate:(CLLocationCoordinate2D)coordinate altitude:(double)altitude heading:(double)heading {/,/^}/p' \
    '/- (void)startRouteFromPending {/,/^}/p'; do
    if sed -n "$body" "$OVERLAY" | grep -q -F "setDriftEnabled"; then
        fail "Apply paths must never use a direct drift setter ($body)"
    fi
done
grep -q -F "syncDriftDraftFromCommittedConfiguration" "$OVERLAY" \
    || fail "a successful Apply must resync the draft from the committed configuration"
if [[ "$(grep -c -F -- '- (void)applyMapStyle:(NSInteger)style {' "$OVERLAY")" != "1" ]]; then
    fail "there must be exactly one applyMapStyle entry point"
fi
pass "overlay owns the drift draft; edits never toggle the engine; Apply bundles drift after validation; Cancel discards"

# Keyboard: centralized localized Done accessory + safe background tap + scoped
# end editing, with the existing keyboard guide/interactive scroll preserved.
grep -q -F "keyboardLayoutGuide" "$SHEET" || fail "the sheet keyboard layout guide must be preserved"
grep -q -F "UIScrollViewKeyboardDismissModeInteractive" "$SHEET" \
    || fail "the sheet interactive keyboard dismissal must be preserved"
grep -q -F "gpslab_decimalAccessoryView" "$SHEET" \
    || fail "a centralized decimal-keyboard accessory is required"
grep -q -F '"common.done"' "$SHEET" || fail "the decimal Done accessory must be localized"
grep -q -F "cancelsTouchesInView = NO" "$SHEET" \
    || fail "the sheet background tap must not block controls"
grep -q -F "shouldReceiveTouch" "$SHEET" \
    || fail "the sheet background tap must scope its touches"
grep -q -F "isBeingDismissed" "$SHEET" \
    || fail "sheet end editing must be scoped to a real dismissal"
grep -q -F "viewWillDisappear:(BOOL)animated {" "$SHEET" \
    || fail "the base sheet must end editing on dismiss"
for unit in GPSLabManualEntryViewController.m GPSLabProfileFormViewController.m \
    GPSLabSubscriptionViewController.m GPSLabAltitudeViewController.m; do
    grep -q -F "endEditing:YES" "$SOURCE_DIR/$unit" || fail "$unit must end editing on Apply/Cancel"
done
if ! sed -n '/- (void)activateTapped {/,/^}/p' "$SOURCE_DIR/GPSLabSubscriptionViewController.m" \
        | grep -q -F "endEditing:YES"; then
    fail "activation must end editing first"
fi
pass "localized Done accessory, safe background tap and scoped form end editing present"

# Map style: persisted UI preference (missing/invalid => Satellite), no schema
# change, and snapshots that match the selected style.
grep -q -F 'kGPSLabKeyMapStyle GPSLAB_PROTECTED_STRING(MapStyleKey)' "$STORE" \
    || fail "the store must persist the exact GPSLab.mapStyle key via the protected literal"
grep -q -F 'GPSLAB_STRING(MapStyleKey, "GPSLab.mapStyle")' "$SOURCE_DIR/GPSLabProtectedStrings.def" \
    || fail "the map-style key must be exactly GPSLab.mapStyle in the manifest"
grep -q -F -- "- (GPSLabMapStyle)loadMapStyle;" "$SOURCE_DIR/GPSLabStore.h" \
    || fail "the store must expose loadMapStyle"
grep -q -F -- "- (void)saveMapStyle:(GPSLabMapStyle)style;" "$SOURCE_DIR/GPSLabStore.h" \
    || fail "the store must expose saveMapStyle"
grep -q -F "return GPSLabMapStyleSatellite;" "$STORE" \
    || fail "a missing/invalid map style must resolve to Satellite"
for style in "GPSLabMapStyleStandard = 0" "GPSLabMapStyleHybrid" "GPSLabMapStyleSatellite"; do
    grep -q -F "$style" "$SOURCE_DIR/GPSLabTypes.h" \
        || fail "the shared map-style enum is missing: $style"
done
grep -q -F "loadMapStyle" "$OVERLAY" || fail "the foreground must load the persisted style"
grep -q -F "mapTypeForStyle" "$OVERLAY" || fail "the snapshot must match the selected style"
if grep -q -F "options.mapType = MKMapTypeStandard" "$OVERLAY"; then
    fail "the snapshot must never be hardcoded to the standard style"
fi
if grep -q -F 'kGPSLabKeyMapStyle' "$SOURCE_DIR/GPSLabConfiguration.m" \
        || grep -q -F "mapStyle" "$SOURCE_DIR/GPSLabProfile.m"; then
    fail "the map style must never enter the configuration/profile schema"
fi
pass "map style is a persisted UI preference with matching snapshots and no schema change"

# ------------------------------------------- Protected client literals --------
echo "== Production-only protected client literals =="
PROTECTED_MANIFEST="$SOURCE_DIR/GPSLabProtectedStrings.def"
PROTECTED_HEADER="$SOURCE_DIR/GPSLabProtectedStringsGenerated.h"
PROTECTED_H="$SOURCE_DIR/GPSLabProtectedString.h"
PROTECTED_M="$SOURCE_DIR/GPSLabProtectedString.m"
PROTECTED_CORE_C="$SOURCE_DIR/GPSLabProtectedStringCore.c"
PROTECTED_CORE_H="$SOURCE_DIR/GPSLabProtectedStringCore.h"
for file in "$PROTECTED_MANIFEST" "$PROTECTED_HEADER" "$PROTECTED_H" "$PROTECTED_M" \
    "$PROTECTED_CORE_C" "$PROTECTED_CORE_H"; do
    [[ -f "$file" ]] || fail "protected-string file missing: $(basename "$file")"
done
grep -q -F "Source/GPSLabProtectedString.m" "$MAKEFILE" \
    || fail "protected-string wrapper must be compiled by the Makefile"
grep -q -F "Source/GPSLabProtectedStringCore.c" "$MAKEFILE" \
    || fail "protected-string core must be compiled by the Makefile"
# The decode branch must be selected by the audited production mode, not invented
# in the source tree.
grep -q -- '-DGPSLAB_PRODUCTION=1' "$ROOT/scripts/build_mode.mk" \
    || fail "the production mode must select the protected-string decode branch"
if grep -q -- '-DGPSLAB_PRODUCTION=1' "$MAKEFILE"; then
    fail "the protected-string switch must come from scripts/build_mode.mk only"
fi
grep -q -F 'GPSLAB_PROTECTED_STRING(DefaultsSuite)' "$SOURCE_DIR/GPSLabStore.m" \
    || fail "the defaults suite must use the protected-string macro"
grep -q -F 'GPSLAB_PROTECTED_STRING(MapStyleKey)' "$SOURCE_DIR/GPSLabStore.m" \
    || fail "the persistence keys must use the protected-string macro"
# Protected strings must never carry a secret; the manifest is the source of truth.
if grep -q -i -E 'PRIVATE KEY|password[[:space:]]*=|secret[[:space:]]*=|api[_-]?key' "$PROTECTED_MANIFEST"; then
    fail "the protected-string manifest must never contain a secret"
fi
[[ -f "$ROOT/tests/gpslab_protected_strings_test.c" ]] \
    || fail "protected-string test missing: tests/gpslab_protected_strings_test.c"
grep -q -F "gpslab_protected_strings_test.c" "$ROOT/.github/workflows/tests.yml" \
    || fail "the protected-string test must be run by the tests workflow"
pass "protected client literals are manifest-driven, compiled and tested"

echo "All GPSLab static checks passed."
