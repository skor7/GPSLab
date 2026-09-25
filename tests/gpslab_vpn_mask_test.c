/*
 * GPSLab VPNMask integration tests (portable C, source-validated).
 *
 * Executable static assertions for the in-process VPN interface masking port.
 * The runtime rebinding needs dyld + fishhook and cannot run here, so this test
 * reads the production source and pins the exact provenance/structure/ordering:
 *
 *   * the port preserves the standalone VPNMask semantics (tun/utun/ppp/tap/
 *     ipsec filtered, original returned first, return code unchanged);
 *   * the shared Source/fishhook.{c,h} is reused: there is exactly one fishhook
 *     implementation in the build (no duplicate symbols, no second copy);
 *   * the hook is NOT a dylib constructor: it is installed explicitly, exactly
 *     once (dispatch_once), after the persisted state is available;
 *   * the toggle defaults to Disabled, is persisted immediately under a single
 *     protected key, is restored at next launch, and is pushed to the hook's
 *     lock-free gate; the hook itself never reads NSUserDefaults on its hot path;
 *   * the UI exposes a VPN section whose switch auto-saves (no Save button).
 *
 * Build/run (from the repository root):
 *   cc -I Source tests/gpslab_vpn_mask_test.c -o /tmp/gpslab_vpn_mask_test
 *   /tmp/gpslab_vpn_mask_test
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
    return haystack != NULL && needle != NULL && strstr(haystack, needle) != NULL;
}

static int not_contains(const char *haystack, const char *needle) {
    return haystack != NULL && needle != NULL && strstr(haystack, needle) == NULL;
}

static long index_of(const char *haystack, const char *needle) {
    if (haystack == NULL || needle == NULL) {
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

/** Counts non-comment lines that contain `needle` (Makefile entry counting). */
static int count_concrete_lines(const char *haystack, const char *needle) {
    if (haystack == NULL || needle == NULL) {
        return 0;
    }
    int count = 0;
    const char *cursor = haystack;
    while (cursor != NULL && *cursor != '\0') {
        const char *eol = strchr(cursor, '\n');
        size_t length = eol ? (size_t)(eol - cursor) : strlen(cursor);
        char *line = (char *)malloc(length + 1);
        if (line != NULL) {
            memcpy(line, cursor, length);
            line[length] = '\0';
            const char *trimmed = line;
            while (*trimmed == ' ' || *trimmed == '\t') {
                trimmed++;
            }
            if (trimmed[0] != '#' && strstr(line, needle) != NULL) {
                count++;
            }
            free(line);
        }
        if (eol == NULL) {
            break;
        }
        cursor = eol + 1;
    }
    return count;
}

/** Extracts a C/ObjC function body `{ ... }` starting at `signature`. Caller frees. */
static char *extract_body(const char *source, const char *signature) {
    const char *start = strstr(source, signature);
    if (start == NULL) {
        return NULL;
    }
    const char *brace = strchr(start, '{');
    if (brace == NULL) {
        return NULL;
    }
    int depth = 0;
    const char *cursor = brace;
    while (*cursor != '\0') {
        if (*cursor == '{') {
            depth++;
        } else if (*cursor == '}') {
            depth--;
            if (depth == 0) {
                break;
            }
        }
        cursor++;
    }
    size_t length = (size_t)(cursor - brace) + 1;
    char *body = (char *)malloc(length + 1);
    if (body == NULL) {
        return NULL;
    }
    memcpy(body, brace, length);
    body[length] = '\0';
    return body;
}

/* -------------------------------------------------- Preserved standalone logic */

