#!/usr/bin/env python3
"""Semantic embedded-secret scan for GPSLab shipping sources.

The static release gate must flag genuinely embedded credentials while allowing
safe runtime code to pass. A naive ``secret\\s*=`` grep is not semantic: it also
matches the harmless ``deviceSecret`` Keychain variable and the
``"devicesecret="`` URL query blocker. This scan replaces that grep with rules
that distinguish a *hardcoded credential literal* from a *runtime reference*:

  * ``private_key_block``   - a real PEM ``-----BEGIN ... PRIVATE KEY-----``.
  * ``private_key_token``   - a ``PRIVATE_KEY`` symbol (case-insensitive).
  * ``assigned_credential`` - a credential-named variable assigned a hardcoded
    string literal. The token boundary ``(?<![A-Za-z0-9])`` stops a suffix of a
    larger identifier from matching (so ``kGPSLabAccountDeviceSecret`` stays
    safe, only a standalone ``secret`` / ``password`` / ``api_key`` token can
    match). A dedicated ``deviceSecret`` alternative is listed explicitly so the
    camelCase/underscore Keychain variable is still flagged when assigned a
    literal, while the required quote prevents matching a non-literal right-hand
    side such as ``deviceSecret = [store deviceSecret]``.

No matched value is ever printed: findings are reported as
``path:line: pattern`` only. Exit code 0 = clean, 1 = at least one finding.

Usage:
    python3 scripts/source_secret_scan.py Source --root .
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

# A real PEM private-key block. High signal on its own.
PRIVATE_KEY_BLOCK = re.compile(r"-----BEGIN (?:[A-Z0-9 ]+ )?PRIVATE KEY-----")
# A `PRIVATE_KEY` symbol (case-insensitive), as used by credential config code.
PRIVATE_KEY_TOKEN = re.compile(r"\bPRIVATE_KEY\b", re.IGNORECASE)
# A credential-named variable assigned a hardcoded string literal.
ASSIGNED_CREDENTIAL = re.compile(
    r"(?<![A-Za-z0-9])"
    r"(?:client[_-]?secret|device[_-]?secret|signing[_-]?key|private[_-]?key"
    r"|secret|password|passwd|api[_-]?key|apikey|access[_-]?key)"
    r"\s*[:=]\s*"
    r"@?[\"']"
    r"[^\"'\n]+"
    r"[\"']",
    re.IGNORECASE,
)

# Pattern display name -> compiled regex. Order is stable for deterministic
# findings so a fixture diff is reproducible.
PATTERNS = (
    ("private_key_block", PRIVATE_KEY_BLOCK),
    ("private_key_token", PRIVATE_KEY_TOKEN),
    ("assigned_credential", ASSIGNED_CREDENTIAL),
)


def scan_text(text: str):
    """Return a sorted list of ``(line_number, pattern_name)`` findings."""
    findings = []
    for number, line in enumerate(text.splitlines(), start=1):
        for name, pattern in PATTERNS:
            if pattern.search(line):
                findings.append((number, name))
    return findings


def scan_file(file_path: str):
    """Return ``(line_number, pattern_name)`` findings for one file.

    Unreadable files are skipped rather than crashing the gate; the scan is a
    deny-list over source text, not a completeness proof.
    """
    try:
        data = Path(file_path).read_bytes()
    except OSError:
        return []
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        text = data.decode("latin-1")
    return scan_text(text)


def iter_files(targets):
    """Yield every regular file reachable from the supplied files/directories."""
    for target in targets:
        if os.path.isdir(target):
            for root, dirs, files in os.walk(target):
                dirs.sort()
                for name in sorted(files):
                    yield os.path.join(root, name)
        elif os.path.isfile(target):
            yield target


def scan_targets(targets, root=None):
    """Return sorted, de-duplicated ``path:line: pattern`` finding strings."""
    findings = set()
    for file_path in iter_files(targets):
        for number, name in scan_file(file_path):
            display = os.path.relpath(file_path, root) if root else file_path
            findings.add(f"{display}:{number}: {name}")
    return sorted(findings)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="+", help="files or directories to scan")
    parser.add_argument("--root", help="make reported paths relative to this root")
    args = parser.parse_args(argv)

    findings = scan_targets(args.paths, root=args.root)
    if findings:
        for finding in findings:
            print(finding)
        print(
            f"FAIL: {len(findings)} embedded credential/private-key finding(s)",
            file=sys.stderr,
        )
        return 1
    print("ok: no embedded secrets, private keys or credential literals")
    return 0


if __name__ == "__main__":
    sys.exit(main())
