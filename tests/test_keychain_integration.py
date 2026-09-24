#!/usr/bin/env python3
"""Static integration tests for the in-process KeychainFix port.

These run on any host (no iOS toolchain) and prove, structurally, that the
integrated Keychain access-group hook is a faithful port of the operator's
on-device-verified standalone KeychainFix and that it participates in the SAME
production hardening as every other source:

  * structural equivalence: the five shared hook functions are token-for-token
    identical to the verified builder's ``KeychainFix.m`` hook bodies, and the
    rebinding table maps exactly the same four Security.framework symbols;
  * hardening participation: the single Makefile compiles both new sources and
    applies the mode flags (hidden visibility / strip / protected-string switch)
    with NO per-file exemption;
  * literal policy: the runtime-required ``SecItem*`` symbol names and
    ``kSecAttrAccessGroup`` stay intact and are deliberately NOT routed through
    the protected-string facility (protecting a runtime symbol name would change
    behaviour); the port introduces no eligible client literal to protect.

The canonical hook fixture below is the exact, comment-free hook logic from the
verified builder (``KeychainFix-Builder/KeychainFix.m``). On an authorized host,
set ``GPSLAB_KEYCHAINFIX_BUILDER_SRC`` to that file to additionally compare
against the live source; in CI the pinned fixture is used.

Run:  python3 tests/test_keychain_integration.py
"""

import hashlib
import os
import re
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(REPO_ROOT, "Source")
COMPAT_M = os.path.join(SOURCE, "GPSLabKeychainCompat.m")
COMPAT_H = os.path.join(SOURCE, "GPSLabKeychainCompat.h")
FISHHOOK_H = os.path.join(SOURCE, "fishhook.h")
MAKEFILE = os.path.join(REPO_ROOT, "Makefile")
MODE_MK = os.path.join(REPO_ROOT, "scripts", "build_mode.mk")
MANIFEST = os.path.join(SOURCE, "GPSLabProtectedStrings.def")

# The four runtime symbol names fishhook must resolve by exact name, plus the
# Security.framework constant the cleaner strips. These MUST remain intact.
RUNTIME_SYMBOLS = (
    "SecItemCopyMatching",
    "SecItemAdd",
    "SecItemUpdate",
    "SecItemDelete",
)
SHARED_FUNCTIONS = (
    "clean_keychain_query",
    "my_SecItemCopyMatching",
    "my_SecItemAdd",
    "my_SecItemUpdate",
    "my_SecItemDelete",
)

# Exact hook logic of the verified builder (KeychainFix-Builder/KeychainFix.m),
# comments removed. This is the canonical form the integrated port must match.
CANONICAL_BUILDER_HOOK = r"""
static OSStatus (*orig_SecItemCopyMatching)(CFDictionaryRef query, CFTypeRef *result);
static OSStatus (*orig_SecItemAdd)(CFDictionaryRef attributes, CFTypeRef *result);
static OSStatus (*orig_SecItemUpdate)(CFDictionaryRef query, CFDictionaryRef attributesToUpdate);
static OSStatus (*orig_SecItemDelete)(CFDictionaryRef query);

static CFDictionaryRef clean_keychain_query(CFDictionaryRef dict) {
    if (!dict) return NULL;

    NSDictionary *nsDict = (__bridge NSDictionary *)dict;
    if (nsDict[(__bridge id)kSecAttrAccessGroup]) {
        NSMutableDictionary *mutableDict = [nsDict mutableCopy];
        [mutableDict removeObjectForKey:(__bridge id)kSecAttrAccessGroup];
        return CFBridgingRetain(mutableDict);
    }
    return (CFDictionaryRef)CFRetain(dict);
}

static OSStatus my_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    CFDictionaryRef cleaned = clean_keychain_query(query);
    OSStatus status = orig_SecItemCopyMatching(cleaned ? cleaned : query, result);
    if (cleaned) CFRelease(cleaned);
    return status;
}

static OSStatus my_SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    CFDictionaryRef cleaned = clean_keychain_query(attributes);
    OSStatus status = orig_SecItemAdd(cleaned ? cleaned : attributes, result);
    if (cleaned) CFRelease(cleaned);
    return status;
}

static OSStatus my_SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) {
    CFDictionaryRef cleanQuery = clean_keychain_query(query);
    CFDictionaryRef cleanAttrs = clean_keychain_query(attributesToUpdate);

    OSStatus status = orig_SecItemUpdate(cleanQuery ? cleanQuery : query,
                                         cleanAttrs ? cleanAttrs : attributesToUpdate);

    if (cleanQuery) CFRelease(cleanQuery);
    if (cleanAttrs) CFRelease(cleanAttrs);
    return status;
}

static OSStatus my_SecItemDelete(CFDictionaryRef query) {
    CFDictionaryRef cleaned = clean_keychain_query(query);
    OSStatus status = orig_SecItemDelete(cleaned ? cleaned : query);
    if (cleaned) CFRelease(cleaned);
    return status;
}

struct rebinding rebindings[] = {
    {"SecItemCopyMatching", (void *)my_SecItemCopyMatching, (void **)&orig_SecItemCopyMatching},
    {"SecItemAdd", (void *)my_SecItemAdd, (void **)&orig_SecItemAdd},
    {"SecItemUpdate", (void *)my_SecItemUpdate, (void **)&orig_SecItemUpdate},
    {"SecItemDelete", (void *)my_SecItemDelete, (void **)&orig_SecItemDelete}
};
"""