static void test_preserved_semantics(const char *impl) {
    CHECK(contains(impl, "static int GPSLabFilteredGetifaddrs(struct ifaddrs **ifap)"),
          "the filtered getifaddrs port is present");
    CHECK(contains(impl, "strncmp(name, \"tun\", 3)") &&
              contains(impl, "strncmp(name, \"utun\", 4)") &&
              contains(impl, "strncmp(name, \"ppp\", 3)") &&
              contains(impl, "strncmp(name, \"tap\", 3)") &&
              contains(impl, "strncmp(name, \"ipsec\", 5)"),
          "all five standalone interface prefixes are filtered");

    CHECK(contains(impl, "int ret = gGPSLabOriginalGetifaddrs(ifap);"),
          "the captured original is called first");
    CHECK(contains(impl, "if (ret != 0 || ifap == NULL || *ifap == NULL)"),
          "a failure/NULL/empty list is forwarded unchanged");
    CHECK(contains(impl, "*ifap = curr->ifa_next;") &&
              contains(impl, "prev->ifa_next = curr->ifa_next;"),
          "head and middle nodes are unlinked exactly as the standalone source");
    CHECK(contains(impl, "return ret;"), "the original return code is preserved");
}

/* ------------------------------------------------------ Gate + init ordering */

static void test_default_disabled_and_gate(const char *impl) {
    // Default is Disabled (safe pass-through) and the gate lives in an atomic.
    CHECK(contains(impl, "static atomic_bool gGPSLabVPNMaskEnabled = false;"),
          "the runtime gate defaults to Disabled");
    CHECK(contains(impl, "atomic_load_explicit(&gGPSLabVPNMaskEnabled, memory_order_relaxed)"),
          "the hook reads the gate with a lock-free atomic load");
    CHECK(contains(impl, "atomic_store_explicit(&gGPSLabVPNMaskEnabled"),
          "the toggle writes the gate with a lock-free atomic store");

    // Disabled => forward straight to the original (no filtering, no cache).
    char *gate = extract_body(impl, "static int GPSLabFilteredGetifaddrs");
    CHECK(gate != NULL, "the filtered function body is present");
    if (gate != NULL) {
        CHECK(appears_before(gate, "!atomic_load_explicit(&gGPSLabVPNMaskEnabled",
                             "int ret = gGPSLabOriginalGetifaddrs(ifap);"),
              "the Disabled pass-through precedes any filtering");
        CHECK(contains(gate, "return gGPSLabOriginalGetifaddrs(ifap);"),
              "Disable forwards to the captured original");
        free(gate);
    }

    // The original is captured once; a missing capture fails safe (no recursion).
    CHECK(contains(impl, "if (gGPSLabOriginalGetifaddrs == NULL)"),
          "a missing captured original is handled without recursing");
    CHECK(contains(impl, "return -1;"), "the missing-original path reports failure");
}

static void test_explicit_idempotent_install(const char *impl) {
    CHECK(not_contains(impl, "__attribute__((constructor))"),
          "the hook is not a dylib constructor (install order is explicit)");
    CHECK(contains(impl, "dispatch_once(&onceToken"), "the install is exactly-once");
    CHECK(contains(impl, "[self setRuntimeEnabled:[GPSLabSimulationRegistry isVPNEnabled]];"),
          "the gate is seeded from the persisted preference");
    CHECK(appears_before(impl, "[self setRuntimeEnabled:[GPSLabSimulationRegistry isVPNEnabled]];",
                         "rebind_symbols(rebindings"),
          "the gate is seeded BEFORE the rebinding is installed");
    CHECK(contains(impl, "{\"getifaddrs\", (void *)GPSLabFilteredGetifaddrs, (void **)&gGPSLabOriginalGetifaddrs}"),
          "only getifaddrs is rebound, to the filtered port");
    CHECK(contains(impl, "rebind_symbols(rebindings, sizeof(rebindings) / sizeof(struct rebinding))"),
          "the shared fishhook rebind_symbols is reused");
}

/* --------------------------------------------------- No duplicate fishhook */

static void test_single_fishhook(const char *impl, const char *makefile) {
    CHECK(contains(impl, "#import \"fishhook.h\""),
          "the port imports the shared fishhook header");
    CHECK(count_concrete_lines(makefile, "Source/fishhook.c") == 1,
          "exactly one fishhook implementation is compiled (no duplicate symbols)");
    CHECK(not_contains(makefile, "Source/VPNMask/fishhook"),
          "the port does not vendor a second fishhook copy");
}

/* ---------------------------------------- Non-compiled provenance copies */

