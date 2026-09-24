#!/usr/bin/env python3
"""Generate Source/GPSLabProtectedStringsGenerated.h from the manifest.

Source of truth: Source/GPSLabProtectedStrings.def (readable plaintext).
Output:          Source/GPSLabProtectedStringsGenerated.h (committed, generated).

How it protects a literal:

  DEV (default)  GPSLAB_PROTECTED_STRING(Symbol) -> the readable plaintext literal.
  PRODUCTION     GPSLAB_PROTECTED_STRING(Symbol) -> a runtime XOR decode of the
                 stored blob. The preprocessor discards the plaintext macro in
                 production, so the plaintext never reaches the production
                 compiler or the shipped binary.

The encoded blob is XOR'd with a per-symbol key derived from the symbol name. This
is obfuscation, not cryptography: it removes the readable literal from the shipped
binary without touching the canonical, readable source tree.

Usage:
    python3 scripts/gen_protected_strings.py           # write the header
    python3 scripts/gen_protected_strings.py --check    # fail if it is out of sync

Never prints plaintext values (only symbol names and counts).
"""

import argparse
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MANIFEST = os.path.join(ROOT, "Source", "GPSLabProtectedStrings.def")
OUTPUT = os.path.join(ROOT, "Source", "GPSLabProtectedStringsGenerated.h")

ENTRY_RE = re.compile(r'^GPSLAB_STRING\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*,\s*"([^"\\]*)"\s*\)\s*$')
SYMBOL_RE = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*$')
# Defense in depth: refuse anything that looks like a credential. The protected
# values are identifiers, never secrets.
SECRET_RE = re.compile(
    r'(?i)(private[\s_-]?key|password|passwd|secret|api[\s_-]?key|token\s*=|bearer\s|BEGIN [A-Z ]*PRIVATE KEY)'
)

DEV_MARKER = "#else /* DEV: readable plaintext */"