def read(path):
    with open(path, "r", encoding="utf-8") as handle:
        return handle.read()


def strip_comments(text):
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    return re.sub(r"//[^\n]*", " ", text)


def extract_function(text, name):
    """Return (signature, body) of `name` from comment-stripped source."""
    text = strip_comments(text)
    match = re.search(r"\b" + re.escape(name) + r"\s*\(", text)
    if match is None:
        return None
    open_paren = text.index("(", match.end() - 1)
    depth = 0
    cursor = open_paren
    while cursor < len(text):
        if text[cursor] == "(":
            depth += 1
        elif text[cursor] == ")":
            depth -= 1
            if depth == 0:
                break
        cursor += 1
    brace = text.index("{", cursor)
    depth = 0
    end = brace
    while end < len(text):
        if text[end] == "{":
            depth += 1
        elif text[end] == "}":
            depth -= 1
            if depth == 0:
                break
        end += 1
    signature = re.sub(r"\s+", " ", text[match.start():cursor + 1]).strip()
    body = text[brace:end + 1]
    return signature, body


def tokenize(text):
    """Whitespace-insensitive token stream (identifiers, numbers, punctuation)."""
    return " ".join(t for t in re.findall(r"[A-Za-z_][A-Za-z0-9_]*|\d+|.", text) if not t.isspace())


def normalized_function(text, name):
    found = extract_function(text, name)
    if found is None:
        return None
    signature, body = found
    return tokenize(signature), tokenize(body)


def original_pointer_declarations(text):
    declarations = re.findall(r"static OSStatus \(\*orig_SecItem\w+\)\([^;]*\);", strip_comments(text))
    return [re.sub(r"\s+", " ", d).strip() for d in declarations]


def rebinding_entries(text):
    entries = re.findall(r'\{\s*"(SecItem\w+)"\s*,\s*\(void \*\)(my_SecItem\w+)\s*,\s*'
                         r'\(void \*\*\)&(orig_SecItem\w+)\s*\}', strip_comments(text))
    return sorted(entries)


class KeychainHookSemanticEquivalenceTest(unittest.TestCase):
    """The port must be structurally identical to the verified builder hook."""

    @classmethod
    def setUpClass(cls):
        cls.compat = read(COMPAT_M)

    def test_shared_functions_match_verified_builder(self):
        for name in SHARED_FUNCTIONS:
            expected = normalized_function(CANONICAL_BUILDER_HOOK, name)
            actual = normalized_function(self.compat, name)
            self.assertIsNotNone(expected, "fixture is missing %s" % name)
            self.assertIsNotNone(actual, "port is missing %s" % name)
            self.assertEqual(actual[0], expected[0], "%s signature differs from the verified builder" % name)
            self.assertEqual(actual[1], expected[1], "%s body differs from the verified builder" % name)

    def test_original_pointer_declarations_match(self):
        expected = original_pointer_declarations(CANONICAL_BUILDER_HOOK)
        actual = original_pointer_declarations(self.compat)
        self.assertEqual(actual, expected,
                         "captured original-pointer declarations differ from the verified builder")

    def test_rebinding_table_maps_the_same_four_symbols(self):
        expected = rebinding_entries(CANONICAL_BUILDER_HOOK)
        actual = rebinding_entries(self.compat)
        self.assertEqual(actual, expected,
                         "the rebinding table differs from the verified builder")
        self.assertEqual(len(actual), 4, "exactly the four SecItem* symbols must be rebound")

    def test_matches_live_builder_source_when_provided(self):
        live = os.environ.get("GPSLAB_KEYCHAINFIX_BUILDER_SRC")
        if not live:
            self.skipTest("GPSLAB_KEYCHAINFIX_BUILDER_SRC not set (pinned fixture used instead)")
        self.assertTrue(os.path.isfile(live), "builder source not found: %s" % live)
        builder = read(live)
        for name in SHARED_FUNCTIONS:
            self.assertEqual(normalized_function(self.compat, name),
                             normalized_function(builder, name),
                             "%s differs from the live verified builder source" % name)
        self.assertEqual(rebinding_entries(self.compat), rebinding_entries(builder))