static void test_reference_copies(const char *makefile) {
    char *refM = read_file("Source/VPNMask/reference/VPNMask.m");
    char *refC = read_file("Source/VPNMask/reference/fishhook.c");
    char *refH = read_file("Source/VPNMask/reference/fishhook.h");
    CHECK(refM != NULL, "the standalone VPNMask.m reference copy is present");
    CHECK(refC != NULL, "the standalone fishhook.c reference copy is present");
    CHECK(refH != NULL, "the standalone fishhook.h reference copy is present");
    if (refM != NULL) {
        CHECK(contains(refM, "__attribute__((constructor))"),
              "the reference VPNMask.m is the unmodified standalone original");
        free(refM);
    }
    if (refC != NULL) {
        free(refC);
    }
    if (refH != NULL) {
        free(refH);
    }
    CHECK(not_contains(makefile, "Source/VPNMask/VPNMask.m"),
          "the reference VPNMask.m is never compiled");
    CHECK(not_contains(makefile, "Source/VPNMask/fishhook.c"),
          "the reference fishhook.c is never compiled");
    CHECK(not_contains(makefile, "VPNMask/reference"),
          "the reference directory is never compiled");
}

/* ------------------------------------ Registry persistence + runtime push */

static void test_registry_wiring(const char *registry_h, const char *registry_m,
                                 const char *manifest, const char *init) {
    CHECK(contains(registry_h, "+ (BOOL)isVPNEnabled;"), "the registry exposes isVPNEnabled");
    CHECK(contains(registry_h, "+ (void)setVPNEnabled:(BOOL)enabled;"),
          "the registry exposes setVPNEnabled:");

    CHECK(contains(registry_m, "#define kGPSLabVPNMaskEnabledKey GPSLAB_PROTECTED_STRING(VPNMaskSimulationKey)"),
          "the registry persists under the protected VPN key");
    CHECK(contains(registry_m, "setBool:enabled forKey:kGPSLabVPNMaskEnabledKey"),
          "the toggle writes the exact persisted key");
    CHECK(contains(registry_m, "+ (void)setVPNEnabled:(BOOL)enabled {"),
          "setVPNEnabled: is defined");
    CHECK(contains(registry_m, "NSClassFromString(@\"GPSLabVPNMaskHook\")"),
          "the runtime push reaches the hook through the ObjC runtime");
    CHECK(contains(registry_m, "NSSelectorFromString(@\"setRuntimeEnabled:\")"),
          "the registry refreshes the hook gate on every change");
    CHECK(contains(registry_m, "NSSelectorFromString(@\"installHooks\")"),
          "the registry installs the hook through the shared selector");

    CHECK(contains(manifest, "GPSLAB_STRING(VPNMaskSimulationKey, \"GPSLab.simulation.vpn.enabled\")"),
          "the manifest defines the exact VPN key");

    // Init order: the persisted state is loaded before hooks install, and the
    // Keychain hook is installed first (fixed, auditable order).
    CHECK(appears_before(init, "loadPersistedConfiguration", "installRuntimeHooks"),
          "the persisted state is loaded before runtime hooks install");
    CHECK(appears_before(init, "GPSLabKeychainCompatInstall()", "installRuntimeHooks"),
          "the VPN hook installs after the Keychain compatibility hook");
}

/* ----------------------------------------------------------- UI auto-save */

static void test_ui_wiring(const char *settings, const char *overlay) {
    char *changed = extract_body(settings, "- (void)simulationSwitchChanged {");
    CHECK(changed != NULL, "the VPN-enabled switch handler is present");
    if (changed != NULL) {
        CHECK(contains(changed, "[GPSLabSimulationRegistry setVPNEnabled:self.simulationSwitch.on]"),
              "the VPN switch auto-saves on change (no Save)");
        free(changed);
    }

    char *enabled = extract_body(settings, "- (BOOL)simulationEnabledForCurrentKind {");
    CHECK(enabled != NULL, "the settings sheet resolves the current kind's state");
    if (enabled != NULL) {
        CHECK(contains(enabled, "isVPNEnabled"), "the VPN sheet reads the persisted state");
        free(enabled);
    }

    CHECK(contains(settings, "self.kind != GPSLabSimulationKindVPN"),
          "VPN shows no Save button (the toggle persists itself)");
    CHECK(contains(settings, "GPSLabSimulationKindVPN"), "the settings sheet knows the VPN kind");
    CHECK(contains(overlay, "vpnSettingsTapped"), "the overlay exposes the VPN settings action");
    CHECK(contains(overlay, "GPSLabSimulationKindVPN"), "the overlay opens the VPN section");
    CHECK(contains(overlay, "sim.vpn.title"), "the overlay renders the VPN row");
}

