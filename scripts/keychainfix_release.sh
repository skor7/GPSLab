#!/usr/bin/env bash
# KeychainFix protected-artifact release.
#
# WHY THIS SCRIPT EXISTS
#   The KeychainFix.dylib is produced and source-verified by the separate
#   KeychainFix-Builder repository. This host (Windows) has no Mach-O toolchain
#   (no Xcode `strip`, no `otool`/`lipo`), so the strip step cannot be performed
#   here. This script is the reproducible macOS step that consumes an EXISTING,
#   already-verified KeychainFix.dylib and emits a hardened KeychainFix-Release.dylib.
#
# GUARANTEES
#   * The input artifact is NEVER modified (a copy is stripped).
#   * KeychainFix source and the sibling KeychainFix-Builder repo are NEVER read
#     or changed: only the supplied binary is read.
#   * The strip is Mach-O-safe: `strip -x -S` removes local symbols and debug
#     symbols only. Global/undefined symbols and all load commands (install_name,
#     min OS, dependencies) are preserved, so hook behaviour is unchanged.
#   * An explicit protected-artifact gate must pass on the INPUT before any
#     output is written, and a before/after audit must show the invariants held.
#   * FAIL CLOSED: if the strip or the after-audit fails for any reason, the
#     newly created output is DELETED and the script exits non-zero. A partial,
#     code-signature-invalidated or under-stripped file is never left behind to
#     be mistaken for a finished release.
#   * The output must end with ZERO local symbols. A code-signed input is refused
#     unless --allow-invalidate-signature, and even then an unsigned result is
#     NOT a finished release: re-signing + device verification are still required
#     (see the closing notes).
#   * The input and output paths are compared after canonicalization (symlinks
#     resolved, `.`/`..` folded) so `--out` can never alias the input.
#
# USAGE (macOS, Xcode command line tools)
#   bash scripts/keychainfix_release.sh <KeychainFix.dylib>
#   bash scripts/keychainfix_release.sh <KeychainFix.dylib> \
#        --out <KeychainFix-Release.dylib> \
#        --expect-sha256 <64-hex-sha256-of-the-verified-input> \
#        --report-json <path-to-write-the-before/after-report.json>
#
# USAGE (any host, argument/flow self-test only; no Mach-O tools needed)
#   bash scripts/keychainfix_release.sh --self-check
#
# Exit code 0 = the protected artifact was produced and passed the after-audit.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUDIT="$ROOT/scripts/audit_macho.py"
PYTHON="${PYTHON:-python3}"

# Required KeychainFix hook symbols (local, defined). Their presence proves the
# input is the genuine KeychainFix artifact and not an unrelated dylib.
REQUIRED_SYMBOLS=(
    "_init_universal_keychain_hook"
    "_my_SecItemCopyMatching"
    "_my_SecItemAdd"
    "_my_SecItemUpdate"
    "_my_SecItemDelete"
    "_rebind_symbols"
)
REQUIRED_DEP_SUFFIXES=(
    "/Foundation.framework/Foundation"
    "/Security.framework/Security"
)

INPUT=""
OUTPUT=""
EXPECT_SHA256=""
REPORT_JSON=""
ALLOW_INVALIDATE_SIGNATURE=0
SELF_CHECK=0

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

pass() {
    echo "ok: $*"
}