class VendoredFishhookProvenanceTest(unittest.TestCase):
    """The vendored fishhook must remain the verified upstream snapshot."""

    # SHA-256 of the verified vendored snapshot, identical to the sibling
    # KeychainFix-Builder's fishhook.{c,h} (line endings normalized to LF).
    FISHHOOK_C_SHA256 = "48f51e1a36d9013501381fdf31a3e9c838938ebf8bb39e0e3a7ac119aa59b61b"
    FISHHOOK_H_SHA256 = "5432b81bd302956adcbfc8836af74e47dd38748d5078495cbe1b5bea62180120"

    def _sha256(self, path):
        with open(path, "rb") as handle:
            data = handle.read().replace(b"\r\n", b"\n")
        return hashlib.sha256(data).hexdigest()

    def test_fishhook_impl_matches_verified_snapshot(self):
        self.assertEqual(self._sha256(os.path.join(SOURCE, "fishhook.c")),
                         self.FISHHOOK_C_SHA256,
                         "vendored fishhook.c drifted from the verified snapshot")

    def test_fishhook_header_matches_verified_snapshot(self):
        self.assertEqual(self._sha256(os.path.join(SOURCE, "fishhook.h")),
                         self.FISHHOOK_H_SHA256,
                         "vendored fishhook.h drifted from the verified snapshot")


class KeychainHardeningParticipationTest(unittest.TestCase):
    """Both sources are compiled by the single build target and hardened."""

    @classmethod
    def setUpClass(cls):
        cls.makefile = read(MAKEFILE)
        cls.mode_mk = read(MODE_MK)
        cls.compat_h = read(COMPAT_H)
        cls.fishhook_h = read(FISHHOOK_H)

    def test_single_makefile_compiles_both_sources(self):
        self.assertIn("Source/fishhook.c", self.makefile)
        self.assertIn("Source/GPSLabKeychainCompat.m", self.makefile)
        self.assertIn("Security", self.makefile)

    def test_no_per_file_flag_exemption(self):
        # Theos applies per-file flags via `$($(<)_CFLAGS)` (the source path is
        # the variable name), so `Source/fishhook.c_CFLAGS` would override the
        # shared mode flags for that one file. Neither new source may do that.
        for token in ("fishhook_CFLAGS", "fishhook_LDFLAGS",
                      "Source/fishhook.c_CFLAGS", "Source/fishhook.c_LDFLAGS",
                      "GPSLabKeychainCompat_CFLAGS", "GPSLabKeychainCompat_LDFLAGS",
                      "Source/GPSLabKeychainCompat.m_CFLAGS",
                      "Source/GPSLabKeychainCompat.m_LDFLAGS"):
            self.assertNotIn(token, self.makefile, "per-file flag exemption found: %s" % token)
        # Visibility must never be forced back to default for these sources.
        self.assertNotIn("-fvisibility=default", self.makefile)
        self.assertNotIn("-fvisibility=default", self.mode_mk)

    def test_mode_flags_are_applied_globally(self):
        self.assertIn("$(GPSLAB_MODE_CFLAGS)", self.makefile)
        self.assertIn("$(GPSLAB_MODE_LDFLAGS)", self.makefile)

    def test_production_flags_are_complete_and_global(self):
        for flag in ("-fvisibility=hidden", "-fno-ident", "-g0", "-DNDEBUG",
                     "-DGPSLAB_PRODUCTION=1"):
            self.assertIn(flag, self.mode_mk, "production CFLAG missing: %s" % flag)
        for flag in ("-Wl,-x", "-Wl,-S"):
            self.assertIn(flag, self.mode_mk, "production LDFLAG missing: %s" % flag)
        # The production block must not special-case the keychain sources.
        production_block = self.mode_mk.split("PRODUCTION", 1)[1]
        for name in ("fishhook", "GPSLabKeychainCompat"):
            self.assertNotIn(name, production_block,
                             "the production mode must not exempt %s" % name)

    def test_apis_are_hidden(self):
        self.assertIn('__attribute__((visibility("hidden")))', self.compat_h)
        self.assertIn('FISHHOOK_VISIBILITY __attribute__((visibility("hidden")))', self.fishhook_h)