/* ------------------------------------------------------------ Isolation */

static void test_isolation(const char *impl, const char *registry_m) {
    // The VPN port is independent of the other process-wide hooks: it neither
    // touches Security.framework symbols nor the engine/license state.
    CHECK(not_contains(impl, "SecItem"), "the VPN hook does not touch the Keychain symbols");
    CHECK(not_contains(impl, "GPSLabEngine"), "the VPN hook is not gated by the engine");
    CHECK(not_contains(impl, "GPSLabLicenseManager"), "the VPN hook is not gated by the license");
    // The hot path must not read NSUserDefaults (which could re-enter getifaddrs).
    char *gate = extract_body(impl, "static int GPSLabFilteredGetifaddrs");
    CHECK(gate != NULL && not_contains(gate, "NSUserDefaults"),
          "the hook hot path never reads NSUserDefaults");
    if (gate != NULL) {
        free(gate);
    }
    (void)registry_m;
}

int main(void) {
    const char *hook_h_path = "Source/VPNMask/GPSLabVPNMaskHook.h";
    const char *hook_m_path = "Source/VPNMask/GPSLabVPNMaskHook.m";
    const char *registry_h_path = "Source/GPSLabSimulationRegistry.h";
    const char *registry_m_path = "Source/GPSLabSimulationRegistry.m";
    const char *settings_path = "Source/GPSLabSimulationSettingsViewController.m";
    const char *overlay_path = "Source/GPSLabOverlayViewController.m";
    const char *manifest_path = "Source/GPSLabProtectedStrings.def";
    const char *init_path = "Source/dylib_init.m";
    const char *makefile_path = "Makefile";

    char *hook_h = read_file(hook_h_path);
    char *hook_m = read_file(hook_m_path);
    char *registry_h = read_file(registry_h_path);
    char *registry_m = read_file(registry_m_path);
    char *settings = read_file(settings_path);
    char *overlay = read_file(overlay_path);
    char *manifest = read_file(manifest_path);
    char *init = read_file(init_path);
    char *makefile = read_file(makefile_path);

    if (hook_h == NULL || hook_m == NULL || registry_h == NULL || registry_m == NULL ||
        settings == NULL || overlay == NULL || manifest == NULL || init == NULL ||
        makefile == NULL) {
        fprintf(stderr, "FAIL: cannot read one or more sources (run from the repository root)\n");
        free(hook_h); free(hook_m); free(registry_h); free(registry_m); free(settings);
        free(overlay); free(manifest); free(init); free(makefile);
        return 1;
    }

    CHECK(contains(hook_h, "@interface GPSLabVPNMaskHook : NSObject"),
          "the hook is namespaced under the GPSLab prefix");
    CHECK(contains(hook_h, "+ (BOOL)installHooks;"), "the hook exposes installHooks");
    CHECK(contains(hook_h, "+ (void)setRuntimeEnabled:(BOOL)enabled;"),
          "the hook exposes the runtime gate setter");

    test_preserved_semantics(hook_m);
    test_default_disabled_and_gate(hook_m);
    test_explicit_idempotent_install(hook_m);
    test_single_fishhook(hook_m, makefile);
    test_reference_copies(makefile);
    test_registry_wiring(registry_h, registry_m, manifest, init);
    test_ui_wiring(settings, overlay);
    test_isolation(hook_m, registry_m);

    free(hook_h); free(hook_m); free(registry_h); free(registry_m); free(settings);
    free(overlay); free(manifest); free(init); free(makefile);

    if (gFailures != 0) {
        fprintf(stderr, "%d/%d VPNMask integration checks failed\n", gFailures, gChecks);
        return 1;
    }
    printf("ok: %d VPNMask integration checks passed\n", gChecks);
    return 0;
}
