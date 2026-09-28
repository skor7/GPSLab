#!/usr/bin/env python3
"""Static contract tests for the KeychainFix release-only hardening.

These run on any host (no Mach-O toolchain) and assert the safety invariants the
release pipeline depends on:

  * the release script consumes an existing VERIFIED binary by process-copying
    it (never a source rebuild) and never modifies the input;
  * the optional SHA-256 identity pin is checked before copying the input;
  * the isolated workflow is private-only, never downloads from a public URL,
    forwards an optional identity pin, and does not rebuild KeychainFix;
  * no anti-debug / bypass / instrumentation / packer / self-modifying logic is
    introduced anywhere in the pipeline.

Run:  python3 tests/test_keychainfix_release.py
"""

import os
import re
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT_PATH = os.path.join(REPO_ROOT, "scripts", "keychainfix_release.sh")
WORKFLOW_PATH = os.path.join(REPO_ROOT, ".github", "workflows", "keychainfix-release.yml")
BUILD_WORKFLOW_PATH = os.path.join(REPO_ROOT, ".github", "workflows", "build.yml")

def read(path):
    with open(path, "r", encoding="utf-8") as handle:
        return handle.read()


def code_without_comments(text):
    """Strip `#` comments (this pipeline has no `#` inside a quoted string)."""
    return "\n".join(line.split("#", 1)[0] for line in text.splitlines())


class KeychainFixReleaseScriptTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.raw = read(SCRIPT_PATH)
        cls.code = code_without_comments(cls.raw)

    def test_exists_and_is_strict(self):
        self.assertEqual(self.code.count("set -euo pipefail"), 1)

    def test_process_copies_input_never_rebuilds(self):
        # The input is copied and only the copy is touched.
        self.assertIn('cp "$INPUT" "$OUTPUT"', self.code)
        self.assertNotIn("xcrun clang", self.code)
        self.assertNotIn("git clone", self.code)

    def test_never_reads_the_sibling_builder_repo_or_source(self):
        self.assertNotIn("KeychainFix-Builder", self.code)
        self.assertNotIn("KeychainFix.m", self.code)
        self.assertNotIn("fishhook", self.code)

    def test_strip_is_macho_safe_and_macos_only(self):
        self.assertIn("xcrun strip -x -S", self.code)
        self.assertIn('uname -s', self.code)
        self.assertIn("Darwin", self.code)

    def test_fails_closed_and_deletes_partial_output(self):
        self.assertIn("trap cleanup EXIT", self.code)
        self.assertIn("OUTPUT_CREATED=1", self.code)
        # cleanup removes the output only when the run failed after creating it.
        self.assertRegex(self.code, r"status.*-ne 0.*\n.*rm -f \"\$OUTPUT\"")

    def test_output_can_never_alias_input(self):
        self.assertIn("OUTPUT_CANON", self.code)
        self.assertIn("INPUT_CANON", self.code)
        self.assertRegex(self.code, r'\[\[\s*"\$OUTPUT_CANON"\s*!=\s*"\$INPUT_CANON"\s*\]\]')

    def test_identity_gate_is_fail_closed(self):
        for token in (
            '"$IN_ARCH" == "arm64"',
            '"$IN_INSTALL" == "KeychainFix.dylib"',
            '"$IN_DWARF" == "false"',
            '"$IN_STAB" == "0"',
            "REQUIRED_SYMBOLS",
            "REQUIRED_DEP_SUFFIXES",
            "--expect-sha256",
        ):
            self.assertIn(token, self.code)
        # A code-signed input is refused unless explicitly allowed.
        self.assertIn("--allow-invalidate-signature", self.code)

    def test_optional_hash_pin_is_checked_before_copy(self):
        self.assertIn('if [[ -n "$EXPECT_SHA256" ]]; then', self.code)
        self.assertIn('[[ "$IN_SHA_LC" == "$EXPECT_SHA_LC" ]]', self.code)
        gate = self.code.index('[[ "$IN_SHA_LC" == "$EXPECT_SHA_LC" ]]')
        strip = self.code.index('cp "$INPUT" "$OUTPUT"')
        self.assertLess(gate, strip)

    def test_no_instrumentation_or_bypass_logic(self):
        forbidden = (
            "ptrace",
            "PT_DENY_ATTACH",
            "substrate",
            "ellekit",
            "libhooker",
            "mshook",
            "cydia",
            "dlopen",
            "vm_protect",
            "mach_vm",
            "antidebug",
            "anti-debug",
            "bypass",
            "packer",
            "self-modif",
        )
        lowered = self.code.lower()
        for token in forbidden:
            self.assertNotIn(token, lowered, "forbidden construct in release script: %s" % token)


class KeychainFixReleaseWorkflowTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.raw = read(WORKFLOW_PATH)
        cls.code = code_without_comments(cls.raw)

    def test_private_only_guard(self):
        self.assertIn("github.event.repository.private != true", self.code)
        self.assertIn("Refuse to publish from a public repository", self.code)

    def test_no_public_download_url(self):
        self.assertNotRegex(self.code, r"https?://")

    def test_optional_identity_pin_is_forwarded(self):
        pin_input = self.code.split("expect_sha256:", 1)[1].split("allow_invalidate_signature:", 1)[0]
        self.assertIn("default: ''", pin_input)
        self.assertIn('if [[ -n "${{ inputs.expect_sha256 }}" ]]; then', self.code)
        self.assertIn('args+=( --expect-sha256 "${{ inputs.expect_sha256 }}" )', self.code)

    def test_never_rebuilds_keychainfix(self):
        for token in ("xcrun clang", "git clone", "fishhook", "KeychainFix.m"):
            self.assertNotIn(token, self.code)

    def test_never_downloads_from_a_public_file_host(self):
        self.assertNotIn("curl ", self.code)
        self.assertNotIn("wget ", self.code)

    def test_blocks_without_input_instead_of_failing(self):
        self.assertIn("BLOCKED_BY_MISSING_INPUT", self.code)

    def test_produces_the_expected_artifacts(self):
        self.assertIn("KeychainFix-production-dylib", self.code)
        self.assertIn("KeychainFix-Release.dylib", self.code)
        self.assertIn("KeychainFix-production-report.json", self.code)

    def test_no_instrumentation_or_bypass_logic(self):
        lowered = self.code.lower()
        for token in ("ptrace", "substrate", "ellekit", "libhooker", "cydia", "dlopen"):
            self.assertNotIn(token, lowered)


class BuildWorkflowWiringTest(unittest.TestCase):
    def test_static_job_runs_the_release_script_self_check(self):
        code = read(BUILD_WORKFLOW_PATH)
        self.assertIn("scripts/keychainfix_release.sh --self-check", code)


if __name__ == "__main__":
    unittest.main(verbosity=2)
