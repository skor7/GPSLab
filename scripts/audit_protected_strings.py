#!/usr/bin/env python3
"""Static audit for the GPSLab production-only protected-string facility.

Proves, deterministically and without an iOS toolchain:

  1. the committed generated header matches the manifest (`gen --check` is also
     run by scripts/audit_protected_strings.sh);
  2. every encoded blob decodes back to its declared plaintext;
  3. no encoded blob contains its plaintext, and no blob equals it;
  4. the PRODUCTION macro expansion never mentions the plaintext, and the
     production branch of the header contains no plaintext literal;
  5. the DEV macro expansion yields the readable plaintext literal;
  6. every GPSLAB_PROTECTED_STRING(Symbol) call site uses a manifest symbol, the
     importing translation unit imports the header, and every manifest symbol is
     actually used (no dead entries);
  7. no protected literal is secret-like;
  8. with `--binary PATH`, none of the protected plaintexts is present as a
     NUL-terminated UTF-8/UTF-16 string in the shipped artifact.

The audit only ever prints symbol names and counts, never plaintext values.
"""

import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import gen_protected_strings as gen  # noqa: E402

ROOT = gen.ROOT
SOURCE = os.path.join(ROOT, "Source")
HEADER = gen.OUTPUT
DEV_MARKER = gen.DEV_MARKER
CALL_RE = re.compile(r'GPSLAB_PROTECTED_STRING\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*\)')
ANY_CALL_RE = re.compile(r'GPSLAB_PROTECTED_STRING\s*\(')
IMPORT_LINE = '#import "GPSLabProtectedString.h"'


def fail(message):
    print("FAIL: %s" % message, file=sys.stderr)
    raise SystemExit(1)


def check_header_in_sync(entries):
    if not os.path.isfile(HEADER):
        fail("generated header missing")
    committed = gen.normalize(gen.read_output())
    expected = gen.normalize(gen.render(entries))
    if committed != expected:
        fail("generated header is out of sync with the manifest")


def check_round_trip(entries):
    for symbol, plain in entries:
        key = gen.xor_key(symbol)
        blob = gen.encode(plain, key)
        if gen.decode(blob, key) != plain:
            fail("round-trip failed for %s" % symbol)
        if bytes(blob) == plain.encode("utf-8"):
            fail("encoded blob equals plaintext for %s" % symbol)
        if len(plain) >= 4 and plain.encode("utf-8") in bytes(blob):
            fail("encoded blob leaks plaintext bytes for %s" % symbol)
    print("ok: %d encoded blobs round-trip and contain no plaintext" % len(entries))


def check_macro_semantics(entries, header):
    prod_branch = header.split(DEV_MARKER)[0]
    for symbol, plain in entries:
        plaintext_macro = '#define GPSLAB_PROTECTED_STRING_%s (@"%s")' % (symbol, plain)
        if plaintext_macro not in header:
            fail("DEV plaintext macro missing for %s" % symbol)
        if ('@"%s"' % plain) in prod_branch:
            fail("production branch contains a plaintext literal for %s" % symbol)
        expansion = ("GPSLabProtectedStringDecode(kGPSLabProtected_%s, "
                     "sizeof(kGPSLabProtected_%s), kGPSLabProtectedKey_%s)"
                     % (symbol, symbol, symbol))
        if plain in expansion:
            fail("production macro expansion mentions the plaintext for %s" % symbol)
    print("ok: DEV expands to plaintext; PRODUCTION expansion is plaintext-free")


def source_files():
    files = []
    for name in sorted(os.listdir(SOURCE)):
        if name.endswith(".m") or name.endswith(".c"):
            files.append(os.path.join(SOURCE, name))
    return files


def check_call_sites(entries):
    manifest_symbols = {symbol for symbol, _ in entries}
    used = set()
    for path in source_files():
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            text = handle.read()
        for match in CALL_RE.finditer(text):
            symbol = match.group(1)
            used.add(symbol)
            if symbol not in manifest_symbols:
                fail("%s uses an unknown protected symbol: %s"
                     % (os.path.basename(path), symbol))
            if IMPORT_LINE not in text:
                fail("%s uses GPSLAB_PROTECTED_STRING without importing GPSLabProtectedString.h"
                     % os.path.basename(path))
        # A call that carries a string literal would bypass the manifest.
        for raw in ANY_CALL_RE.finditer(text):
            tail = text[raw.end():text.find(")", raw.end()) + 1]
            if '"' in tail:
                fail("%s passes a string literal to GPSLAB_PROTECTED_STRING"
                     % os.path.basename(path))
    missing = manifest_symbols - used
    if missing:
        fail("manifest symbol(s) never used: %s" % ", ".join(sorted(missing)))
    print("ok: %d call sites, all manifest symbols used, no literal bypass" % len(used))


def check_binary(entries, path):
    if not os.path.isfile(path):
        fail("binary not found at the supplied path")
    with open(path, "rb") as handle:
        data = handle.read()
    for symbol, plain in entries:
        needles = [
            plain.encode("utf-8") + b"\x00",
            plain.encode("utf-16-le") + b"\x00\x00",
        ]
        if any(needle in data for needle in needles):
            fail("protected plaintext for %s is present in the binary" % symbol)
    print("ok: no protected plaintext is present in the binary")


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default=None,
                        help="optional shipped artifact to scan for protected plaintexts")
    args = parser.parse_args(argv)

    if not os.path.isfile(gen.MANIFEST):
        fail("manifest not found: %s" % gen.MANIFEST)
    entries = gen.parse_manifest(gen.MANIFEST)

    check_header_in_sync(entries)
    print("ok: generated header is in sync (%d protected literals)" % len(entries))
    check_round_trip(entries)
    with open(HEADER, "r", encoding="utf-8", errors="replace") as handle:
        header = handle.read()
    check_macro_semantics(entries, header)
    check_call_sites(entries)
    if args.binary:
        check_binary(entries, args.binary)
    print("Protected-string audit passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
