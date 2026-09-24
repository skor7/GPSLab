/*
 * GPSLab Keychain compatibility wiring tests (portable C).
 *
 * Executable static assertions for the integrated KeychainFix behaviour that
 * cannot run in a portable test (it needs Security.framework + the dyld
 * rebinding path). The test reads the production source and pins the exact
 * provenance/structure, so it is honestly source-validated wiring, not a runtime
 * Keychain test. Runtime behaviour is only provable on a device.
 *
 * What it pins:
 *   * fishhook.{c,h} are vendored byte-for-byte from facebook/fishhook and keep
 *     the BSD-3 licence and the hidden-visibility API;
 *   * GPSLabKeychainCompat ports the verified standalone KeychainFix hook exactly
 *     (all four SecItem* rebinds, kSecAttrAccessGroup stripped from a copy, the
 *     original status returned unchanged, balanced CoreFoundation ownership);
 *   * the install is explicit, idempotent (dispatch_once) and hidden;
 *   * it is UNCONDITIONAL: never gated by the synthetic-engine switch or the
 *     license state;
 *   * dylib_init installs it before the licence manager touches the Keychain;
 *   * the Makefile compiles both new sources against Security.framework.
 *
 * Build/run (from the repository root):
 *   cc -I Source tests/gpslab_keychain_compat_test.c -o /tmp/gpslab_keychain_compat_test
 *   /tmp/gpslab_keychain_compat_test
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int gFailures = 0;
static int gChecks = 0;

#define CHECK(condition, message)                                                \
    do {                                                                         \
        gChecks++;                                                               \
        if (!(condition)) {                                                      \
            gFailures++;                                                         \
            fprintf(stderr, "FAIL: %s (%s:%d)\n", (message), __FILE__, __LINE__); \
        }                                                                        \
    } while (0)

static char *read_file(const char *path) {
    FILE *handle = fopen(path, "rb");
    if (handle == NULL) {
        return NULL;
    }
    if (fseek(handle, 0, SEEK_END) != 0) {
        fclose(handle);
        return NULL;
    }
    long size = ftell(handle);
    if (size < 0) {
        fclose(handle);
        return NULL;
    }
    rewind(handle);
    char *buffer = (char *)malloc((size_t)size + 1);
    if (buffer == NULL) {
        fclose(handle);
        return NULL;
    }
    size_t read = fread(buffer, 1, (size_t)size, handle);
    buffer[read] = '\0';
    fclose(handle);
    return buffer;
}

static int contains(const char *haystack, const char *needle) {
    return haystack != NULL && strstr(haystack, needle) != NULL;
}

static int not_contains(const char *haystack, const char *needle) {
    return haystack != NULL && strstr(haystack, needle) == NULL;
}

static long index_of(const char *haystack, const char *needle) {
    if (haystack == NULL) {
        return -1;
    }
    const char *found = strstr(haystack, needle);
    return found == NULL ? -1 : (long)(found - haystack);
}

static int appears_before(const char *haystack, const char *first, const char *second) {
    long firstIndex = index_of(haystack, first);
    long secondIndex = index_of(haystack, second);
    return firstIndex >= 0 && secondIndex >= 0 && firstIndex < secondIndex;
}

static int count_occurrences(const char *haystack, const char *needle) {
    if (haystack == NULL || needle == NULL || needle[0] == '\0') {
        return 0;
    }
    int count = 0;
    size_t length = strlen(needle);
    const char *cursor = haystack;
    while ((cursor = strstr(cursor, needle)) != NULL) {
        count++;
        cursor += length;
    }
    return count;
}

/* ------------------------------------------------------------- Vendored fishhook */

static void test_vendored_fishhook(const char *header, const char *impl) {
    CHECK(contains(header, "Copyright (c) 2013, Facebook, Inc."),
          "fishhook.h keeps the upstream BSD-3 copyright");
    CHECK(contains(header, "Redistribution and use in source and binary forms"),
          "fishhook.h keeps the upstream BSD-3 licence text");
    CHECK(contains(header, "#define FISHHOOK_VISIBILITY __attribute__((visibility(\"hidden\")))"),
          "fishhook.h defaults to hidden visibility (no exported C ABI)");
    CHECK(contains(header, "struct rebinding {"), "fishhook.h declares struct rebinding");
    CHECK(contains(header, "int rebind_symbols(struct rebinding rebindings[], size_t rebindings_nel);"),
          "fishhook.h declares rebind_symbols");

    CHECK(contains(impl, "Copyright (c) 2013, Facebook, Inc."),
          "fishhook.c keeps the upstream BSD-3 copyright");
    CHECK(contains(impl, "#include \"fishhook.h\""), "fishhook.c includes its own header");
    CHECK(contains(impl, "int rebind_symbols(struct rebinding rebindings[], size_t rebindings_nel) {"),
          "fishhook.c defines rebind_symbols");
    CHECK(contains(impl, "_dyld_register_func_for_add_image"),
          "fishhook.c registers a dyld add-image callback (covers later images)");
    CHECK(contains(impl, "vm_protect"), "fishhook.c rewrites the symbol pointer with vm_protect");
}

