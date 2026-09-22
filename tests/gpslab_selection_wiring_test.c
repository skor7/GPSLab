/*
 * GPSLab selection wiring tests (portable C).
 *
 * Executable static wiring assertions per overlay method: the pending-draft
 * lifecycle and the favorite-add flow live in UIKit code that cannot run in a
 * portable test, so this test reads the production source and pins the exact
 * ordering/structure. The behavioural rules themselves are covered by
 * gpslab_selection_policy_test.c and GPSLabStoreTests.m; this file is honestly
 * source-validated wiring, not a runtime UI test.
 *
 * Build/run (from the repository root):
 *   cc -I Source tests/gpslab_selection_wiring_test.c -o /tmp/gpslab_selection_wiring_test
 *   /tmp/gpslab_selection_wiring_test
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
    return strstr(haystack, needle) != NULL;
}

static long index_of(const char *haystack, const char *needle) {
    const char *found = strstr(haystack, needle);
    return found == NULL ? -1 : (long)(found - haystack);
}

static int appears_before(const char *haystack, const char *first, const char *second) {
    long firstIndex = index_of(haystack, first);
    long secondIndex = index_of(haystack, second);
    return firstIndex >= 0 && secondIndex >= 0 && firstIndex < secondIndex;
}

/** Extracts from `start` to the next method/#pragma/@end line. Caller frees. */
static char *extract_body(const char *start) {
    if (start == NULL) {
        return NULL;
    }
    const char *cursor = start;
    while (*cursor != '\0' && *cursor != '\n') {
        cursor++;
    }
    const char *end = cursor;
    while (*cursor != '\0') {
        const char *line = cursor + 1;
        if ((line[0] == '-' && line[1] == ' ') || (line[0] == '+' && line[1] == ' ')) {
            break;
        }
        if (strncmp(line, "#pragma", 7) == 0 || strncmp(line, "@end", 4) == 0) {
            break;
        }
        end = line;
        cursor = line;
        while (*cursor != '\0' && *cursor != '\n') {
            cursor++;
        }
    }
    size_t length = (size_t)(end - start);
    char *body = (char *)malloc(length + 1);
    if (body == NULL) {
        return NULL;
    }
    memcpy(body, start, length);
    body[length] = '\0';
    return body;
}

/** Body of the first method whose signature line starts with `signature`. */
static char *method_body(const char *source, const char *signature) {
    return extract_body(strstr(source, signature));
}

/** Body of the last matching method (for overloaded signatures). */
static char *method_body_last(const char *source, const char *signature) {
    const char *found = strstr(source, signature);
    if (found == NULL) {
        return NULL;
    }
    const char *next = strstr(found + 1, signature);
    while (next != NULL) {
        found = next;
        next = strstr(found + 1, signature);
    }
    return extract_body(found);
}

#define REQUIRE_BODY(variable, source, signature)     \
    char *variable = method_body((source), (signature)); \
    CHECK((variable) != NULL, "method present: " signature)

