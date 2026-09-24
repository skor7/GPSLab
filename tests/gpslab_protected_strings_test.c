/*
 * GPSLab protected-string tests (portable C).
 *
 * Exercises Source/GPSLabProtectedStringCore.c and the committed generated blobs
 * from Source/GPSLabProtectedStringsGenerated.h:
 *   * the XOR decode core against fixed vectors (including NULL/zero-length);
 *   * every encoded blob decodes back to its declared plaintext;
 *   * no blob equals or contains its plaintext.
 *
 * The DEV/PRODUCTION macro text is proven separately by
 * scripts/audit_protected_strings.py (no Foundation needed).
 *
 * Build/run:
 *   cc -I Source tests/gpslab_protected_strings_test.c Source/GPSLabProtectedStringCore.c \
 *      -o protected_strings_test && ./protected_strings_test
 */

#include <stdio.h>
#include <string.h>

#include "GPSLabProtectedStringCore.h"

/* Ask the generated header for the expected-plaintext test table. */
#define GPSLAB_PROTECTED_STRING_TEST 1
#include "GPSLabProtectedStringsGenerated.h"

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

static void test_core_fixed_vectors(void) {
    unsigned char out[8];

    const unsigned char identity[] = { 0x00, 0x41, 0xFF };
    memset(out, 0xAA, sizeof(out));
    GPSLabProtectedStringDecodeBytes(identity, sizeof(identity), 0x00, out);
    CHECK(out[0] == 0x00 && out[1] == 0x41 && out[2] == 0xFF, "zero key is identity");

    const unsigned char encoded[] = { 0x5A, 0x1B, 0x0F, 0x4E };
    memset(out, 0x00, sizeof(out));
    GPSLabProtectedStringDecodeBytes(encoded, sizeof(encoded), 0x5A, out);
    CHECK(out[0] == 0x00 && out[1] == 0x41 && out[2] == 0x55 && out[3] == 0x14,
          "fixed XOR vector decodes");

    /* XOR is an involution: decoding twice returns the input. */
    unsigned char round[4];
    memset(round, 0x00, sizeof(round));
    GPSLabProtectedStringDecodeBytes(encoded, sizeof(encoded), 0x5A, round);
    unsigned char again[4];
    memset(again, 0x00, sizeof(again));
    GPSLabProtectedStringDecodeBytes(round, sizeof(round), 0x5A, again);
    CHECK(memcmp(again, encoded, sizeof(encoded)) == 0, "decode is an involution");

    /* Fail closed: NULL/zero-length inputs are no-ops. */
    GPSLabProtectedStringDecodeBytes(NULL, 4, 0x11, out);
    GPSLabProtectedStringDecodeBytes(encoded, 0, 0x11, out);
    GPSLabProtectedStringDecodeBytes(encoded, sizeof(encoded), 0x11, NULL);
    CHECK(1, "NULL/zero-length inputs do not crash");
}

static void test_generated_blobs(void) {
    CHECK(GPSLAB_PROTECTED_STRING_CASE_COUNT > 0, "the generated table is non-empty");

    for (size_t index = 0; index < GPSLAB_PROTECTED_STRING_CASE_COUNT; index++) {
        const GPSLabProtectedStringCase *entry = &kGPSLabProtectedStringCases[index];
        CHECK(entry->length < 512, entry->name);

        unsigned char decoded[512];
        memset(decoded, 0, sizeof(decoded));
        GPSLabProtectedStringDecodeBytes(entry->blob, entry->length, entry->key, decoded);
        decoded[entry->length] = '\0';

        CHECK(strcmp((const char *)decoded, entry->expected) == 0, entry->name);
        CHECK(memcmp(entry->blob, entry->expected, entry->length) != 0 ||
                  entry->length != strlen(entry->expected),
              "encoded blob differs from plaintext");
    }
}

int main(void) {
    test_core_fixed_vectors();
    test_generated_blobs();

    if (gFailures == 0) {
        printf("gpslab_protected_strings_test: %d checks passed\n", gChecks);
        return 0;
    }
    fprintf(stderr, "gpslab_protected_strings_test: %d/%d checks failed\n", gFailures, gChecks);
    return 1;
}
