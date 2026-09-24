#!/usr/bin/env python3
"""GPSLab production-build report and release gate for CI.

Consumes the JSON emitted by ``scripts/audit_macho.py --json`` for a DEV baseline
and a PRODUCTION artifact, enforces the production contract, runs an explicit
secret scan over the production binary, and writes BOTH a machine-readable JSON
report and a human-readable Markdown report. Every number comes from the supplied
audits / the actual binary: nothing is hardcoded or invented here.

Usage:
    python3 scripts/ci_production_report.py \
        --prod-audit prod.json [--dev-audit dev.json] \
        --binary GPSLab.dylib \
        --out-json report.json --out-md report.md

Exit code 0 = every production check passed. It never prints matched secret
values: findings are reported as ``pattern -> count`` only.

This script reuses ``audit_macho.py`` for the structural measurement (it does not
re-parse Mach-O itself); it only adds the release checks, the secret scan and the
report rendering.
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import re
import subprocess
import sys

# High-confidence secret patterns. Deliberately narrow so framework constants
# (e.g. Security.framework's kSecClassGenericPassword, which contains "Password")
# do not produce false positives. Values are never printed.
SECRET_PATTERNS = [
    ("private_key_block", re.compile(rb"-----BEGIN (?:[A-Z0-9 ]+ )?PRIVATE KEY-----")),
    ("aws_access_key_id", re.compile(rb"\bAKIA[0-9A-Z]{16}\b")),
    ("github_token", re.compile(rb"\b(?:ghp|gho|ghs|ghu)_[A-Za-z0-9]{20,}\b")),
    ("github_pat", re.compile(rb"\bgithub_pat_[A-Za-z0-9_]{20,}\b")),
    ("slack_token", re.compile(rb"\bxox[baprs]-[A-Za-z0-9-]{10,}\b")),
    ("assigned_secret", re.compile(
        rb"(?i)\b(?:private_key|secret_key|client_secret|signing_key)\s*[:=]\s*['\"]?[A-Za-z0-9/+_=.-]{12,}"
    )),
]

REQUIRED_FRAMEWORKS = [
    "/Foundation.framework/Foundation",
    "/CoreLocation.framework/CoreLocation",
    "/UIKit.framework/UIKit",
    "/MapKit.framework/MapKit",
]
BANNED_DEPENDENCIES = ("substrate", "ellekit", "libhooker")
EXPECTED_INSTALL_NAME = "@executable_path/Frameworks/GPSLab.dylib"
MINIMUM_IOS_MAJOR = 16
BANNED_BINARY_REFERENCES = ("substrate", "ellekit", "libhooker", "cydia")

# The binary-level "sensitive string" audit is the protected-string facility's
# own gate: it proves no protected client plaintext survives into the shipped
# artifact. The reporter runs the real audit (never a fabricated verdict); the
# path is overridable so tests can point at a fixture and so CI can relocate it.
DEFAULT_STRING_AUDIT_SCRIPT = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "audit_protected_strings.py"
)


def fail(message: str) -> None:
    print(f"FAIL: {message}", file=sys.stderr)
    sys.exit(1)


def load_json(path: str) -> dict:
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError) as error:
        fail(f"could not read audit JSON {path}: {error}")
        raise  # unreachable


def version_major(value: object) -> int:
    text = str(value or "").strip()
    head = text.split(".", 1)[0]
    if not head.isdigit():
        return -1
    return int(head)


def scan_secrets(data: bytes) -> dict:
    counts = {}
    for name, pattern in SECRET_PATTERNS:
        count = len(pattern.findall(data))
        if count:
            counts[name] = count
    return counts


def run_sensitive_string_audit(binary_path: str, script_path: str) -> dict:
    """Run the protected-string binary audit and return its real verdict.

    Nothing is assumed: when the script is missing or cannot run, the verdict is
    a failure (``ok=False``), never a silent pass. The audit only prints symbol
    names and counts, so its output is safe to surface in the report.
    """
    if not script_path or not os.path.isfile(script_path):
        return {
            "ran": False,
            "ok": False,
            "detail": f"sensitive-string audit script not found: {script_path or 'unset'}",
        }
    python = os.environ.get("PYTHON") or sys.executable or "python3"
    try:
        proc = subprocess.run(
            [python, script_path, "--binary", binary_path],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
    except OSError as error:
        return {"ran": False, "ok": False, "detail": f"could not run sensitive-string audit: {error}"}
    lines = [line for line in proc.stdout.strip().splitlines() if line.strip()]
    if proc.returncode == 0:
        detail = lines[-1] if lines else "sensitive-string audit passed"
        return {"ran": True, "ok": True, "detail": detail}
    return {
        "ran": True,
        "ok": False,
        "detail": "sensitive-string audit failed (see CI logs; no values are printed)",
    }


def git_value(*args: str) -> str | None:
    try:
        out = subprocess.run(
            ["git", *args],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=True,
            text=True,
        )
        value = out.stdout.strip()
        return value or None
    except (OSError, subprocess.SubprocessError):
        return None


def summarize(audit: dict) -> dict:
    """A stable subset of the audit used in the report and the comparison."""
    if not audit:
        return {}
    return {
        "sha256": audit.get("sha256"),
        "sizeBytes": audit.get("size_bytes"),
        "arch": audit.get("arch"),
        "minOs": audit.get("min_os"),
        "installName": audit.get("install_name"),
        "dependencies": audit.get("dependencies", []),
        "symbolsTotal": (audit.get("symbols") or {}).get("total"),
        "symbolsLocal": (audit.get("symbols") or {}).get("local"),
        "symbolsExternalDefined": (audit.get("symbols") or {}).get("external_defined"),
        "symbolsStabSource": (audit.get("symbols") or {}).get("stab_source"),
        "dwarfDebugSegment": audit.get("dwarf_debug_segment"),
        "codeSignature": audit.get("code_signature"),
        "stringCount": audit.get("string_count"),
        "leaks": audit.get("leaks", {}),
    }


def check(name: str, ok: bool, detail: str) -> dict:
    return {"name": name, "ok": bool(ok), "detail": detail}


def evaluate(prod: dict, secret_findings: dict, string_audit: dict | None = None) -> list[dict]:
    string_audit = string_audit or {}
    deps = list(prod.get("dependencies") or [])
    lowered_deps = [dep.lower() for dep in deps]
    symbols = prod.get("symbols") or {}
    leaks = prod.get("leaks") or {}
    expected = EXPECTED_INSTALL_NAME

    checks = [
        check("arch_arm64", prod.get("arch") == "arm64", f"arch={prod.get('arch')}"),
        check(
            "min_ios_16",
            version_major(prod.get("min_os")) >= MINIMUM_IOS_MAJOR,
            f"min_os={prod.get('min_os')}",
        ),
        check(
            "install_name",
            prod.get("install_name") == expected,
            f"install_name={prod.get('install_name')}",
        ),
    ]
    for framework in REQUIRED_FRAMEWORKS:
        checks.append(check(
            f"dependency_{framework.split('/')[1]}",
            any(framework.lower() in dep.lower() for dep in deps),
            f"present={any(framework.lower() in dep.lower() for dep in deps)}",
        ))
    checks.append(check(
        "no_banned_dependency",
        not any(word in dep for dep in lowered_deps for word in BANNED_DEPENDENCIES),
        f"dependencies={len(deps)}",
    ))
    checks.append(check(
        "no_dwarf_debug_segment",
        prod.get("dwarf_debug_segment") is False,
        f"dwarf_debug_segment={prod.get('dwarf_debug_segment')}",
    ))
    checks.append(check(
        "no_source_stabs",
        symbols.get("stab_source") == 0,
        f"symbols_stab_source={symbols.get('stab_source')}",
    ))
    checks.append(check(
        "no_local_symbols",
        symbols.get("local") == 0,
        f"symbols_local={symbols.get('local')}",
    ))
    checks.append(check(
        "no_binary_leaks",
        not leaks,
        f"leaks={sorted(leaks)}",
    ))
    checks.append(check(
        "secret_scan",
        not secret_findings,
        f"findings={sorted(secret_findings)}",
    ))
    checks.append(check(
        "sensitive_string_binary_audit",
        bool(string_audit.get("ok")),
        string_audit.get("detail") or "not run",
    ))
    return checks


def render_markdown(report: dict) -> str:
    lines = []
    lines.append("# GPSLab production build report")
    lines.append("")
    lines.append("Generated by CI from the actual built artifacts. No metric is hardcoded.")
    lines.append("")
    meta = report["meta"]
    lines.append("| Field | Value |")
    lines.append("| --- | --- |")
    for key in ("generatedAt", "commit", "ref", "runId", "repository"):
        lines.append(f"| {key} | {meta.get(key) or 'n/a'} |")
    lines.append(f"| verdict | {'PASS' if report['verdict'] == 'pass' else 'FAIL'} |")
    lines.append("")

    lines.append("## Artifacts")
    lines.append("")
    lines.append("| Artifact | SHA-256 (full) | Size (bytes) |")
    lines.append("| --- | --- | ---: |")
    for label, key in (("DEV baseline", "dev"), ("PRODUCTION", "production")):
        item = report.get(key) or {}
        lines.append(f"| {label} | `{item.get('sha256') or 'n/a'}` | {item.get('sizeBytes') if item.get('sizeBytes') is not None else 'n/a'} |")
    lines.append("")

    lines.append("## Hardening comparison (DEV -> PRODUCTION)")
    lines.append("")
    rows = [
        ("Architecture", "arch"),
        ("Minimum iOS", "minOs"),
        ("install_name", "installName"),
        ("Dependencies", "dependencies"),
        ("Symbols (total)", "symbolsTotal"),
        ("Symbols (exported)", "symbolsExternalDefined"),
        ("Symbols (local)", "symbolsLocal"),
        ("Symbols (source STABS)", "symbolsStabSource"),
        ("__DWARF segment", "dwarfDebugSegment"),
        ("Code signature", "codeSignature"),
        ("Strings", "stringCount"),
        ("Leaks", "leaks"),
    ]
    dev = report.get("dev") or {}
    prod = report.get("production") or {}
    lines.append("| Metric | DEV | PRODUCTION |")
    lines.append("| --- | --- | --- |")
    for label, key in rows:
        dev_value = dev.get(key)
        prod_value = prod.get(key)
        if key == "dependencies":
            dev_value = len(dev_value or [])
            prod_value = len(prod_value or [])
        lines.append(f"| {label} | {_fmt(dev_value)} | {_fmt(prod_value)} |")
    lines.append("")

    lines.append("## Production checks")
    lines.append("")
    lines.append("| Check | Result | Detail |")
    lines.append("| --- | --- | --- |")
    for item in report["checks"]:
        lines.append(f"| {item['name']} | {'PASS' if item['ok'] else 'FAIL'} | {_md(item['detail'])} |")
    lines.append("")

    # Explicit release-gate summary: the reader must not have to infer any of
    # these from the tables above. Every value is read from the supplied audits /
    # the actual binary; nothing here is hardcoded or invented.
    string_audit = report.get("stringAudit") or {}
    secret = report.get("secretScan") or {}
    findings = secret.get("findings") or []
    lines.append("## Release gates (explicit)")
    lines.append("")
    lines.append(f"- Exported symbols: DEV={_fmt(dev.get('symbolsExternalDefined'))}, "
                 f"PRODUCTION={_fmt(prod.get('symbolsExternalDefined'))}")
    lines.append(f"- Sensitive-string binary audit: "
                 f"{'PASS' if string_audit.get('ok') else 'FAIL'} "
                 f"({_md(string_audit.get('detail') or 'not run')})")
    lines.append(f"- Secret scan: {'PASS' if not findings else 'FAIL'} "
                 f"({len(findings)} finding(s): {', '.join(findings) or 'none'})")
    lines.append(f"- Source commit: {meta.get('commit') or 'n/a'}")
    lines.append(f"- PRODUCTION SHA-256 (full): `{prod.get('sha256') or 'n/a'}`")
    lines.append(f"- PRODUCTION size: "
                 f"{prod.get('sizeBytes') if prod.get('sizeBytes') is not None else 'n/a'} bytes")
    lines.append("- Device / runtime verification: NOT VERIFIED "
                 "(CI proves the static build/artifact contract only)")
    lines.append("")
    return "\n".join(lines)


def _fmt(value: object) -> str:
    if isinstance(value, (list, tuple)):
        return ", ".join(str(item) for item in value) if value else "none"
    if isinstance(value, dict):
        return ", ".join(f"{k}x{v}" for k, v in sorted(value.items())) if value else "none"
    if value is None:
        return "n/a"
    return str(value)


def _md(value: object) -> str:
    return str(value).replace("|", "\\|")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--prod-audit", required=True)
    parser.add_argument("--dev-audit")
    parser.add_argument("--binary", required=True)
    parser.add_argument("--out-json")
    parser.add_argument("--out-md")
    parser.add_argument(
        "--string-audit-script",
        default=DEFAULT_STRING_AUDIT_SCRIPT,
        help="protected-string binary audit script (default: scripts/audit_protected_strings.py)",
    )
    parser.add_argument(
        "--skip-string-audit",
        action="store_true",
        help="skip the sensitive-string binary audit (the verdict is then FAIL/not run)",
    )
    args = parser.parse_args()

    try:
        with open(args.binary, "rb") as handle:
            binary = handle.read()
    except OSError as error:
        fail(f"production binary not found: {error}")
        return 1
    digest = hashlib.sha256(binary).hexdigest()

    prod = load_json(args.prod_audit)
    dev = load_json(args.dev_audit) if args.dev_audit else {}

    if prod.get("sha256") != digest:
        fail("the supplied production audit does not match the supplied binary (SHA-256 mismatch)")

    secret_findings = scan_secrets(binary)
    if args.skip_string_audit:
        string_audit = {"ran": False, "ok": False, "detail": "skipped by --skip-string-audit"}
    else:
        string_audit = run_sensitive_string_audit(args.binary, args.string_audit_script)
    checks = evaluate(prod, secret_findings, string_audit)
    verdict = "pass" if all(item["ok"] for item in checks) else "fail"

    meta = {
        "generatedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "commit": os.environ.get("GITHUB_SHA") or git_value("rev-parse", "HEAD"),
        "ref": os.environ.get("GITHUB_REF_NAME") or git_value("rev-parse", "--abbrev-ref", "HEAD"),
        "runId": os.environ.get("GITHUB_RUN_ID"),
        "repository": os.environ.get("GITHUB_REPOSITORY"),
    }

    report = {
        "meta": meta,
        "dev": summarize(dev),
        "production": summarize(prod),
        "secretScan": {"findings": sorted(secret_findings), "counts": secret_findings},
        "stringAudit": string_audit,
        "checks": checks,
        "verdict": verdict,
    }

    if args.out_json:
        with open(args.out_json, "w", encoding="utf-8") as handle:
            json.dump(report, handle, indent=2, sort_keys=True)
            handle.write("\n")
    if args.out_md:
        with open(args.out_md, "w", encoding="utf-8") as handle:
            handle.write(render_markdown(report))

    print("GPSLab production report")
    print(f"  sha256:            {digest}")
    print(f"  size_bytes:        {len(binary)}")
    print(f"  min_os:            {prod.get('min_os')}")
    print(f"  install_name:      {prod.get('install_name')}")
    print(f"  exported symbols:  dev={(dev.get('symbols') or {}).get('external_defined')} "
          f"prod={(prod.get('symbols') or {}).get('external_defined')}")
    print(f"  secret_findings:   {len(secret_findings)}")
    print(f"  string_audit:      {'PASS' if string_audit.get('ok') else 'FAIL'}")
    failed = [item["name"] for item in checks if not item["ok"]]
    if failed:
        print(f"  FAILED checks:     {', '.join(failed)}", file=sys.stderr)
        return 1
    print("  verdict:           PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
