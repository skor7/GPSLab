#!/usr/bin/env bash
# GPSLab build-mode audit: validate BOTH modes without an iOS toolchain.
#
# The mode -> flag mapping lives in scripts/build_mode.mk, which is self-contained
# (no Theos include). This script evaluates it with plain GNU make for each mode
# and asserts the exact flag sets, so a regression in either mode fails the static
# gate even on a host with no iOS SDK.
#
# It enforces:
#   * the DEFAULT mode is dev: a plain `make` must not produce a hardened artifact;
#   * dev is readable/debuggable: DEBUG=1, no visibility/strip/g0/NDEBUG flags;
#   * production is hardened: DEBUG=0, hidden visibility, no ident, -g0, NDEBUG
#     and link-time local + debug symbol strip;
#   * an unknown MODE is rejected (a typo must fail, not silently harden);
#   * the top-level Makefile consumes the mode mapping and no longer hardcodes a
#     DEBUG default.
#
# Usage: bash scripts/audit_build_modes.sh
# Exit code 0 = both modes are correct.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE_MK="$ROOT/scripts/build_mode.mk"
MAKEFILE="$ROOT/Makefile"
MAKE="${MAKE:-make}"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

pass() {
    echo "ok: $*"
}

[[ -f "$MODE_MK" ]] || fail "scripts/build_mode.mk not found at $MODE_MK"
[[ -f "$MAKEFILE" ]] || fail "Makefile not found at $MAKEFILE"
command -v "$MAKE" >/dev/null 2>&1 || fail "$MAKE is required for the build-mode audit"

# Evaluate scripts/build_mode.mk for a given MODE (or the default when the first
# argument is "default") and print the resolved variables as key=value lines.
eval_mode() {
    local mode="$1" tmp status
    tmp="$(mktemp "${TMPDIR:-/tmp}/gpslab-mode.XXXXXX.mk")"
    cat > "$tmp" <<'EOF'
include $(GPSLAB_MODE_MK)
dump:
	@printf 'mode=%s\n' '$(GPSLAB_MODE_SELECTED)'
	@printf 'debug=%s\n' '$(DEBUG)'
	@printf 'cflags=%s\n' '$(GPSLAB_MODE_CFLAGS)'
	@printf 'ldflags=%s\n' '$(GPSLAB_MODE_LDFLAGS)'
EOF
    if [[ "$mode" == "default" ]]; then
        ( unset MODE DEBUG; "$MAKE" -s -f "$tmp" GPSLAB_MODE_MK="$MODE_MK" dump )
        status=$?
    else
        "$MAKE" -s -f "$tmp" GPSLAB_MODE_MK="$MODE_MK" MODE="$mode" dump
        status=$?
    fi
    rm -f "$tmp"
    return "$status"
}

field() {
    # $1 = dump text, $2 = key -> value
    sed -n "s/^$2=//p" <<<"$1"
}

assert_contains() {
    # $1 = haystack, $2 = needle, $3 = message
    [[ "$1" == *"$2"* ]] || fail "$3 (expected '$2' in '$1')"
}

assert_not_contains() {
    [[ "$1" != *"$2"* ]] || fail "$3 (unexpected '$2' in '$1')"
}

# ------------------------------------------------------------- DEV mode ------
echo "== Build mode: DEV (default) =="
DEV_DUMP="$(eval_mode dev)"
[[ "$(field "$DEV_DUMP" mode)" == "dev" ]] || fail "MODE=dev must resolve to the dev mode"
[[ "$(field "$DEV_DUMP" debug)" == "1" ]] || fail "dev must set DEBUG=1 (readable/debuggable)"
DEV_CFLAGS="$(field "$DEV_DUMP" cflags)"
DEV_LDFLAGS="$(field "$DEV_DUMP" ldflags)"
assert_not_contains "$DEV_CFLAGS" "-fvisibility=hidden" "dev must not hide symbols"
assert_not_contains "$DEV_CFLAGS" "-fno-ident" "dev must keep compiler ident"
assert_not_contains "$DEV_CFLAGS" "-g0" "dev must keep debug symbols"
assert_not_contains "$DEV_CFLAGS" "-DNDEBUG" "dev must keep asserts/diagnostics"
assert_not_contains "$DEV_CFLAGS" "-DGPSLAB_PRODUCTION=1" "dev must keep protected strings readable"
[[ -z "$DEV_LDFLAGS" ]] || fail "dev must not strip at link time (got '$DEV_LDFLAGS')"
pass "dev is readable/debuggable (DEBUG=1, no hardening, no strip)"

# -------------------------------------------------------- PRODUCTION mode ----
echo "== Build mode: PRODUCTION =="
PROD_DUMP="$(eval_mode production)"
[[ "$(field "$PROD_DUMP" mode)" == "production" ]] || fail "MODE=production must resolve to the production mode"
[[ "$(field "$PROD_DUMP" debug)" == "0" ]] || fail "production must set DEBUG=0 (no Theos debug schema)"
PROD_CFLAGS="$(field "$PROD_DUMP" cflags)"
PROD_LDFLAGS="$(field "$PROD_DUMP" ldflags)"
assert_contains "$PROD_CFLAGS" "-fvisibility=hidden" "production must hide internal symbols"
assert_contains "$PROD_CFLAGS" "-fno-ident" "production must omit the compiler ident"
assert_contains "$PROD_CFLAGS" "-g0" "production must emit no debug info"
assert_contains "$PROD_CFLAGS" "-DNDEBUG" "production must compile out asserts"
assert_contains "$PROD_CFLAGS" "-DGPSLAB_PRODUCTION=1" \
    "production must select the protected-string decode branch"
assert_contains "$PROD_LDFLAGS" "-Wl,-x" "production must strip local symbols"
assert_contains "$PROD_LDFLAGS" "-Wl,-S" "production must strip debug symbols"
pass "production is hardened (DEBUG=0, hidden visibility, no debug/ident, stripped)"

# ----------------------------------------------------- Default is DEV --------
echo "== Default mode (plain make) =="
DEFAULT_DUMP="$(eval_mode default)"
[[ "$(field "$DEFAULT_DUMP" mode)" == "dev" ]] || fail "the default mode must be dev"
[[ "$(field "$DEFAULT_DUMP" debug)" == "1" ]] || fail "the default build must be debuggable (DEBUG=1)"
pass "a plain 'make' defaults to the readable dev build"

# --------------------------------------------------- Unknown mode rejected ---
echo "== Unknown mode rejection =="
if eval_mode bogus >/dev/null 2>&1; then
    fail "an unknown MODE must be rejected"
fi
pass "an unknown MODE fails the build"

# --------------------------------------------------- Top-level Makefile ------
echo "== Makefile consumes the mode mapping =="
grep -q 'scripts/build_mode.mk' "$MAKEFILE" \
    || fail "the Makefile must include scripts/build_mode.mk"
grep -q 'GPSLAB_MODE_CFLAGS' "$MAKEFILE" \
    || fail "the Makefile must consume GPSLAB_MODE_CFLAGS"
grep -q 'GPSLAB_MODE_LDFLAGS' "$MAKEFILE" \
    || fail "the Makefile must consume GPSLAB_MODE_LDFLAGS"
if grep -qE '^[[:space:]]*DEBUG[[:space:]]*=' "$MAKEFILE"; then
    fail "the Makefile must not hardcode DEBUG (the mode mapping owns it)"
fi
pass "the Makefile includes and consumes the mode mapping; no hardcoded DEBUG"

echo "Build-mode audit passed (dev + production)."