int main(void) {
    const char *path = "Source/GPSLabOverlayViewController.m";
    char *source = read_file(path);
    if (source == NULL) {
        fprintf(stderr, "FAIL: cannot read %s (run from the repository root)\n", path);
        return 1;
    }

    // applyCoordinate: record the receipt, then clear the draft on success.
    REQUIRE_BODY(apply, source,
                 "- (BOOL)applyCoordinate:(CLLocationCoordinate2D)coordinate altitude:(double)altitude heading:(double)heading {");
    CHECK(contains(apply, "applyConfiguration:"), "applyCoordinate writes the engine");
    CHECK(appears_before(apply, "recordCommittedSelection:", "clearPendingSelection"),
          "applyCoordinate records the receipt before clearing the draft");
    CHECK(contains(apply, "return YES"), "applyCoordinate reports success");
    free(apply);

    // clearPendingSelection clears the persisted draft (not the config).
    REQUIRE_BODY(clear, source, "- (void)clearPendingSelection {");
    CHECK(contains(clear, "[[GPSLabStore sharedStore] clearPendingSelection]"),
          "clearPendingSelection clears the persisted draft");
    free(clear);

    // restore is UI-only: never writes the engine, never records a receipt.
    REQUIRE_BODY(restore, source, "- (void)restorePendingSelection {");
    CHECK(contains(restore, "loadPendingSelection"), "restore loads the draft");
    CHECK(!contains(restore, "applyConfiguration"), "restore never applies a configuration");
    CHECK(!contains(restore, "persistConfiguration"), "restore never persists a configuration");
    CHECK(!contains(restore, "recordCommittedSelection"), "restore never records a receipt");
    free(restore);

    // Cancel clears first, then restores the committed UI.
    REQUIRE_BODY(cancel, source, "- (void)cancelTapped {");
    CHECK(appears_before(cancel, "clearPendingSelection", "loadConfigurationIntoUI"),
          "cancel clears the draft before restoring the committed UI");
    free(cancel);

    // Close retains the draft (no clear on close).
    REQUIRE_BODY(close, source, "- (void)closeTapped {");
    CHECK(!contains(close, "clearPendingSelection"), "close retains the draft");
    free(close);

    // Disappear retains the draft (background).
    REQUIRE_BODY(disappear, source, "- (void)viewDidDisappear:(BOOL)animated {");
    CHECK(!contains(disappear, "clearPendingSelection"), "disappear retains the draft");
    free(disappear);

    // Preview and altitude edits persist the draft. The 4-arg preview method is
    // the last overload (the 2-arg helper just forwards).
    char *preview = method_body_last(source, "- (void)previewCoordinate:(CLLocationCoordinate2D)coordinate");
    CHECK(preview != NULL, "method present: previewCoordinate");
    CHECK(preview != NULL && contains(preview, "persistPendingSelection"), "preview persists the draft");
    free(preview);

    REQUIRE_BODY(altitude, source, "- (void)setPendingAltitude:(double)altitude {");
    CHECK(contains(altitude, "persistPendingSelection"), "altitude edit persists the draft");
    free(altitude);

    // Heart flow: shown-selection resolution, guard, prompt, duplicate-aware add.
    REQUIRE_BODY(heart, source, "- (void)bookmarkTapped {");
    CHECK(contains(heart, "GPSLabFavoriteResolveShownSelection"), "heart resolves the shown selection");
    CHECK(contains(heart, "shouldAllowFavoriteAtCoordinate"), "heart guards the default 0,0");
    CHECK(contains(heart, "presentFavoriteNamePromptForCoordinate"), "heart prompts for a name");
    free(heart);

    REQUIRE_BODY(prompt, source, "- (void)presentFavoriteNamePromptForCoordinate:");
    CHECK(contains(prompt, "favorites.defaultName"), "prompt shows the localized default name");
    CHECK(contains(prompt, "addBookmarkIfNotDuplicate"), "prompt dedupes at confirm");
    CHECK(contains(prompt, "presentFavoriteMessageKey"), "prompt surfaces a visible duplicate message");
    CHECK(contains(prompt, "__weak UIAlertController"), "prompt uses a weak alert ref");
    free(prompt);

    REQUIRE_BODY(message, source, "- (void)presentFavoriteMessageKey:");
    CHECK(contains(message, "presentAlert"), "favorite message is a visible native alert");
    free(message);

    // Selection still commits through the existing applyCoordinate path.
    REQUIRE_BODY(select, source, "- (void)favoriteTapped:(UIButton *)sender {");
    CHECK(contains(select, "applyCoordinate"), "favorite selection reuses applyCoordinate");
    free(select);

    // The draft clear must never erase the keep-last configuration.
    CHECK(!contains(source, "clearPersistedCoordinate"),
          "overlay never erases the keep-last configuration to clear a draft");

    free(source);

    if (gFailures != 0) {
        fprintf(stderr, "%d/%d wiring checks failed\n", gFailures, gChecks);
        return 1;
    }
    printf("ok: %d selection wiring checks passed\n", gChecks);
    return 0;
}