class KeychainLiteralPolicyTest(unittest.TestCase):
    """Runtime-required literals stay intact and out of the protected manifest."""

    @classmethod
    def setUpClass(cls):
        cls.compat = read(COMPAT_M)
        cls.manifest = read(MANIFEST)

    def test_runtime_symbol_names_remain_exact_literals(self):
        for symbol in RUNTIME_SYMBOLS:
            self.assertIn('"%s"' % symbol, self.compat,
                          "runtime-required symbol name was altered: %s" % symbol)
        self.assertIn("kSecAttrAccessGroup", self.compat)

    def test_runtime_literals_are_never_protected(self):
        for symbol in RUNTIME_SYMBOLS:
            self.assertNotIn(symbol, self.manifest,
                             "a runtime symbol name must not be protected: %s" % symbol)
        self.assertNotIn("kSecAttrAccessGroup", self.manifest)
        self.assertNotIn("SecItem", self.manifest)

    def test_port_does_not_use_the_protected_string_facility(self):
        code = strip_comments(self.compat)
        self.assertNotIn("GPSLAB_PROTECTED_STRING", code)
        # The port has no Objective-C string literal, so there is nothing
        # eligible for the protected-string policy.
        self.assertNotIn('@"', code)


class KeychainSingleBuildTargetTest(unittest.TestCase):
    """No alternate build target can silently omit the new sources."""

    SKIP_DIRS = {".git", ".theos", "node_modules", "build", "__pycache__",
                 "scripts/tmp", "GPSLab-dylib"}
    BUILD_FILE_SUFFIXES = (".mk", ".pbxproj", ".xcodeproj", ".xcconfig",
                           ".cmake", ".ninja")
    BUILD_FILE_NAMES = {"Makefile", "makefile", "GNUmakefile", "Package.swift",
                        "CMakeLists.txt"}

    def _build_files(self):
        found = []
        for root, dirs, files in os.walk(REPO_ROOT):
            rel = os.path.relpath(root, REPO_ROOT).replace("\\", "/")
            dirs[:] = [d for d in dirs
                       if d not in self.SKIP_DIRS
                       and not rel.startswith("Mawqie-Web/node_modules")]
            for name in files:
                if name in self.BUILD_FILE_NAMES or name.endswith(self.BUILD_FILE_SUFFIXES):
                    found.append(os.path.relpath(os.path.join(root, name), REPO_ROOT)
                                 .replace("\\", "/"))
        return sorted(found)

    def test_only_the_single_makefile_target_exists(self):
        build_files = self._build_files()
        makefiles = [f for f in build_files if os.path.basename(f) in ("Makefile", "makefile", "GNUmakefile")]
        mode_fragments = [f for f in build_files if f.endswith(".mk")]
        self.assertEqual(makefiles, ["Makefile"], "unexpected Makefile(s): %s" % makefiles)
        self.assertEqual(mode_fragments, ["scripts/build_mode.mk"],
                         "unexpected make fragment(s): %s" % mode_fragments)
        # No project-style build system may exist that could omit the sources.
        for path in build_files:
            self.assertTrue(path in ("Makefile", "scripts/build_mode.mk"),
                            "unexpected alternate build target: %s" % path)

    def test_the_single_target_lists_both_sources(self):
        makefile = read(MAKEFILE)
        files_block = makefile.split("GPSLab_FILES", 1)[1]
        self.assertIn("Source/fishhook.c", files_block)
        self.assertIn("Source/GPSLabKeychainCompat.m", files_block)


if __name__ == "__main__":
    unittest.main(verbosity=2)