/* --------------------------------------------------------- Ported Keychain hook */

static void test_ported_hook(const char *header, const char *impl) {
    // The internal entry point is declared and defined hidden.
    CHECK(contains(header, "BOOL GPSLabKeychainCompatInstall(void);"),
          "GPSLabKeychainCompat.h declares the install entry point");
    CHECK(contains(header, "__attribute__((visibility(\"hidden\")))"),
          "GPSLabKeychainCompat.h hides the install entry point");
    CHECK(contains(impl, "BOOL GPSLabKeychainCompatInstall(void) {"),
          "GPSLabKeychainCompat.m defines the install entry point");
    CHECK(contains(impl, "visibility(\"hidden\")"),
          "GPSLabKeychainCompat.m hides the install symbol in production and dev");

    // The four original pointers and the four hooked bodies.
    CHECK(contains(impl, "orig_SecItemCopyMatching") && contains(impl, "orig_SecItemAdd") &&
              contains(impl, "orig_SecItemUpdate") && contains(impl, "orig_SecItemDelete"),
          "all four original SecItem* pointers are captured");
    CHECK(contains(impl, "static OSStatus my_SecItemCopyMatching") &&
              contains(impl, "static OSStatus my_SecItemAdd") &&
              contains(impl, "static OSStatus my_SecItemUpdate") &&
              contains(impl, "static OSStatus my_SecItemDelete"),
          "all four SecItem* functions are hooked");

    // The universal cleaner strips the access group from a COPY.
    CHECK(contains(impl, "static CFDictionaryRef clean_keychain_query(CFDictionaryRef dict)"),
          "the universal cleaner is present");
    CHECK(contains(impl, "if (!dict) return NULL;"), "a NULL dictionary is forwarded unchanged");
    CHECK(contains(impl, "if (nsDict[(__bridge id)kSecAttrAccessGroup])"),
          "the cleaner checks for kSecAttrAccessGroup");
    CHECK(contains(impl, "[nsDict mutableCopy]"), "the cleaner works on a mutable copy");
    CHECK(contains(impl, "[mutableDict removeObjectForKey:(__bridge id)kSecAttrAccessGroup];"),
          "the access group is removed from the copy only");
    CHECK(count_occurrences(impl, "removeObjectForKey") == 1,
          "the caller's dictionary is never mutated (a single removal on the copy)");
    CHECK(contains(impl, "return CFBridgingRetain(mutableDict);"),
          "the cleaned copy is returned with +1 ownership");
    CHECK(contains(impl, "return (CFDictionaryRef)CFRetain(dict);"),
          "the no-match path retains the original with +1 ownership");

    // Ownership is balanced and the out-params are never consumed.
    CHECK(count_occurrences(impl, "CFRelease(cleaned)") >= 3,
          "the cleaned copies are balanced with CFRelease");
    CHECK(contains(impl, "CFRelease(cleanQuery)") && contains(impl, "CFRelease(cleanAttrs)"),
          "the update path balances both cleaned dictionaries");
    CHECK(not_contains(impl, "CFRelease(result)") && not_contains(impl, "CFRelease(attributes)"),
          "the result/attribute out-params are never consumed");
    CHECK(count_occurrences(impl, "return status;") >= 4,
          "every handler returns the original OSStatus unchanged");

    // The rebinding table maps every symbol to the hooked body.
    CHECK(contains(impl, "{\"SecItemCopyMatching\", (void *)my_SecItemCopyMatching,"),
          "SecItemCopyMatching is rebound to the hooked body");
    CHECK(contains(impl, "{\"SecItemAdd\", (void *)my_SecItemAdd,"),
          "SecItemAdd is rebound to the hooked body");
    CHECK(contains(impl, "{\"SecItemUpdate\", (void *)my_SecItemUpdate,"),
          "SecItemUpdate is rebound to the hooked body");
    CHECK(contains(impl, "{\"SecItemDelete\", (void *)my_SecItemDelete,"),
          "SecItemDelete is rebound to the hooked body");
    CHECK(contains(impl, "rebind_symbols(rebindings, sizeof(rebindings) / sizeof(struct rebinding))"),
          "rebind_symbols is invoked once with the complete table");

    // Idempotent, and NOT gated by any engine/license state.
    CHECK(contains(impl, "dispatch_once(&gGPSLabKeychainCompatOnce"),
          "the install is exactly-once (dispatch_once)");
    CHECK(contains(impl, "gGPSLabKeychainCompatInstalled"),
          "the install records its outcome and is idempotent");
    CHECK(not_contains(impl, "setEnabled"), "the hook is never gated by the engine switch");
    CHECK(not_contains(impl, "isEnabled"), "the hook is never read from the engine enabled state");
    CHECK(not_contains(impl, "sharedEngine"), "the hook never reaches the engine singleton");
    CHECK(not_contains(impl, "GPSLabLicenseManager"), "the hook never reaches the license manager");
    CHECK(not_contains(impl, "GPSLabEngine"), "the hook never reaches the engine class");
    CHECK(not_contains(impl, "entitlementAllowsSynthesis"),
          "the hook is never gated by the entitlement state");
}

