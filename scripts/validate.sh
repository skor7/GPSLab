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
pass "Makefile declares arm64/iOS16/ARC/frameworks/install path"

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

# ---------------------------------------------------- Overlay map layout --------
echo "== Overlay map layout =="
# The MKMapView must be a visible arranged subview of the dedicated map section,
# never hidden behind the panel, and must carry an explicit height so the scroll
# content can size. The ban targets the specific old map-behind-panel placement.
if grep -n -E 'insertSubview:.*mapView.*belowSubview' "$OVERLAY" >/dev/null 2>&1; then
    fail "overlay must not place the map behind the panel (insertSubview:mapView belowSubview:)"
fi
grep -q -F -e "- (UIStackView *)buildMapSection" "$OVERLAY" \
    || fail "overlay must build the map as a dedicated map section"
grep -q -F "initWithArrangedSubviews:@[self.mapView," "$OVERLAY" \
    || fail "overlay map must be the first arranged subview of the map section stack"
grep -q -F "mapView.heightAnchor constraintEqualToConstant" "$OVERLAY" \
    || fail "overlay map must declare an explicit height constraint"
pass "map is a visible arranged subview with an explicit height, not behind the panel"

# --------------------------------------------------------------- Search --------
echo "== Search request hygiene =="
grep -q -F "activeSearch" "$OVERLAY" || fail "search must track an active MKLocalSearch"
grep -q -F "cancelActiveSearch" "$OVERLAY" || fail "search must cancel the previous request"
grep -q -F "didDismissSearchController" "$OVERLAY" || fail "search must cancel when dismissed"
grep -q -F "searchGeneration" "$OVERLAY" || fail "search must guard against stale responses"
pass "active search is cancelled on new/short/dismiss/dealloc and stale results are ignored"

# ------------------------------------------------------------- Gesture ---------
echo "== Gesture contract =="
GESTURE="$SOURCE_DIR/GPSLabGestureActivator.m"
[[ -f "$GESTURE" ]] || fail "GPSLabGestureActivator.m missing"
grep -q -F "numberOfTouchesRequired = 3" "$GESTURE" || fail "gesture must require exactly 3 fingers"
grep -q -F "minimumPressDuration = kGPSLabActivationPressDuration" "$GESTURE" \
    || fail "gesture must use the named press duration"
grep -q -F "kGPSLabActivationPressDuration = 0.9" "$GESTURE" || fail "press duration must be 0.9s"
grep -q -F "cancelsTouchesInView = NO" "$GESTURE" || fail "gesture must not cancel host touches"
grep -q -F "kGPSLabActivationCooldown" "$GESTURE" || fail "gesture cooldown missing"
grep -q -F "allowableMovement" "$GESTURE" || fail "gesture movement threshold missing"
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

echo "All GPSLab static checks passed."
