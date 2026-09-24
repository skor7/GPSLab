#!/usr/bin/env bash
# GPSLab production-only protected-string audit.
#
# Proves, offline and without an iOS toolchain, that the protected-string
# facility keeps DEV readable while removing the protected plaintext from the
# PRODUCTION build path:
#
#   * the committed generated header is exactly what the manifest produces
#     (scripts/gen_protected_strings.py --check);
#   * every encoded blob round-trips to its plaintext and leaks no plaintext
#     bytes; the PRODUCTION macro expansion never mentions the plaintext, while
#     the DEV expansion is the readable literal (scripts/audit_protected_strings.py);
#   * the PRODUCTION build mode actually defines -DGPSLAB_PRODUCTION=1 and the
#     DEV mode does not (so the switch is wired to the real Theos mode machinery);
#   * when a built dylib is supplied, none of the protected plaintexts appears in
#     the shipped artifact.
#
# The audit never prints a protected plaintext value, only symbol names/counts.
#
# Usage:
#   bash scripts/audit_protected_strings.sh                 # static only
#   bash scripts/audit_protected_strings.sh path/to/GPSLab.dylib
#
# Exit code 0 = every executed check passed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON="${PYTHON:-python3}"
BINARY="${1:-}"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

pass() {
    echo "ok: $*"
}

MANIFEST="$ROOT/Source/GPSLabProtectedStrings.def"
HEADER="$ROOT/Source/GPSLabProtectedStringsGenerated.h"
MODE_MK="$ROOT/scripts/build_mode.mk"

[[ -f "$MANIFEST" ]] || fail "protected-string manifest not found at $MANIFEST"
[[ -f "$HEADER" ]] || fail "generated protected-string header not found at $HEADER"
[[ -f "$MODE_MK" ]] || fail "build-mode mapping not found at $MODE_MK"
command -v "$PYTHON" >/dev/null 2>&1 || fail "$PYTHON is required for the protected-string audit"

# The generated header must be exactly reproducible from the manifest.
"$PYTHON" "$ROOT/scripts/gen_protected_strings.py" --check \
    || fail "the generated header is out of sync; run: python3 scripts/gen_protected_strings.py"
pass "generated header is in sync with the manifest"

# Round-trip, macro semantics, call-site consistency and (optional) artifact scan.
if [[ -n "$BINARY" ]]; then
    "$PYTHON" "$ROOT/scripts/audit_protected_strings.py" --binary "$BINARY" \
        || fail "the protected-string audit failed"
else
    "$PYTHON" "$ROOT/scripts/audit_protected_strings.py" \
        || fail "the protected-string audit failed"
fi

# The switch must be wired to the real build-mode machinery, not invented here.
grep -q -- '-DGPSLAB_PRODUCTION=1' "$MODE_MK" \
    || fail "the production build mode must define -DGPSLAB_PRODUCTION=1"
# The DEV branch of build_mode.mk sets GPSLAB_MODE_CFLAGS empty; guard against a
# future edit that leaks the production define into dev by inspecting the dev block.
DEV_BLOCK="$(sed -n '/DEV --------/,/^else$/p' "$MODE_MK")"
if grep -q -- '-DGPSLAB_PRODUCTION=1' <<<"$DEV_BLOCK"; then
    fail "the dev build mode must not define -DGPSLAB_PRODUCTION=1"
fi
pass "the production define is wired to the production mode only"

echo "Protected-string audit passed."
