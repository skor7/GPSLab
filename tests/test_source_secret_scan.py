#!/usr/bin/env python3
"""Regression fixtures for scripts/source_secret_scan.py.

These tests pin the semantic contract of the release-gate source secret scan:
genuinely embedded credentials (PEM private-key blocks, ``PRIVATE_KEY`` symbols
and credential-named variables assigned a hardcoded string literal) MUST be
flagged, while the safe runtime Keychain ``deviceSecret`` variable and the
``"devicesecret="`` URL query blocker MUST pass.

The scan is deliberately semantic, not a bare grep: a standalone ``secret =``
token assigned a real literal fails, and so does ``deviceSecret = @"literal"``
(the camelCase Keychain variable gets an explicit credential-name rule). But
``deviceSecret = [someCall]`` runtime references and
``kGPSLabAccountDeviceSecret = @"deviceSecret"`` (an account *name*, not a
credential value) pass. A real-tree case proves the shipping sources currently
pass, and that the device query-string protection was not removed to make the
gate green.

Run directly:  python3 tests/test_source_secret_scan.py
"""

import importlib.util
import io
import os
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SCANNER_PATH = os.path.join(ROOT, "scripts", "source_secret_scan.py")
SOURCE_DIR = os.path.join(ROOT, "Source")


def load_scanner():
    spec = importlib.util.spec_from_file_location("source_secret_scan", SCANNER_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


scanner = load_scanner()

# A realistic-looking literal used throughout the fixtures. It is intentionally
# NOT a real credential.
LITERAL = "hunter2hunter2"


class SourceSecretScanFixtureTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def _scan_line(self, line):
        text = line if line.endswith("\n") else line + "\n"
        return scanner.scan_text(text)

    # -------------------------------------------------- negative (must flag) --
    def test_pem_private_key_block_is_flagged(self):
        for block in (
            "-----BEGIN RSA PRIVATE KEY-----",
            "-----BEGIN PRIVATE KEY-----",
            "-----BEGIN EC PRIVATE KEY-----",
        ):
            with self.subTest(block=block):
                findings = self._scan_line(block)
                self.assertIn("private_key_block", [name for _, name in findings])

    def test_private_key_symbol_is_flagged(self):
        findings = self._scan_line("#define PRIVATE_KEY 0x42")
        self.assertIn("private_key_token", [name for _, name in findings])

    def test_plain_secret_assignment_is_flagged(self):
        findings = self._scan_line(f'NSString *secret = @"{LITERAL}";')
        self.assertIn("assigned_credential", [name for _, name in findings])

    def test_password_assignment_is_flagged(self):
        findings = self._scan_line(f'NSString *password = @"{LITERAL}";')
        self.assertIn("assigned_credential", [name for _, name in findings])

    def test_api_key_assignment_is_flagged(self):
        for line in (
            f'NSString *apiKey = @"{LITERAL}";',
            f'NSString *api_key = @"{LITERAL}";',
            f'NSString *api-key = @"{LITERAL}";',
        ):
            with self.subTest(line=line):
                findings = self._scan_line(line)
                self.assertIn("assigned_credential", [name for _, name in findings])

    def test_client_secret_and_signing_key_assignments_are_flagged(self):
        for name in ("client_secret", "signing_key", "private_key"):
            with self.subTest(name=name):
                findings = self._scan_line(f'NSString *{name} = @"{LITERAL}";')
                self.assertIn("assigned_credential", [name for _, name in findings])

    def test_device_secret_literal_assignment_is_flagged(self):
        # The camelCase/underscore Keychain variable is only safe when its
        # right-hand side is a runtime reference, never a hardcoded literal.
        for name in ("deviceSecret", "device_secret", "DeviceSecret"):
            with self.subTest(name=name):
                findings = self._scan_line(f'NSString *{name} = @"{LITERAL}";')
                self.assertIn("assigned_credential", [name for _, name in findings])
        findings = self._scan_line(f'device_secret = "{LITERAL}";')
        self.assertIn("assigned_credential", [name for _, name in findings])

    # -------------------------------------------------- positive (must pass) --
    def test_runtime_device_secret_variable_passes(self):
        for line in (
            "NSString *deviceSecret = [[GPSLabSecureStore sharedStore] deviceSecretBase64];",
            'NSDictionary *body = @{@"deviceSecret": deviceSecret};',
            "NSData *secret = [self deviceSecret];",
            "NSData *secret = [generated copy];",
            "- (void)pairWithInstallation:(NSString *)installationId "
            "deviceSecret:(nullable NSString *)deviceSecret;",
        ):
            with self.subTest(line=line):
                self.assertEqual(self._scan_line(line), [])

    def test_keychain_account_name_constant_passes(self):
        line = 'static NSString * const kGPSLabAccountDeviceSecret = @"deviceSecret";'
        self.assertEqual(self._scan_line(line), [])
        # The credential token must not be split out of a larger identifier, even
        # when that identifier is assigned a literal (an account *name* constant).
        prefixed = f'static NSString * const kGPSLabAccountDeviceSecret = @"{LITERAL}";'
        self.assertEqual(self._scan_line(prefixed), [])

    def test_url_query_blocker_token_passes(self):
        # The device query-string protection token is not an assignment.
        self.assertEqual(self._scan_line('        "devicesecret=",'), [])

    # ------------------------------------------------------- CLI behaviour ----
    def _write(self, name, body):
        file_path = os.path.join(self.tmp.name, name)
        with open(file_path, "w", encoding="utf-8") as handle:
            handle.write(body)
        return file_path

    def test_cli_flags_a_fixture_and_never_prints_the_value(self):
        file_path = self._write("bad.m", f'NSString *password = @"{LITERAL}";\n')
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            rc = scanner.main([file_path])
        self.assertEqual(rc, 1)
        self.assertIn("assigned_credential", out.getvalue())
        # The literal value itself must never be echoed into the log output.
        self.assertNotIn(LITERAL, out.getvalue())
        self.assertNotIn(LITERAL, err.getvalue())
        self.assertIn("FAIL", err.getvalue())

    def test_cli_passes_a_safe_fixture(self):
        file_path = self._write(
            "good.m",
            "NSData *secret = [self deviceSecret];\n"
            '        "devicesecret=",\n',
        )
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            rc = scanner.main([file_path])
        self.assertEqual(rc, 0)
        self.assertIn("ok:", out.getvalue())

    # ------------------------------------------------------- real tree --------
    def test_shipping_sources_pass_the_scan(self):
        findings = scanner.scan_targets([SOURCE_DIR], root=ROOT)
        self.assertEqual(findings, [], f"unexpected findings: {findings}")

    def test_device_query_string_protection_is_preserved(self):
        policy = os.path.join(SOURCE_DIR, "GPSLabPortalPolicy.c")
        with open(policy, "r", encoding="utf-8") as handle:
            contents = handle.read()
        # The blocker token must still exist, and that same file must pass.
        self.assertIn('"devicesecret="', contents)
        self.assertEqual(scanner.scan_targets([policy], root=ROOT), [])

    def test_keychain_device_secret_source_passes(self):
        store = os.path.join(SOURCE_DIR, "GPSLabSecureStore.m")
        with open(store, "r", encoding="utf-8") as handle:
            contents = handle.read()
        self.assertIn("deviceSecret", contents)
        self.assertEqual(scanner.scan_targets([store], root=ROOT), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
