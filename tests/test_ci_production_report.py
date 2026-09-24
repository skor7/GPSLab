#!/usr/bin/env python3
"""Fixture tests for scripts/ci_production_report.py.

These tests never depend on a real Mach-O or a real CI run. They feed the
reporter synthetic audit JSON + a synthetic binary whose SHA-256 is computed by
the test, and assert that every value surfaced in the Markdown/JSON comes from
those inputs (no hardcoded or fabricated metric). Negative cases prove the gate
fails closed: SHA mismatch, banned dependency, embedded secret, binary leak and a
failing sensitive-string audit.

Run directly:  python3 tests/test_ci_production_report.py
"""

import hashlib
import importlib.util
import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SCRIPTS = os.path.join(ROOT, "scripts")
REPORTER_PATH = os.path.join(SCRIPTS, "ci_production_report.py")


def load_reporter():
    spec = importlib.util.spec_from_file_location("ci_production_report", REPORTER_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ci = load_reporter()

REQUIRED_DEPS = [
    "/System/Library/Frameworks/Foundation.framework/Foundation",
    "/System/Library/Frameworks/CoreLocation.framework/CoreLocation",
    "/System/Library/Frameworks/UIKit.framework/UIKit",
    "/System/Library/Frameworks/MapKit.framework/MapKit",
]


def make_audit(sha256, size, *, exported, local=0, stab_source=0, leaks=None,
               deps=None, arch="arm64", min_os="16.0.0",
               install_name="@executable_path/Frameworks/GPSLab.dylib",
               dwarf=False, signed=False, strings=10):
    return {
        "sha256": sha256,
        "size_bytes": size,
        "arch": arch,
        "min_os": min_os,
        "install_name": install_name,
        "dependencies": list(REQUIRED_DEPS if deps is None else deps),
        "symbols": {
            "total": 100,
            "local": local,
            "external_defined": exported,
            "stab_source": stab_source,
        },
        "dwarf_debug_segment": dwarf,
        "code_signature": signed,
        "string_count": strings,
        "leaks": dict(leaks or {}),
    }


class ReporterFixtureTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.pass_script = self._write_script(
            "pass_audit.py", "print('ok: no protected plaintext is present in the binary')\n"
        )
        self.fail_script = self._write_script(
            "fail_audit.py",
            "import sys\nprint('FAIL: protected plaintext present')\nsys.exit(1)\n",
        )
        self.env = mock.patch.dict(os.environ, {
            "GITHUB_SHA": "c0ffee1234567890abcdef1234567890abcdef12",
            "GITHUB_REF_NAME": "refs/heads/test",
            "GITHUB_RUN_ID": "4242",
            "GITHUB_REPOSITORY": "example/GPSLab",
        })
        self.env.start()
        self.addCleanup(self.env.stop)

    def _write_script(self, name, body):
        path = os.path.join(self.tmp.name, name)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(body)
        return path

    def _write(self, name, data):
        path = os.path.join(self.tmp.name, name)
        mode = "wb" if isinstance(data, bytes) else "w"
        with open(path, mode) as handle:
            handle.write(data)
        return path

    def _run(self, prod, dev, binary, string_script=None, extra=None):
        prod_path = self._write("prod.json", json.dumps(prod))
        dev_path = self._write("dev.json", json.dumps(dev))
        bin_path = self._write("GPSLab.dylib", binary)
        json_out = os.path.join(self.tmp.name, "report.json")
        md_out = os.path.join(self.tmp.name, "report.md")
        argv = [
            "ci_production_report.py",
            "--prod-audit", prod_path,
            "--dev-audit", dev_path,
            "--binary", bin_path,
            "--out-json", json_out,
            "--out-md", md_out,
        ]
        if string_script is None:
            string_script = self.pass_script
        if string_script != "skip":
            argv += ["--string-audit-script", string_script]
        else:
            argv += ["--skip-string-audit"]
        argv += list(extra or [])
        with mock.patch.object(sys, "argv", argv), \
                redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            rc = ci.main()
        with open(json_out, "r", encoding="utf-8") as handle:
            report = json.load(handle)
        with open(md_out, "r", encoding="utf-8") as handle:
            markdown = handle.read()
        return rc, report, markdown

    def _fixture(self):
        binary = b"not-a-real-macho-fixture-binary" + b"\x00" * 64
        digest = hashlib.sha256(binary).hexdigest()
        size = len(binary)
        dev = make_audit(digest, size, exported=245, local=3271, stab_source=9711,
                         leaks={"build_path_absolute": 63, "source_file_debug": 62},
                         strings=11708)
        prod = make_audit(digest, size, exported=42)
        return prod, dev, binary, digest, size

    def test_markdown_shows_real_metrics(self):
        prod, dev, binary, digest, size = self._fixture()
        rc, report, md = self._run(prod, dev, binary)
        self.assertEqual(rc, 0)
        self.assertEqual(report["verdict"], "pass")
        # Full hash + size + source commit are explicit and match the fixture.
        self.assertIn(f"`{digest}`", md)
        self.assertIn(str(size), md)
        self.assertIn("c0ffee1234567890abcdef1234567890abcdef12", md)
        # Exported DEV/PROD counts are explicit and are the fixture values.
        self.assertIn("Symbols (exported)", md)
        self.assertIn("DEV=245", md)
        self.assertIn("PRODUCTION=42", md)
        # Sensitive-string binary audit verdict + secret scan are explicit.
        self.assertIn("Sensitive-string binary audit: PASS", md)
        self.assertIn("Secret scan: PASS", md)
        self.assertIn("Device / runtime verification: NOT VERIFIED", md)
        # The real audit verdict is carried through to JSON.
        self.assertTrue(report["stringAudit"]["ok"])
        self.assertEqual(report["secretScan"]["findings"], [])

    def test_metrics_are_not_fabricated(self):
        # Change only the fixture numbers; the report must follow them.
        binary = b"another-fixture-binary"
        digest = hashlib.sha256(binary).hexdigest()
        size = len(binary)
        dev = make_audit(digest, size, exported=11)
        prod = make_audit(digest, size, exported=7)
        rc, report, md = self._run(prod, dev, binary)
        self.assertEqual(rc, 0)
        self.assertIn("DEV=11", md)
        self.assertIn("PRODUCTION=7", md)
        self.assertEqual(report["dev"]["symbolsExternalDefined"], 11)
        self.assertEqual(report["production"]["symbolsExternalDefined"], 7)
        self.assertEqual(report["production"]["sizeBytes"], size)

    def test_sha_mismatch_fails_closed(self):
        prod, dev, binary, _, _ = self._fixture()
        prod["sha256"] = "0" * 64  # no longer matches the binary
        with self.assertRaises(SystemExit) as ctx:
            self._run(prod, dev, binary)
        self.assertEqual(ctx.exception.code, 1)

    def test_banned_dependency_fails(self):
        prod, dev, binary, digest, size = self._fixture()
        prod["dependencies"] = REQUIRED_DEPS + ["/usr/lib/libsubstrate.dylib"]
        rc, report, md = self._run(prod, dev, binary)
        self.assertEqual(rc, 1)
        self.assertEqual(report["verdict"], "fail")
        failed = {c["name"] for c in report["checks"] if not c["ok"]}
        self.assertIn("no_banned_dependency", failed)
        self.assertIn("FAIL", md)

    def test_embedded_secret_fails_and_value_is_never_printed(self):
        prod, dev, binary, digest, size = self._fixture()
        secret = b"-----BEGIN RSA PRIVATE KEY-----"
        binary = binary + secret
        prod = make_audit(hashlib.sha256(binary).hexdigest(), len(binary), exported=42)
        rc, report, md = self._run(prod, dev, binary)
        self.assertEqual(rc, 1)
        self.assertEqual(report["verdict"], "fail")
        self.assertIn("private_key_block", report["secretScan"]["findings"])
        # The matched secret value must never appear in the rendered report.
        self.assertNotIn("BEGIN RSA PRIVATE KEY", md)
        self.assertIn("Secret scan: FAIL", md)

    def test_binary_leak_fails(self):
        prod, dev, binary, digest, size = self._fixture()
        prod = make_audit(digest, size, exported=42, leaks={"build_path_absolute": 3})
        rc, report, md = self._run(prod, dev, binary)
        self.assertEqual(rc, 1)
        failed = {c["name"] for c in report["checks"] if not c["ok"]}
        self.assertIn("no_binary_leaks", failed)

    def test_failing_sensitive_string_audit_fails_the_gate(self):
        prod, dev, binary, _, _ = self._fixture()
        rc, report, md = self._run(prod, dev, binary, string_script=self.fail_script)
        self.assertEqual(rc, 1)
        self.assertFalse(report["stringAudit"]["ok"])
        self.assertIn("Sensitive-string binary audit: FAIL", md)
        failed = {c["name"] for c in report["checks"] if not c["ok"]}
        self.assertIn("sensitive_string_binary_audit", failed)

    def test_missing_string_audit_script_is_a_failure_not_a_pass(self):
        prod, dev, binary, _, _ = self._fixture()
        missing = os.path.join(self.tmp.name, "does-not-exist.py")
        rc, report, md = self._run(prod, dev, binary, string_script=missing)
        self.assertEqual(rc, 1)
        self.assertFalse(report["stringAudit"]["ok"])
        self.assertIn("Sensitive-string binary audit: FAIL", md)

    def test_skip_string_audit_marks_not_run(self):
        prod, dev, binary, _, _ = self._fixture()
        rc, report, md = self._run(prod, dev, binary, string_script="skip")
        self.assertEqual(rc, 1)
        self.assertFalse(report["stringAudit"]["ran"])
        self.assertIn("skipped by --skip-string-audit", md)


if __name__ == "__main__":
    unittest.main(verbosity=2)
