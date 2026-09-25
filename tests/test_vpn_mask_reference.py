#!/usr/bin/env python3
"""Static guard for the non-compiled VPNMask provenance copies.

The three original VPNMask-Builder files (VPNMask.m, fishhook.c, fishhook.h) are
kept BYTE-FOR-BYTE under Source/VPNMask/reference/ as READ-ONLY provenance. They
must never be compiled: the build uses the shared Source/fishhook.{c,h} (already
vendored for the Keychain hook) and the namespaced port
Source/VPNMask/GPSLabVPNMaskHook.m.

This guard proves:
  * the reference copies still match the pinned VPNMask-Builder SHA-256, so the
    evidence cannot silently drift;
  * the reference fishhook is byte-identical to the shared compiled fishhook;
  * the Makefile compiles neither the reference VPNMask.m nor the reference
    fishhook.c and lists exactly one fishhook implementation;
  * the namespaced port is the ONLY source compiled under Source/VPNMask/.

Run:  python3 tests/test_vpn_mask_reference.py
"""

import hashlib
import os
import re
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REFERENCE_DIR = os.path.join(REPO_ROOT, "Source", "VPNMask", "reference")
PORT_PATH = os.path.join(REPO_ROOT, "Source", "VPNMask", "GPSLabVPNMaskHook.m")
SHARED_FISHHOOK_C = os.path.join(REPO_ROOT, "Source", "fishhook.c")
SHARED_FISHHOOK_H = os.path.join(REPO_ROOT, "Source", "fishhook.h")
MAKEFILE = os.path.join(REPO_ROOT, "Makefile")

# SHA-256 of the verified standalone VPNMask-Builder sources, LF-normalized so the
# guard is stable across CRLF/LF checkouts. The on-disk VPNMask.m original is
# CRLF (raw SHA-256 2fabd495f4cc811349f31428aede784e7356d6888f031d01cb1e361a26a3e3d4,
# identical to the GPSLab reference copy); its LF-normalized digest is pinned
# below. The two fishhook files are already LF so raw == normalized.
PINNED = {
    "VPNMask.m": "36880c0fde57a09ed4436d94fe54f801586d96e99a115223a6d43ecaf2bb7f88",
    "fishhook.c": "48f51e1a36d9013501381fdf31a3e9c838938ebf8bb39e0e3a7ac119aa59b61b",
    "fishhook.h": "5432b81bd302956adcbfc8836af74e47dd38748d5078495cbe1b5bea62180120",
}


def read(path):
    with open(path, "r", encoding="utf-8") as handle:
        return handle.read()


def sha256(path):
    with open(path, "rb") as handle:
        data = handle.read().replace(b"\r\n", b"\n")
    return hashlib.sha256(data).hexdigest()


class ReferenceCopiesAreUnmodified(unittest.TestCase):
    """The three original bytes are preserved exactly as read-only reference."""

    def test_all_three_copies_exist_and_match_pinned_hashes(self):
        for name, digest in PINNED.items():
            path = os.path.join(REFERENCE_DIR, name)
            self.assertTrue(os.path.isfile(path), "missing reference copy: %s" % name)
            self.assertEqual(sha256(path), digest, "reference copy drifted: %s" % name)

    def test_reference_fishhook_matches_the_shared_compiled_fishhook(self):
        self.assertEqual(sha256(os.path.join(REFERENCE_DIR, "fishhook.c")),
                         sha256(SHARED_FISHHOOK_C),
                         "reference fishhook.c differs from the compiled Source/fishhook.c")
        self.assertEqual(sha256(os.path.join(REFERENCE_DIR, "fishhook.h")),
                         sha256(SHARED_FISHHOOK_H),
                         "reference fishhook.h differs from the compiled Source/fishhook.h")

    def test_reference_vpn_mask_is_the_unmodified_standalone_original(self):
        code = read(os.path.join(REFERENCE_DIR, "VPNMask.m"))
        self.assertIn("__attribute__((constructor))", code,
                      "the reference copy is not the standalone constructor-based original")
        self.assertIn('{"getifaddrs", (void *)my_getifaddrs, (void **)&orig_getifaddrs}', code)


class ReferenceCopiesAreNotCompiled(unittest.TestCase):
    """No reference file enters the build; the port is the only VPNMask source."""

    @classmethod
    def setUpClass(cls):
        cls.makefile = read(MAKEFILE)
        # The file-list/flag lines only (drop `#` comments so paths mentioned in
        # prose never count as build entries).
        cls.concrete = "\n".join(line for line in cls.makefile.splitlines()
                                 if not line.lstrip().startswith("#"))

    def test_reference_vpn_mask_m_is_never_compiled(self):
        self.assertNotIn("Source/VPNMask/VPNMask.m", self.concrete,
                         "the reference VPNMask.m must never be compiled")

    def test_reference_fishhook_is_never_compiled(self):
        self.assertNotIn("Source/VPNMask/fishhook.c", self.concrete,
                         "the reference fishhook.c must never be compiled")
        self.assertNotIn("VPNMask/reference", self.concrete,
                         "the reference directory must never be compiled")

    def test_exactly_one_fishhook_implementation_is_compiled(self):
        self.assertEqual(self.concrete.count("Source/fishhook.c"), 1,
                         "the shared fishhook must be the only implementation compiled")

    def test_the_port_is_the_only_source_compiled_under_vpnmask(self):
        entries = re.findall(r"Source/VPNMask/[A-Za-z0-9_./-]+\.m", self.concrete)
        self.assertEqual(entries, ["Source/VPNMask/GPSLabVPNMaskHook.m"],
                         "only the namespaced port may be compiled under Source/VPNMask/")

    def test_port_file_is_present(self):
        self.assertTrue(os.path.isfile(PORT_PATH), "the namespaced port is missing")


if __name__ == "__main__":
    unittest.main(verbosity=2)