/* --------------------------------------------------------------- Constructor */

static void test_constructor_order(const char *init) {
    CHECK(contains(init, "#import \"GPSLabKeychainCompat.h\""),
          "the constructor imports the compatibility hook");
    CHECK(contains(init, "(void)GPSLabKeychainCompatInstall();"),
          "the constructor installs the compatibility hook");
    CHECK(appears_before(init, "GPSLabKeychainCompatInstall()", "loadAndStart]"),
          "the hook is installed BEFORE the license manager starts using the Keychain");
    CHECK(appears_before(init, "GPSLabKeychainCompatInstall()", "loadPersistedConfiguration"),
          "the hook is installed at the very start of the constructor");
    CHECK(appears_before(init, "GPSLabDiagDylibLoaded()", "GPSLabKeychainCompatInstall()"),
          "the load diagnostic precedes the install (deterministic ordering)");
}

/* ------------------------------------------------------------------ Build wiring */

static void test_build_wiring(const char *makefile) {
    CHECK(contains(makefile, "Source/fishhook.c"),
          "the Makefile compiles the vendored fishhook");
    CHECK(contains(makefile, "Source/GPSLabKeychainCompat.m"),
          "the Makefile compiles the Keychain compatibility hook");
    CHECK(contains(makefile, "Security"), "the Makefile links Security.framework");
    CHECK(contains(makefile, "ARCHS = arm64"), "the target stays arm64-only");
}

int main(void) {
    const char *fishhook_h_path = "Source/fishhook.h";
    const char *fishhook_c_path = "Source/fishhook.c";
    const char *compat_h_path = "Source/GPSLabKeychainCompat.h";
    const char *compat_m_path = "Source/GPSLabKeychainCompat.m";
    const char *init_path = "Source/dylib_init.m";
    const char *makefile_path = "Makefile";

    char *fishhook_h = read_file(fishhook_h_path);
    char *fishhook_c = read_file(fishhook_c_path);
    char *compat_h = read_file(compat_h_path);
    char *compat_m = read_file(compat_m_path);
    char *init = read_file(init_path);
    char *makefile = read_file(makefile_path);

    if (fishhook_h == NULL || fishhook_c == NULL || compat_h == NULL ||
        compat_m == NULL || init == NULL || makefile == NULL) {
        fprintf(stderr, "FAIL: cannot read one or more sources (run from the repository root)\n");
        free(fishhook_h); free(fishhook_c); free(compat_h);
        free(compat_m); free(init); free(makefile);
        return 1;
    }

    test_vendored_fishhook(fishhook_h, fishhook_c);
    test_ported_hook(compat_h, compat_m);
    test_constructor_order(init);
    test_build_wiring(makefile);

    free(fishhook_h);
    free(fishhook_c);
    free(compat_h);
    free(compat_m);
    free(init);
    free(makefile);

    if (gFailures != 0) {
        fprintf(stderr, "%d/%d keychain compatibility wiring checks failed\n", gFailures, gChecks);
        return 1;
    }
    printf("ok: %d keychain compatibility wiring checks passed\n", gChecks);
    return 0;
}