usage() {
    cat <<'EOF'
KeychainFix protected-artifact release (macOS / Xcode command line tools).

Usage:
  bash scripts/keychainfix_release.sh <KeychainFix.dylib>
  bash scripts/keychainfix_release.sh <KeychainFix.dylib> \
       --out <KeychainFix-Release.dylib> \
       --expect-sha256 <64-hex-sha256-of-the-verified-input> \
       --report-json <path-to-write-the-before/after-report.json>
  bash scripts/keychainfix_release.sh --self-check

The input must be an existing, already-verified KeychainFix.dylib. The output is
a stripped copy (the input is never modified). On any strip/audit failure the
newly created output is deleted and the script exits non-zero.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --out)
            [[ $# -ge 2 ]] || fail "--out requires a path"
            OUTPUT="$2"
            shift 2
            ;;
        --expect-sha256)
            [[ $# -ge 2 ]] || fail "--expect-sha256 requires a hash"
            EXPECT_SHA256="$2"
            shift 2
            ;;
        --report-json)
            [[ $# -ge 2 ]] || fail "--report-json requires a path"
            REPORT_JSON="$2"
            shift 2
            ;;
        --allow-invalidate-signature)
            ALLOW_INVALIDATE_SIGNATURE=1
            shift
            ;;
        --self-check)
            SELF_CHECK=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            fail "unknown option: $1"
            ;;
        *)
            if [[ -n "$INPUT" ]]; then
                fail "only one input artifact may be supplied"
            fi
            INPUT="$1"
            shift
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Self-check: validates argument handling and the missing-input contract on any
# host. It deliberately does NOT need Mach-O tooling.
# ---------------------------------------------------------------------------
if [[ "$SELF_CHECK" == "1" ]]; then
    [[ -f "$AUDIT" ]] || fail "audit tool not found at $AUDIT"
    if bash "${BASH_SOURCE[0]}" >/dev/null 2>&1; then
        fail "a no-argument run must fail"
    fi
    if bash "${BASH_SOURCE[0]}" /nonexistent/KeychainFix.dylib >/dev/null 2>&1; then
        fail "a nonexistent explicit input must fail"
    fi
    if ! bash "${BASH_SOURCE[0]}" --help >/dev/null 2>&1; then
        fail "--help must succeed"
    fi
    if bash "${BASH_SOURCE[0]}" --bogus-option >/dev/null 2>&1; then
        fail "unknown options must fail"
    fi
    if bash "${BASH_SOURCE[0]}" --report-json >/dev/null 2>&1; then
        fail "--report-json without a value must fail"
    fi
    # `--out` may never alias the input, including via a canonical alias path.
    self_dir="$(mktemp -d "${TMPDIR:-/tmp}/kcf-selfcheck.XXXXXX")"
    : > "$self_dir/KeychainFix.dylib"
    if bash "${BASH_SOURCE[0]}" "$self_dir/KeychainFix.dylib" --out "$self_dir/KeychainFix.dylib" >/dev/null 2>&1; then
        rm -rf "$self_dir"
        fail "an --out equal to the input must fail"
    fi
    if bash "${BASH_SOURCE[0]}" "$self_dir/KeychainFix.dylib" --out "$self_dir/./KeychainFix.dylib" >/dev/null 2>&1; then
        rm -rf "$self_dir"
        fail "a canonical --out alias of the input must fail"
    fi
    rm -rf "$self_dir"
    echo "keychainfix_release self-check: PASS"
    exit 0
fi

# ---------------------------------------------------------------------------
# Input validation (host-independent, so a bad path fails even on Windows).
# ---------------------------------------------------------------------------
[[ -n "$INPUT" ]] || { usage >&2; fail "an existing KeychainFix.dylib path is required"; }
[[ -f "$INPUT" ]] || fail "input artifact not found: $INPUT"
[[ -f "$AUDIT" ]] || fail "audit tool not found at $AUDIT"
command -v "$PYTHON" >/dev/null 2>&1 || fail "$PYTHON is required for the audit"

if [[ -z "$OUTPUT" ]]; then
    OUTPUT="$(dirname "$INPUT")/KeychainFix-Release.dylib"
fi

# Resolve a path to an absolute, symlink-free form even when the file does not
# exist yet (its directory must exist). This is how `--out` is prevented from
# aliasing the input through `./`, `..`, or a symlink.
canonicalize() {
    local dir base
    dir="$(dirname -- "$1")"
    base="$(basename -- "$1")"
    dir="$(cd -- "$dir" 2>/dev/null && pwd -P)" || return 1
    printf '%s/%s\n' "${dir%/}" "$base"
}

INPUT_CANON="$(canonicalize "$INPUT")" || fail "could not resolve the input path: $INPUT"
OUTPUT_CANON="$(canonicalize "$OUTPUT")" || fail "the output directory does not exist: $(dirname -- "$OUTPUT")"
[[ "$OUTPUT_CANON" != "$INPUT_CANON" ]] || fail "--out must differ from the input (the original is never modified)"
if [[ -e "$OUTPUT_CANON" ]]; then
    fail "output already exists: $OUTPUT (refusing to overwrite)"
fi

# The Mach-O strip step is macOS-only. Fail loudly rather than silently shipping
# an unstripped artifact.
if [[ "$(uname -s)" != "Darwin" ]]; then
    fail "Mach-O strip requires macOS (Darwin); this host is $(uname -s). Run this on macOS, or use --self-check."
fi
command -v xcrun >/dev/null 2>&1 || fail "xcrun not found; install the Xcode command line tools"
xcrun --find strip >/dev/null 2>&1 || fail "xcrun could not locate 'strip'"

# ---------------------------------------------------------------------------
# Audit helpers.
# ---------------------------------------------------------------------------
audit_to_file() {
    # $1 = binary, $2 = output file
    "$PYTHON" "$AUDIT" "$1" --symbols > "$2"
}

field() {
    # $1 = audit file, $2 = key -> last matching value
    grep -m1 "^$2: " "$1" | sed "s/^$2: //" || true
}

dep_list() {
    # $1 = audit file -> sorted dependency names
    grep '^  dep: ' "$1" | sed 's/^  dep: //' | LC_ALL=C sort
}

json_escape() {
    # Minimal JSON string escaping (backslash + double quote) for path/hash text.
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# ---------------------------------------------------------------------------
# 1. Protected-artifact gate on the INPUT (nothing is written until it passes).
# ---------------------------------------------------------------------------
# Fail closed: once the output has been created, ANY non-zero exit removes it so
# a partial / invalidated / under-stripped file cannot be mistaken for a release.
OUTPUT_CREATED=0
cleanup() {
    local status=$?
    rm -f "${BEFORE:-}" "${AFTER:-}" "${BEFORE:-}.deps" "${AFTER:-}.deps" 2>/dev/null || true
    if [[ "$status" -ne 0 && "$OUTPUT_CREATED" -eq 1 ]]; then
        rm -f "$OUTPUT" 2>/dev/null || true
        echo "FAIL: removed incomplete release output: $OUTPUT" >&2
    fi
    exit "$status"
}
trap cleanup EXIT

echo "== KeychainFix protected-artifact gate (input) =="
BEFORE="$(mktemp "${TMPDIR:-/tmp}/kcf-before.XXXXXX")"
AFTER="$(mktemp "${TMPDIR:-/tmp}/kcf-after.XXXXXX")"

audit_to_file "$INPUT" "$BEFORE"

IN_SHA="$(field "$BEFORE" sha256)"
IN_SIZE="$(field "$BEFORE" size_bytes)"
IN_ARCH="$(field "$BEFORE" arch)"
IN_INSTALL="$(field "$BEFORE" install_name)"
IN_MINOS="$(field "$BEFORE" min_os)"
IN_SIGNED="$(field "$BEFORE" code_signature)"
IN_DWARF="$(field "$BEFORE" dwarf_debug_segment)"
IN_STAB="$(field "$BEFORE" symbols_stab_source)"
IN_LOCAL="$(field "$BEFORE" symbols_local)"
IN_EXT="$(field "$BEFORE" symbols_external_defined)"

echo "  sha256:            $IN_SHA"
echo "  size_bytes:        $(field "$BEFORE" size_bytes)"
echo "  arch:              $IN_ARCH"
echo "  install_name:      $IN_INSTALL"
echo "  min_os:            $IN_MINOS"
echo "  dependencies:      $(field "$BEFORE" dependencies)"
echo "  code_signature:    $IN_SIGNED"
echo "  dwarf_segment:     $IN_DWARF"
echo "  stab_source:       $IN_STAB"
echo "  symbols_local:     $IN_LOCAL"
echo "  symbols_exported:  $IN_EXT"
if grep -q '^leak\[' "$BEFORE"; then
    grep '^leak\[' "$BEFORE" >&2
    fail "input artifact leaks build paths / source names / hooking references"
fi

[[ "$IN_ARCH" == "arm64" ]] || fail "input is not arm64 (got '$IN_ARCH')"
[[ "$IN_INSTALL" == "KeychainFix.dylib" ]] || fail "unexpected install_name: '$IN_INSTALL' (expected KeychainFix.dylib)"
IN_MAJOR="${IN_MINOS%%.*}"
[[ "$IN_MAJOR" =~ ^[0-9]+$ ]] || fail "could not parse min_os: '$IN_MINOS'"
(( IN_MAJOR >= 14 )) || fail "input min OS is below 14.0: $IN_MINOS"
[[ "$IN_DWARF" == "false" ]] || fail "input still carries a __DWARF debug segment"
[[ "$IN_STAB" == "0" ]] || fail "input still carries source STABS debug symbols"
[[ "$IN_SIGNED" == "false" ]] || {
    [[ "$ALLOW_INVALIDATE_SIGNATURE" == "1" ]] || \
        fail "input is code-signed; stripping would leave a stale, invalid signature. Provide an unsigned input, or pass --allow-invalidate-signature (the output must still end unsigned and be re-signed)."
}

for symbol in "${REQUIRED_SYMBOLS[@]}"; do
    grep -qx "symbol: $symbol" "$BEFORE" || fail "required KeychainFix symbol missing: $symbol"
done
for suffix in "${REQUIRED_DEP_SUFFIXES[@]}"; do
    grep -q -F -- "$suffix" "$BEFORE" || fail "required framework dependency missing: $suffix"
done
if [[ -n "$EXPECT_SHA256" ]]; then
    # macOS ships bash 3.2, so avoid ${var,,}; use tr for case folding.
    IN_SHA_LC="$(printf '%s' "$IN_SHA" | tr '[:upper:]' '[:lower:]')"
    EXPECT_SHA_LC="$(printf '%s' "$EXPECT_SHA256" | tr '[:upper:]' '[:lower:]')"
    [[ "$IN_SHA_LC" == "$EXPECT_SHA_LC" ]] || fail "input sha256 $IN_SHA does not match --expect-sha256 $EXPECT_SHA256"
fi
pass "input is the genuine, verified KeychainFix artifact (hook symbols, frameworks, arm64, iOS $IN_MINOS+)"

# ---------------------------------------------------------------------------
# 2. Mach-O-safe strip on a COPY (original is never touched).
# ---------------------------------------------------------------------------
echo "== Strip (copy only) =="
# The output is about to exist; mark it so the EXIT trap deletes it if any later
# step fails.
OUTPUT_CREATED=1
cp "$INPUT" "$OUTPUT"
chmod u+w "$OUTPUT"
# -x: remove local symbols only.  -S: remove debug symbols.  Load commands and
# global/undefined symbols are preserved, so the dylib's hook contract is intact.
xcrun strip -x -S "$OUTPUT"
pass "wrote stripped copy: $OUTPUT"

# ---------------------------------------------------------------------------
# 3. Before/after audit and invariant comparison.
# ---------------------------------------------------------------------------
echo "== KeychainFix protected-artifact audit (after) =="
audit_to_file "$OUTPUT" "$AFTER"

OUT_SHA="$(field "$AFTER" sha256)"
OUT_SIZE="$(field "$AFTER" size_bytes)"
OUT_ARCH="$(field "$AFTER" arch)"
OUT_INSTALL="$(field "$AFTER" install_name)"
OUT_MINOS="$(field "$AFTER" min_os)"
OUT_SIGNED="$(field "$AFTER" code_signature)"
OUT_DWARF="$(field "$AFTER" dwarf_debug_segment)"
OUT_STAB="$(field "$AFTER" symbols_stab_source)"
OUT_LOCAL="$(field "$AFTER" symbols_local)"
OUT_EXT="$(field "$AFTER" symbols_external_defined)"

printf '  %-20s %-18s %s\n' "metric" "before" "after"
printf '  %-20s %-18s %s\n' "sha256" "${IN_SHA:0:16}..." "${OUT_SHA:0:16}..."
printf '  %-20s %-18s %s\n' "size_bytes" "$(field "$BEFORE" size_bytes)" "$(field "$AFTER" size_bytes)"
printf '  %-20s %-18s %s\n' "arch" "$IN_ARCH" "$OUT_ARCH"
printf '  %-20s %-18s %s\n' "install_name" "$IN_INSTALL" "$OUT_INSTALL"
printf '  %-20s %-18s %s\n' "min_os" "$IN_MINOS" "$OUT_MINOS"
printf '  %-20s %-18s %s\n' "dependencies" "$(field "$BEFORE" dependencies)" "$(field "$AFTER" dependencies)"
printf '  %-20s %-18s %s\n' "dwarf_segment" "$IN_DWARF" "$OUT_DWARF"
printf '  %-20s %-18s %s\n' "stab_source" "$IN_STAB" "$OUT_STAB"
printf '  %-20s %-18s %s\n' "symbols_local" "$IN_LOCAL" "$OUT_LOCAL"
printf '  %-20s %-18s %s\n' "symbols_exported" "$IN_EXT" "$(field "$AFTER" symbols_external_defined)"

if grep -q '^leak\[' "$AFTER"; then
    grep '^leak\[' "$AFTER" >&2
    fail "release artifact leaks build paths / source names / hooking references"
fi
[[ "$OUT_ARCH" == "arm64" ]] || fail "release artifact is not arm64"
[[ "$OUT_INSTALL" == "$IN_INSTALL" ]] || fail "install_name changed: '$OUT_INSTALL' != '$IN_INSTALL'"
[[ "$OUT_MINOS" == "$IN_MINOS" ]] || fail "min_os changed: '$OUT_MINOS' != '$IN_MINOS'"
[[ "$OUT_DWARF" == "false" ]] || fail "release artifact still carries a __DWARF debug segment"
[[ "$OUT_STAB" == "0" ]] || fail "release artifact still carries source STABS debug symbols"
# A code signature is only valid over the exact bytes it was made for. Stripping
# changes the bytes, so any signature command left in the output is stale. Refuse
# it: a code-signature-invalidated file must never look like a finished release.
if [[ "$OUT_SIGNED" != "false" ]]; then
    if [[ "$IN_SIGNED" == "true" ]]; then
        fail "the input was code-signed; stripping invalidated its signature and the stale signature command remains — this is not a releasable artifact (re-sign it, then re-run the gate)"
    fi
    fail "release artifact unexpectedly reports a code signature"
fi
# `strip -x` must remove ALL local symbols; a non-zero count means the release is
# not actually stripped, so fail closed.
if [[ "$OUT_LOCAL" != "0" ]]; then
    fail "release artifact still contains $OUT_LOCAL local symbol(s); strip -x must remove all of them"
fi
dep_list "$BEFORE" > "${BEFORE}.deps"
dep_list "$AFTER" > "${AFTER}.deps"
if ! diff -u "${BEFORE}.deps" "${AFTER}.deps" >/dev/null 2>&1; then
    diff -u "${BEFORE}.deps" "${AFTER}.deps" >&2 || true
    fail "dependency list changed across the strip"
fi
rm -f "${BEFORE}.deps" "${AFTER}.deps"
pass "release artifact preserves arch / install_name / min_os / dependencies and is stripped + leak-free"

if [[ "$IN_SIGNED" == "true" ]]; then
    echo "warning: the input was code-signed; the stripped output is UNSIGNED. Re-sign it (ldid -S) before release." >&2
fi

echo ""
echo "Protected artifact: $OUTPUT"
echo "release_sha256:     $OUT_SHA"
echo "input_sha256:       $IN_SHA"

# ---------------------------------------------------------------------------
# 4. Machine-readable before/after report (only after the gate has passed).
# ---------------------------------------------------------------------------
if [[ -n "$REPORT_JSON" ]]; then
    report_dir="$(dirname -- "$REPORT_JSON")"
    [[ -d "$report_dir" ]] || fail "the --report-json directory does not exist: $report_dir"
    {
        printf '{\n'
        printf '  "generatedAt": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '  "verdict": "pass",\n'
        printf '  "input": {\n'
        printf '    "path": "%s",\n' "$(json_escape "$INPUT")"
        printf '    "sha256": "%s",\n' "$IN_SHA"
        printf '    "size_bytes": %s,\n' "${IN_SIZE:-0}"
        printf '    "arch": "%s",\n' "$IN_ARCH"
        printf '    "install_name": "%s",\n' "$(json_escape "$IN_INSTALL")"
        printf '    "min_os": "%s",\n' "$IN_MINOS"
        printf '    "dependencies": %s,\n' "$(field "$BEFORE" dependencies)"
        printf '    "symbols_exported": %s,\n' "${IN_EXT:-0}"
        printf '    "symbols_local": %s,\n' "${IN_LOCAL:-0}"
        printf '    "symbols_stab_source": %s\n' "${IN_STAB:-0}"
        printf '  },\n'
        printf '  "output": {\n'
        printf '    "path": "%s",\n' "$(json_escape "$OUTPUT")"
        printf '    "sha256": "%s",\n' "$OUT_SHA"
        printf '    "size_bytes": %s,\n' "${OUT_SIZE:-0}"
        printf '    "arch": "%s",\n' "$OUT_ARCH"
        printf '    "install_name": "%s",\n' "$(json_escape "$OUT_INSTALL")"
        printf '    "min_os": "%s",\n' "$OUT_MINOS"
        printf '    "dependencies": %s,\n' "$(field "$AFTER" dependencies)"
        printf '    "symbols_exported": %s,\n' "${OUT_EXT:-0}"
        printf '    "symbols_local": %s,\n' "${OUT_LOCAL:-0}"
        printf '    "symbols_stab_source": %s\n' "${OUT_STAB:-0}"
        printf '  }\n'
        printf '}\n'
    } > "$REPORT_JSON"
    echo "report_json:        $REPORT_JSON"
fi

cat <<EOF

== Signing + runtime / device verification (NOT proven by this script) ==
This script proves STRUCTURE only. Its output is an UNSIGNED, stripped dylib; it
is NOT a finished, releasable artifact until it is signed and verified on device.
Complete these steps on a macOS host / test device:

  1. MANDATORY re-sign (the artifact is unsigned after strip):
       ldid -S "$OUTPUT"
     Verify:  codesign -dvvv "$OUTPUT"  (macOS) or ldid -e "$OUTPUT"
  2. Inject the release dylib into the target IPA using the project's existing
     injection tooling, then install on a test device you own/are authorized to test.
  3. Exercise the app's Keychain flows (save/read/update/delete a keychain item).
     Success = the operation no longer fails with -34018 (errSecMissingEntitlement)
     or an access-group mismatch.
  4. Confirm the installed dylib's SHA-256 equals release_sha256 above.
  5. Record device + iOS version. Only then is the protected artifact "verified".
EOF

echo "Release protection checks passed (KeychainFix)."