def parse_manifest(path):
    """Return [(symbol, plaintext)] in manifest order, validating the schema."""
    entries = []
    seen = set()
    with open(path, "r", encoding="utf-8") as handle:
        for lineno, raw in enumerate(handle, 1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            match = ENTRY_RE.match(line)
            if match is None:
                raise SystemExit("manifest parse error at line %d" % lineno)
            symbol, plain = match.group(1), match.group(2)
            if not SYMBOL_RE.match(symbol):
                raise SystemExit("invalid symbol at line %d" % lineno)
            if symbol in seen:
                raise SystemExit("duplicate symbol %s" % symbol)
            if not plain:
                raise SystemExit("empty literal for %s" % symbol)
            if not plain.isascii() or any(ord(ch) < 0x20 for ch in plain):
                raise SystemExit("literal for %s must be printable ASCII" % symbol)
            if SECRET_RE.search(plain):
                raise SystemExit("refusing to protect a secret-like literal for %s" % symbol)
            seen.add(symbol)
            entries.append((symbol, plain))
    if not entries:
        raise SystemExit("manifest has no entries")
    return entries


def xor_key(symbol):
    """Deterministic non-zero XOR key for a symbol (FNV-1a based)."""
    digest = 0x811C9DC5
    for byte in symbol.encode("utf-8"):
        digest = ((digest ^ byte) * 0x01000193) & 0xFFFFFFFF
    key = digest & 0xFF
    return key if key else 0x5A


def encode(plain, key):
    """XOR the UTF-8 plaintext with the key."""
    return bytes((byte ^ key) for byte in plain.encode("utf-8"))


def decode(blob, key):
    return bytes((byte ^ key) for byte in blob).decode("utf-8")


def render(entries):
    """Render the full generated header as text (LF line endings)."""
    lines = []
    lines.append("//")
    lines.append("//  GPSLabProtectedStringsGenerated.h")
    lines.append("//  GPSLab")
    lines.append("//")
    lines.append("//  GENERATED FILE - DO NOT EDIT BY HAND.")
    lines.append("//  Source of truth: Source/GPSLabProtectedStrings.def")
    lines.append("//  Regenerate:      python3 scripts/gen_protected_strings.py")
    lines.append("//  Verified in sync: scripts/audit_protected_strings.sh")
    lines.append("//")
    lines.append("//  DEV (default): GPSLAB_PROTECTED_STRING(Symbol) expands to the readable")
    lines.append("//  plaintext literal, so the dev artifact stays fully readable.")
    lines.append("//  PRODUCTION: it expands to a runtime XOR decode of the stored blob, so the")
    lines.append("//  plaintext literal never reaches the production compiler.")
    lines.append("//")
    lines.append("#ifndef GPSLAB_PROTECTED_STRINGS_GENERATED_H")
    lines.append("#define GPSLAB_PROTECTED_STRINGS_GENERATED_H")
    lines.append("")
    lines.append("#if defined(GPSLAB_PRODUCTION) && GPSLAB_PRODUCTION")
    lines.append("")
    lines.append("#define GPSLAB_PROTECTED_STRING(symbol) \\")
    lines.append("    GPSLabProtectedStringDecode(kGPSLabProtected_##symbol, \\")
    lines.append("                                sizeof(kGPSLabProtected_##symbol), \\")
    lines.append("                                kGPSLabProtectedKey_##symbol)")
    lines.append("")
    lines.append(DEV_MARKER)
    lines.append("")
    for symbol, plain in entries:
        lines.append('#define GPSLAB_PROTECTED_STRING_%s (@"%s")' % (symbol, plain))
    lines.append("")
    lines.append("#define GPSLAB_PROTECTED_STRING(symbol) GPSLAB_PROTECTED_STRING_##symbol")
    lines.append("")
    lines.append("#endif")
    lines.append("")
    lines.append("/* Encoded blobs: always present so the portable test can decode them;")
    lines.append("   marked unused so a DEV translation unit stays -Wall/-Wextra clean. */")
    for symbol, plain in entries:
        key = xor_key(symbol)
        blob = encode(plain, key)
        lines.append("static const unsigned char kGPSLabProtected_%s[] __attribute__((unused)) = {" % symbol)
        for index in range(0, len(blob), 12):
            chunk = blob[index:index + 12]
            lines.append("    " + " ".join("0x%02X," % byte for byte in chunk))
        lines.append("};")
        lines.append("static const unsigned char kGPSLabProtectedKey_%s __attribute__((unused)) = 0x%02X;"
                     % (symbol, key))
        lines.append("")
    lines.append("#if defined(GPSLAB_PROTECTED_STRING_TEST)")
    lines.append("")
    lines.append("typedef struct {")
    lines.append("    const char *name;")
    lines.append("    const unsigned char *blob;")
    lines.append("    size_t length;")
    lines.append("    unsigned char key;")
    lines.append("    const char *expected;")
    lines.append("} GPSLabProtectedStringCase;")
    lines.append("")
    lines.append("static const GPSLabProtectedStringCase kGPSLabProtectedStringCases[] __attribute__((unused)) = {")
    for symbol, plain in entries:
        lines.append('    { "%s", kGPSLabProtected_%s, sizeof(kGPSLabProtected_%s), '
                     'kGPSLabProtectedKey_%s, "%s" },'
                     % (symbol, symbol, symbol, symbol, plain))
    lines.append("};")
    lines.append("")
    lines.append("#define GPSLAB_PROTECTED_STRING_CASE_COUNT \\")
    lines.append("    (sizeof(kGPSLabProtectedStringCases) / sizeof(kGPSLabProtectedStringCases[0]))")
    lines.append("")
    lines.append("#endif /* GPSLAB_PROTECTED_STRING_TEST */")
    lines.append("")
    lines.append("#endif /* GPSLAB_PROTECTED_STRINGS_GENERATED_H */")
    lines.append("")
    return "\n".join(lines)


def read_output():
    with open(OUTPUT, "r", encoding="utf-8", newline="") as handle:
        return handle.read()


def normalize(text):
    return text.replace("\r\n", "\n")


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true",
                        help="verify the committed header matches the manifest")
    args = parser.parse_args(argv)

    if not os.path.isfile(MANIFEST):
        raise SystemExit("manifest not found: %s" % MANIFEST)
    entries = parse_manifest(MANIFEST)
    rendered = render(entries)

    if args.check:
        if not os.path.isfile(OUTPUT):
            raise SystemExit("generated header missing: %s" % OUTPUT)
        if normalize(read_output()) != normalize(rendered):
            raise SystemExit("generated header is out of sync; run: python3 scripts/gen_protected_strings.py")
        print("ok: generated header is in sync (%d protected literals)" % len(entries))
        return 0

    with open(OUTPUT, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(rendered)
    print("wrote %s (%d protected literals)" % (os.path.relpath(OUTPUT, ROOT), len(entries)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
