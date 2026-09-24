#!/usr/bin/env bash
# GPSLab release-protection validation.
#
# Two layers, both deterministic and offline:
#   1. static: BOTH build modes must be correct (dev readable, production
#      hardened, default dev), and the shipping sources must be free of debug
#      printing, absolute developer paths and embedded secrets/private keys.
#      The mode mapping is evaluated by scripts/audit_build_modes.sh.
#   2. binary: when a dylib path is given, the Mach-O must be arm64, carry the
#      injection install_name, target iOS 16+, contain no DWARF/STABS debug
#      info, no local symbols, no leaked build paths/source names and no banned
#      hooking references. This is the release-artifact gate: a dev build fails
#      it, so an unhardened artifact can never be shipped as a release.
#
# Usage:
#   bash scripts/release_protection.sh                 # static only
#   bash scripts/release_protection.sh path/to/GPSLab.dylib
#
# Exit code 0 = every executed check passed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAKEFILE="$ROOT/Makefile"
SOURCE_DIR="$ROOT/Source"
BINARY="${1:-}"
PYTHON="${PYTHON:-python3}"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

pass() {
    echo "ok: $*"
}

[[ -f "$MAKEFILE" ]] || fail "Makefile not found at $MAKEFILE"
[[ -d "$SOURCE_DIR" ]] || fail "Source directory not found at $SOURCE_DIR"

# An explicitly supplied binary path must exist: silently downgrading to the
# static-only path would report a green gate for a build that was never audited.
if [[ -n "$BINARY" && ! -f "$BINARY" ]]; then
    fail "binary not found at the supplied path: $BINARY"
fi

# ---------------------------------------------- Build modes (dev + production) --
echo "== Build-mode mapping (dev + production) =="
bash "$ROOT/scripts/audit_build_modes.sh" \
    || fail "the build-mode audit failed (see scripts/audit_build_modes.sh)"
pass "dev is readable; production is hardened; a plain make defaults to dev"

# ------------------------------------------------------- Source hygiene ------
echo "== Source debug/secret hygiene =="
if grep -r -n -E '\bNSLog\b|\bprintf\b|\bfprintf\b' "$SOURCE_DIR" >/dev/null 2>&1; then
    # List offending FILES only: never echo source lines, which could contain a
    # literal that must not be printed to logs.
    grep -r -l -E '\bNSLog\b|\bprintf\b|\bfprintf\b' "$SOURCE_DIR" >&2 || true
    fail "debug printing (NSLog/printf) is not allowed in shipping sources"
fi
pass "no NSLog/printf in shipping sources (Diagnostics uses os_log)"

if grep -r -n -E '(/Users/|/home/|[A-Za-z]:\\)' "$SOURCE_DIR" >/dev/null 2>&1; then
    grep -r -l -E '(/Users/|/home/|[A-Za-z]:\\)' "$SOURCE_DIR" >&2 || true
    fail "absolute developer paths are not allowed in shipping sources"
fi
pass "no absolute developer paths in shipping sources"

if grep -r -n -i -E 'BEGIN [A-Z ]*PRIVATE KEY|PRIVATE_KEY|api[_-]?key[[:space:]]*=|password[[:space:]]*=|secret[[:space:]]*=' "$SOURCE_DIR" >/dev/null 2>&1; then
    fail "an embedded secret, private key or credential literal was found"
fi
pass "no embedded secrets, private keys or credential literals"

# ---------------------------------------- Protected client literals ----------
echo "== Protected-string audit (DEV readable, PRODUCTION protected) =="
bash "$ROOT/scripts/audit_protected_strings.sh" \
    || fail "the protected-string audit failed (see scripts/audit_protected_strings.sh)"
pass "protected client literals are readable in DEV and removed from PRODUCTION"

# ------------------------------------------------------- Binary audit --------
if [[ -n "$BINARY" && -f "$BINARY" ]]; then
    echo "== Mach-O release audit =="
    command -v "$PYTHON" >/dev/null 2>&1 || fail "$PYTHON is required for the binary audit"
    OUT="$("$PYTHON" "$ROOT/scripts/audit_macho.py" "$BINARY")"
    echo "$OUT"

    grep -q '^arch: arm64$' <<<"$OUT" || fail "binary is not arm64"
    grep -q '^install_name: @executable_path/Frameworks/GPSLab.dylib$' <<<"$OUT" \
        || fail "install_name does not match the injection contract"
    grep -q '^dwarf_debug_segment: false$' <<<"$OUT" || fail "binary still contains a __DWARF debug segment"
    grep -q '^symbols_stab_source: 0$' <<<"$OUT" || fail "binary still contains source STABS debug symbols"
    grep -q '^symbols_local: 0$' <<<"$OUT" || fail "binary still contains local symbols"
    if grep -q '^leak\[' <<<"$OUT"; then
        echo "$OUT" | grep '^leak\[' >&2 || true
        fail "leaked build paths / source names / keys / hooking refs remain in the binary"
    fi

    # The artifact must not contain any protected client literal (decoded at
    # runtime in PRODUCTION). The audit prints symbol names only, never values.
    "$PYTHON" "$ROOT/scripts/audit_protected_strings.py" --binary "$BINARY" >/dev/null \
        || fail "a protected client literal is present in the binary"
    pass "no protected client literal appears in the binary"

    MIN_OS="$(grep '^min_os: ' <<<"$OUT" | cut -d' ' -f2)"
    MAJOR="${MIN_OS%%.*}"
    [[ "$MAJOR" =~ ^[0-9]+$ ]] || fail "could not parse min_os: $MIN_OS"
    (( MAJOR >= 16 )) || fail "minimum iOS is below 16.0: $MIN_OS"
    pass "binary is arm64, iOS $MIN_OS+, correctly named, stripped and leak-free"
else
    echo "note: no dylib supplied; ran static release-protection checks only"
fi

echo "Release protection checks passed."
