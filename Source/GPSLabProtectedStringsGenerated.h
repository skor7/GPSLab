//
//  GPSLabProtectedStringsGenerated.h
//  GPSLab
//
//  GENERATED FILE - DO NOT EDIT BY HAND.
//  Source of truth: Source/GPSLabProtectedStrings.def
//  Regenerate:      python3 scripts/gen_protected_strings.py
//  Verified in sync: scripts/audit_protected_strings.sh
//
//  DEV (default): GPSLAB_PROTECTED_STRING(Symbol) expands to the readable
//  plaintext literal, so the dev artifact stays fully readable.
//  PRODUCTION: it expands to a runtime XOR decode of the stored blob, so the
//  plaintext literal never reaches the production compiler.
//
#ifndef GPSLAB_PROTECTED_STRINGS_GENERATED_H
#define GPSLAB_PROTECTED_STRINGS_GENERATED_H

#if defined(GPSLAB_PRODUCTION) && GPSLAB_PRODUCTION

#define GPSLAB_PROTECTED_STRING(symbol) \
    GPSLabProtectedStringDecode(kGPSLabProtected_##symbol, \
                                sizeof(kGPSLabProtected_##symbol), \
                                kGPSLabProtectedKey_##symbol)

#else /* DEV: readable plaintext */

#define GPSLAB_PROTECTED_STRING_DefaultsSuite (@"com.gpslab.runtime")
#define GPSLAB_PROTECTED_STRING_PendingSelectionKey (@"GPSLab.pendingSelection")
#define GPSLAB_PROTECTED_STRING_ConfigurationKey (@"GPSLab.configuration")
#define GPSLAB_PROTECTED_STRING_BookmarksKey (@"GPSLab.bookmarks")
#define GPSLAB_PROTECTED_STRING_RecentsKey (@"GPSLab.recents")
#define GPSLAB_PROTECTED_STRING_CommittedSelectionKey (@"GPSLab.committedSelection")
#define GPSLAB_PROTECTED_STRING_MapStyleKey (@"GPSLab.mapStyle")
#define GPSLAB_PROTECTED_STRING_LanguageDefaultsKey (@"GPSLab.language")
#define GPSLAB_PROTECTED_STRING_WiFiSimulationKey (@"GPSLab.simulation.wifi.enabled")
#define GPSLAB_PROTECTED_STRING_BluetoothSimulationKey (@"GPSLab.simulation.bluetooth.enabled")

#define GPSLAB_PROTECTED_STRING(symbol) GPSLAB_PROTECTED_STRING_##symbol

#endif

/* Encoded blobs: always present so the portable test can decode them;
   marked unused so a DEV translation unit stays -Wall/-Wextra clean. */
static const unsigned char kGPSLabProtected_DefaultsSuite[] __attribute__((unused)) = {
    0x9A, 0x96, 0x94, 0xD7, 0x9E, 0x89, 0x8A, 0x95, 0x98, 0x9B, 0xD7, 0x8B,
    0x8C, 0x97, 0x8D, 0x90, 0x94, 0x9C,
};
static const unsigned char kGPSLabProtectedKey_DefaultsSuite __attribute__((unused)) = 0xF9;

static const unsigned char kGPSLabProtected_PendingSelectionKey[] __attribute__((unused)) = {
    0x5E, 0x49, 0x4A, 0x55, 0x78, 0x7B, 0x37, 0x69, 0x7C, 0x77, 0x7D, 0x70,
    0x77, 0x7E, 0x4A, 0x7C, 0x75, 0x7C, 0x7A, 0x6D, 0x70, 0x76, 0x77,
};
static const unsigned char kGPSLabProtectedKey_PendingSelectionKey __attribute__((unused)) = 0x19;

static const unsigned char kGPSLabProtected_ConfigurationKey[] __attribute__((unused)) = {
    0xD7, 0xC0, 0xC3, 0xDC, 0xF1, 0xF2, 0xBE, 0xF3, 0xFF, 0xFE, 0xF6, 0xF9,
    0xF7, 0xE5, 0xE2, 0xF1, 0xE4, 0xF9, 0xFF, 0xFE,
};
static const unsigned char kGPSLabProtectedKey_ConfigurationKey __attribute__((unused)) = 0x90;

static const unsigned char kGPSLabProtected_BookmarksKey[] __attribute__((unused)) = {
    0x02, 0x15, 0x16, 0x09, 0x24, 0x27, 0x6B, 0x27, 0x2A, 0x2A, 0x2E, 0x28,
    0x24, 0x37, 0x2E, 0x36,
};
static const unsigned char kGPSLabProtectedKey_BookmarksKey __attribute__((unused)) = 0x45;

static const unsigned char kGPSLabProtected_RecentsKey[] __attribute__((unused)) = {
    0x09, 0x1E, 0x1D, 0x02, 0x2F, 0x2C, 0x60, 0x3C, 0x2B, 0x2D, 0x2B, 0x20,
    0x3A, 0x3D,
};
static const unsigned char kGPSLabProtectedKey_RecentsKey __attribute__((unused)) = 0x4E;

static const unsigned char kGPSLabProtected_CommittedSelectionKey[] __attribute__((unused)) = {
    0x2F, 0x38, 0x3B, 0x24, 0x09, 0x0A, 0x46, 0x0B, 0x07, 0x05, 0x05, 0x01,
    0x1C, 0x1C, 0x0D, 0x0C, 0x3B, 0x0D, 0x04, 0x0D, 0x0B, 0x1C, 0x01, 0x07,
    0x06,
};
static const unsigned char kGPSLabProtectedKey_CommittedSelectionKey __attribute__((unused)) = 0x68;

static const unsigned char kGPSLabProtected_MapStyleKey[] __attribute__((unused)) = {
    0xDE, 0xC9, 0xCA, 0xD5, 0xF8, 0xFB, 0xB7, 0xF4, 0xF8, 0xE9, 0xCA, 0xED,
    0xE0, 0xF5, 0xFC,
};
static const unsigned char kGPSLabProtectedKey_MapStyleKey __attribute__((unused)) = 0x99;

static const unsigned char kGPSLabProtected_LanguageDefaultsKey[] __attribute__((unused)) = {
    0x23, 0x34, 0x37, 0x28, 0x05, 0x06, 0x4A, 0x08, 0x05, 0x0A, 0x03, 0x11,
    0x05, 0x03, 0x01,
};
static const unsigned char kGPSLabProtectedKey_LanguageDefaultsKey __attribute__((unused)) = 0x64;

static const unsigned char kGPSLabProtected_WiFiSimulationKey[] __attribute__((unused)) = {
    0xC9, 0xDE, 0xDD, 0xC2, 0xEF, 0xEC, 0xA0, 0xFD, 0xE7, 0xE3, 0xFB, 0xE2,
    0xEF, 0xFA, 0xE7, 0xE1, 0xE0, 0xA0, 0xF9, 0xE7, 0xE8, 0xE7, 0xA0, 0xEB,
    0xE0, 0xEF, 0xEC, 0xE2, 0xEB, 0xEA,
};
static const unsigned char kGPSLabProtectedKey_WiFiSimulationKey __attribute__((unused)) = 0x8E;

static const unsigned char kGPSLabProtected_BluetoothSimulationKey[] __attribute__((unused)) = {
    0x52, 0x45, 0x46, 0x59, 0x74, 0x77, 0x3B, 0x66, 0x7C, 0x78, 0x60, 0x79,
    0x74, 0x61, 0x7C, 0x7A, 0x7B, 0x3B, 0x77, 0x79, 0x60, 0x70, 0x61, 0x7A,
    0x7A, 0x61, 0x7D, 0x3B, 0x70, 0x7B, 0x74, 0x77, 0x79, 0x70, 0x71,
};
static const unsigned char kGPSLabProtectedKey_BluetoothSimulationKey __attribute__((unused)) = 0x15;

#if defined(GPSLAB_PROTECTED_STRING_TEST)

typedef struct {
    const char *name;
    const unsigned char *blob;
    size_t length;
    unsigned char key;
    const char *expected;
} GPSLabProtectedStringCase;

static const GPSLabProtectedStringCase kGPSLabProtectedStringCases[] __attribute__((unused)) = {
    { "DefaultsSuite", kGPSLabProtected_DefaultsSuite, sizeof(kGPSLabProtected_DefaultsSuite), kGPSLabProtectedKey_DefaultsSuite, "com.gpslab.runtime" },
    { "PendingSelectionKey", kGPSLabProtected_PendingSelectionKey, sizeof(kGPSLabProtected_PendingSelectionKey), kGPSLabProtectedKey_PendingSelectionKey, "GPSLab.pendingSelection" },
    { "ConfigurationKey", kGPSLabProtected_ConfigurationKey, sizeof(kGPSLabProtected_ConfigurationKey), kGPSLabProtectedKey_ConfigurationKey, "GPSLab.configuration" },
    { "BookmarksKey", kGPSLabProtected_BookmarksKey, sizeof(kGPSLabProtected_BookmarksKey), kGPSLabProtectedKey_BookmarksKey, "GPSLab.bookmarks" },
    { "RecentsKey", kGPSLabProtected_RecentsKey, sizeof(kGPSLabProtected_RecentsKey), kGPSLabProtectedKey_RecentsKey, "GPSLab.recents" },
    { "CommittedSelectionKey", kGPSLabProtected_CommittedSelectionKey, sizeof(kGPSLabProtected_CommittedSelectionKey), kGPSLabProtectedKey_CommittedSelectionKey, "GPSLab.committedSelection" },
    { "MapStyleKey", kGPSLabProtected_MapStyleKey, sizeof(kGPSLabProtected_MapStyleKey), kGPSLabProtectedKey_MapStyleKey, "GPSLab.mapStyle" },
    { "LanguageDefaultsKey", kGPSLabProtected_LanguageDefaultsKey, sizeof(kGPSLabProtected_LanguageDefaultsKey), kGPSLabProtectedKey_LanguageDefaultsKey, "GPSLab.language" },
    { "WiFiSimulationKey", kGPSLabProtected_WiFiSimulationKey, sizeof(kGPSLabProtected_WiFiSimulationKey), kGPSLabProtectedKey_WiFiSimulationKey, "GPSLab.simulation.wifi.enabled" },
    { "BluetoothSimulationKey", kGPSLabProtected_BluetoothSimulationKey, sizeof(kGPSLabProtected_BluetoothSimulationKey), kGPSLabProtectedKey_BluetoothSimulationKey, "GPSLab.simulation.bluetooth.enabled" },
};

#define GPSLAB_PROTECTED_STRING_CASE_COUNT \
    (sizeof(kGPSLabProtectedStringCases) / sizeof(kGPSLabProtectedStringCases[0]))

#endif /* GPSLAB_PROTECTED_STRING_TEST */

#endif /* GPSLAB_PROTECTED_STRINGS_GENERATED_H */
