/*
 * GPSLab overlay UI wiring tests (portable C).
 *
 * Executable static wiring assertions for the behaviour that lives in UIKit code
 * the portable test target cannot instantiate: the overlay-owned drift DRAFT, the
 * shared keyboard handling and the persisted map-style preference. The test reads
 * the production source and pins the exact ordering/structure, so it is honestly
 * source-validated wiring, not a runtime UI test.
 *
 * The pure rules it depends on are covered elsewhere:
 *   * drift bounds/clamping            -> gpslab_altitude_test.c / GPSLabDriftTests.m
 *   * map-style persistence roundtrip  -> GPSLabStoreTests.m
 *
 * Build/run (from the repository root):
 *   cc -I Source tests/gpslab_overlay_ui_wiring_test.c -o /tmp/gpslab_overlay_ui_wiring_test
 *   /tmp/gpslab_overlay_ui_wiring_test
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

#define REQUIRE_BODY(variable, source, signature)        \
    char *variable = method_body((source), (signature)); \
    CHECK((variable) != NULL, "method present: " signature)

/* ---------------------------------------------------------------- Drift draft */

static void test_overlay_drift_draft(const char *overlay, const char *catalog) {
    CHECK(contains(overlay, "@property (nonatomic, assign) BOOL pendingDriftEnabled;"),
          "overlay declares the pendingDriftEnabled draft");
    CHECK(contains(overlay, "@property (nonatomic, assign) double pendingDriftRadius;"),
          "overlay declares the pendingDriftRadius draft");

    // The compact row requires this exact localized label.
    CHECK(contains(catalog, "\"panel.drift.range\""), "the catalog defines panel.drift.range");
    CHECK(contains(catalog, "\"Drift range\""), "the catalog English label is exact");
    CHECK(contains(catalog, "\u0645\u062f\u0649 \u0627\u0644\u062a\u0630\u0628\u0630\u0628"),
          "the catalog Arabic label is exact");

    // The draft is seeded from the COMMITTED configuration on load.
    REQUIRE_BODY(load, overlay, "- (void)loadConfigurationIntoUI {");
    CHECK(contains(load, "self.pendingDriftEnabled = configuration.driftEnabled"),
          "load seeds pendingDriftEnabled from the committed configuration");
    CHECK(contains(load, "self.pendingDriftRadius = configuration.driftRadiusMeters"),
          "load seeds pendingDriftRadius from the committed configuration");
    free(load);

    // The switch edits ONLY the draft and NEVER touches the engine.
    REQUIRE_BODY(driftChanged, overlay, "- (void)driftChanged {");
    CHECK(contains(driftChanged, "self.pendingDriftEnabled = self.driftSwitch.on"),
          "the switch edits pendingDriftEnabled");
    CHECK(!contains(driftChanged, "setDriftEnabled"), "the switch never enables/disables the engine");
    CHECK(!contains(driftChanged, "setDriftRadiusMeters"), "the switch never writes the engine radius");
    CHECK(!contains(driftChanged, "GPSLabEngine"), "the switch never reaches the engine");
    free(driftChanged);

    // The compact localized range row sits immediately under the switch and is
    // tappable into the fluctuation sheet.
    char *column = method_body(overlay, "- (UIView *)controlCardView {");
    CHECK(column != NULL, "method present: controlCardView");
    CHECK(appears_before(column, "panel.toggle.drift", "[self driftRangeRowView]"),
          "the range row is added after the drift switch");
    CHECK(appears_before(column, "[self driftRangeRowView]", "panel.toggle.keepLast"),
          "the range row is immediately under the switch (before keep-last)");
    free(column);

    // The compact row: exact localized label + live value + visible `>` chevron,
    // and the shared subtree localization must not corrupt the live value.
    REQUIRE_BODY(rangeRow, overlay, "- (UIView *)driftRangeRowView {");
    CHECK(contains(rangeRow, "panel.drift.range"), "the range row uses the exact localized label key");
    CHECK(contains(rangeRow, "@\">\""), "the range row renders a visible > chevron");
    CHECK(contains(rangeRow, "driftRangeChevronLabel"), "the chevron is a rendered label");
    CHECK(contains(rangeRow, "driftRangeTapped"), "the range row targets its own tap action");
    CHECK(contains(rangeRow, "driftRangeValueLabel"), "the live value is rendered separately");
    CHECK(contains(rangeRow, "updateDriftRangeDisplay"), "the range row shows the localized draft value");
    free(rangeRow);

    REQUIRE_BODY(rangeDisplay, overlay, "- (void)updateDriftRangeDisplay {");
    CHECK(contains(rangeDisplay, "driftRangeValueLabel"), "the live value is applied to the value label");
    CHECK(contains(rangeDisplay, "fluctuation.radiusFormat"), "the live value uses the radius format");
    CHECK(contains(rangeDisplay, "accessibilityLabel"), "the live value is exposed for accessibility");
    free(rangeDisplay);

    REQUIRE_BODY(rangeTap, overlay, "- (void)driftRangeTapped {");
    CHECK(contains(rangeTap, "presentFluctuationSheet"), "tapping the range row opens the sheet");
    free(rangeTap);

    // The sheet is initialized from the draft and edits only the draft.
    REQUIRE_BODY(sheet, overlay, "- (void)presentFluctuationSheet {");
    CHECK(contains(sheet, "sheet.fluctuationEnabled = self.pendingDriftEnabled"),
          "the sheet is initialized from the draft enabled flag");
    CHECK(contains(sheet, "sheet.radiusMeters = self.pendingDriftRadius"),
          "the sheet is initialized from the draft radius");
    CHECK(contains(sheet, "pendingDriftEnabled = enabled"), "the sheet edits the draft enabled flag");
    CHECK(contains(sheet, "pendingDriftRadius = GPSLabClampDriftRadiusMeters(radiusMeters)"),
          "the sheet edits the draft radius");
    CHECK(!contains(sheet, "setDriftEnabled"), "the sheet never enables/disables the engine");
    CHECK(!contains(sheet, "setDriftRadiusMeters"), "the sheet never writes the engine radius");
    CHECK(!contains(sheet, "sharedEngine"), "the sheet never reaches the engine");
    free(sheet);

    // Apply must NOT pre-commit drift: the drift bundle lives in the validated
    // paths so a failed Apply cannot persist anything.
    REQUIRE_BODY(apply, overlay, "- (void)applyTapped {");
    CHECK(!contains(apply, "commitPendingDriftIfNeeded"), "Apply never pre-commits the drift draft");
    CHECK(!contains(apply, "setDriftEnabled"), "Apply never uses a direct drift setter");
    CHECK(!contains(apply, "setDriftRadiusMeters"), "Apply never uses a direct drift setter");
    CHECK(contains(apply, "endEditing:YES"), "Apply ends editing first");
    free(apply);

    // Static Apply: validate the coordinate, then bundle drift into the SAME
    // configuration passed to the engine; resync the draft only on success.
    REQUIRE_BODY(applyCoord, overlay,
                 "- (BOOL)applyCoordinate:(CLLocationCoordinate2D)coordinate altitude:(double)altitude heading:(double)heading {");
    CHECK(appears_before(applyCoord, "GPSLabIsValidCoordinate",
                         "configuration.driftEnabled = self.pendingDriftEnabled"),
          "an invalid coordinate fails before any drift write");
    CHECK(appears_before(applyCoord, "return NO", "configuration.driftEnabled = self.pendingDriftEnabled"),
          "the invalid-coordinate early return precedes the drift bundle");
    CHECK(contains(applyCoord, "configuration.driftEnabled = self.pendingDriftEnabled"),
          "static Apply bundles the drift enabled flag");
    CHECK(contains(applyCoord,
                   "configuration.driftRadiusMeters = GPSLabClampDriftRadiusMeters(self.pendingDriftRadius)"),
          "static Apply bundles the clamped drift radius");
    CHECK(appears_before(applyCoord, "configuration.driftEnabled = self.pendingDriftEnabled",
                         "applyConfiguration:configuration]"),
          "the drift bundle rides in the SAME configuration passed to the engine");
    CHECK(!contains(applyCoord, "setDriftEnabled") && !contains(applyCoord, "setDriftRadiusMeters"),
          "static Apply never uses a direct drift setter");
    CHECK(appears_before(applyCoord, "applyConfiguration:configuration]",
                         "syncDriftDraftFromCommittedConfiguration"),
          "the draft is resynced only after the successful application");
    free(applyCoord);

    // Route Apply: validate endpoints first, then bundle drift into the same config.
    REQUIRE_BODY(route, overlay, "- (void)startRouteFromPending {");
    CHECK(appears_before(route, "pendingRouteStartItem == nil",
                         "configuration.driftEnabled = self.pendingDriftEnabled"),
          "route endpoint validation precedes the drift bundle");
    CHECK(contains(route, "configuration.driftEnabled = self.pendingDriftEnabled"),
          "route Apply bundles the drift enabled flag");
    CHECK(contains(route,
                   "configuration.driftRadiusMeters = GPSLabClampDriftRadiusMeters(self.pendingDriftRadius)"),
          "route Apply bundles the clamped drift radius");
    CHECK(appears_before(route, "configuration.driftEnabled = self.pendingDriftEnabled",
                         "applyConfiguration:configuration]"),
          "route drift rides in the SAME configuration passed to the engine");
    CHECK(!contains(route, "setDriftEnabled") && !contains(route, "setDriftRadiusMeters"),
          "route Apply never uses a direct drift setter");
    CHECK(contains(route, "syncDriftDraftFromCommittedConfiguration"),
          "route Apply resyncs the draft from the committed configuration");
    free(route);

    REQUIRE_BODY(cancel, overlay, "- (void)cancelTapped {");
    CHECK(contains(cancel, "loadConfigurationIntoUI"), "Cancel discards the draft by resyncing");
    CHECK(contains(cancel, "endEditing:YES"), "Cancel ends editing first");
    CHECK(!contains(cancel, "setDriftEnabled"), "Cancel never writes the engine");
    free(cancel);

    // The direct commit helper is eliminated; the committed-config sync remains.
    CHECK(!contains(overlay, "commitPendingDriftIfNeeded"),
          "the direct drift commit helper is eliminated");
    REQUIRE_BODY(sync, overlay, "- (void)syncDriftDraftFromCommittedConfiguration {");
    CHECK(contains(sync, "self.pendingDriftEnabled = committed.driftEnabled"),
          "the sync reloads the enabled flag from the committed configuration");
    CHECK(contains(sync, "self.pendingDriftRadius = committed.driftRadiusMeters"),
          "the sync reloads the radius from the committed configuration");
    free(sync);

    // The periodic status refresh must show the DRAFT, not roll it back.
    REQUIRE_BODY(status, overlay, "- (void)updateStatusLabel {");
    CHECK(contains(status, "self.driftSwitch.on = self.pendingDriftEnabled"),
          "the status refresh renders the draft switch, never the committed value");
    CHECK(!contains(status, "self.driftSwitch.on = configuration.driftEnabled"),
          "the status refresh never rolls the switch back to the committed value");
    free(status);

    // Profile staging/applying resyncs the draft with the committed configuration.
    REQUIRE_BODY(staged, overlay, "- (void)applyStagedProfileUI:");
    CHECK(contains(staged, "loadConfigurationIntoUI"), "a staged profile syncs the drift draft UI");
    free(staged);
    REQUIRE_BODY(profile, overlay, "- (void)applyProfile:");
    CHECK(contains(profile, "loadConfigurationIntoUI"), "an applied profile syncs the drift draft UI");
    free(profile);
}

/* ------------------------------------------------------------------- Keyboard */

static void test_sheet_keyboard(const char *sheet) {
    // The interactive scroll + keyboard guide architecture is preserved.
    CHECK(contains(sheet, "keyboardLayoutGuide"), "the keyboard layout guide is preserved");
    CHECK(contains(sheet, "UIScrollViewKeyboardDismissModeInteractive"),
          "interactive keyboard dismissal is preserved");

    // Scoped end-editing on a real dismissal only.
    REQUIRE_BODY(disappear, sheet, "- (void)viewWillDisappear:(BOOL)animated {");
    CHECK(contains(disappear, "endEditing:YES"), "dismiss scopes an endEditing");
    CHECK(contains(disappear, "isBeingDismissed"), "the endEditing is scoped to an actual dismissal");
    free(disappear);

    // Safe background tap: never blocks controls and ignores control touches.
    CHECK(contains(sheet, "gpslab_backgroundTapped"), "a background tap ends editing");
    CHECK(contains(sheet, "cancelsTouchesInView = NO"), "the background tap does not block controls");
    CHECK(contains(sheet, "shouldReceiveTouch"), "the background tap scopes its touches");
    CHECK(contains(sheet, "UIControl"), "the background tap ignores touches on controls");

    // Centralized, localized Done accessory + shared Return for decimal fields.
    REQUIRE_BODY(field, sheet, "- (UITextField *)decimalFieldWithPlaceholder:");
    CHECK(contains(field, "field.delegate = self"), "decimal fields get the shared delegate");
    CHECK(contains(field, "inputAccessoryView"), "decimal fields get the Done accessory");
    CHECK(contains(field, "gpslab_decimalAccessoryView"), "the accessory is the centralized helper");
    free(field);
    CHECK(contains(sheet, "common.done"), "the accessory is localized (common.done)");
    CHECK(contains(sheet, "gpslab_decimalAccessoryView"), "the Done accessory helper exists");
    CHECK(contains(sheet, "(BOOL)textFieldShouldReturn:(UITextField *)textField"),
          "the shared delegate ends editing on Return");
}

static void test_form_actions_end_editing(const char *manual, const char *form,
                                          const char *subscription, const char *altitude) {
    REQUIRE_BODY(manualApply, manual, "- (void)applyTapped {");
    CHECK(contains(manualApply, "endEditing:YES"), "manual Apply ends editing");
    free(manualApply);

    REQUIRE_BODY(save, form, "- (void)saveTapped {");
    CHECK(contains(save, "endEditing:YES"), "profile Save ends editing");
    free(save);
    REQUIRE_BODY(delete, form, "- (void)deleteTapped {");
    CHECK(contains(delete, "endEditing:YES"), "profile Delete ends editing");
    free(delete);

    REQUIRE_BODY(activate, subscription, "- (void)activateTapped {");
    CHECK(contains(activate, "endEditing:YES"), "activation ends editing");
    CHECK(appears_before(activate, "endEditing:YES", "isServiceConfigured"),
          "activation ends editing BEFORE any licensing/network work");
    free(activate);

    REQUIRE_BODY(altApply, altitude, "- (void)applyTapped {");
    CHECK(contains(altApply, "endEditing:YES"), "altitude Apply ends editing");
    free(altApply);
    REQUIRE_BODY(altCancel, altitude, "- (void)cancelTapped {");
    CHECK(contains(altCancel, "endEditing:YES"), "altitude Cancel ends editing");
    free(altCancel);
}

/* ----------------------------------------------------------------------- Map */

static void test_map_preference(const char *overlay, const char *store,
                                const char *storeHeader, const char *types,
                                const char *configuration, const char *profile) {
    // The UI preference is persisted by the store and never enters the schema.
    CHECK(contains(storeHeader, "- (GPSLabMapStyle)loadMapStyle;"),
          "the store exposes loadMapStyle");
    CHECK(contains(storeHeader, "- (void)saveMapStyle:(GPSLabMapStyle)style;"),
          "the store exposes saveMapStyle");
    CHECK(contains(store, "@\"GPSLab.mapStyle\""), "the store persists the exact map-style key");
    CHECK(contains(store, "GPSLabMapStyleSatellite"), "missing/invalid resolves to Satellite");
    CHECK(contains(store, "GPSLabMapStyleStandard") && contains(store, "GPSLabMapStyleSatellite"),
          "the store validates the persisted style range");
    CHECK(contains(types, "GPSLabMapStyleStandard = 0") && contains(types, "GPSLabMapStyleHybrid") &&
              contains(types, "GPSLabMapStyleSatellite"),
          "the shared enum defines exactly three valid styles");
    CHECK(!contains(configuration, "mapStyle"), "the map style is never part of the configuration");
    CHECK(!contains(profile, "mapStyle"), "the map style is never part of the profile schema");

    // Foreground uses the persisted style with real MK configurations.
    REQUIRE_BODY(viewDidLoad, overlay, "- (void)viewDidLoad {");
    CHECK(contains(viewDidLoad, "loadMapStyle"), "the foreground loads the persisted style");
    free(viewDidLoad);

    REQUIRE_BODY(style, overlay, "- (void)applyMapStyle:(NSInteger)style {");
    CHECK(contains(style, "saveMapStyle"), "selecting a style persists the preference");
    CHECK(contains(style, "preferredConfiguration"), "the foreground uses MK map configurations");
    CHECK(contains(style, "scheduleBackgroundSnapshot"), "selecting a style refreshes the snapshot");
    free(style);

    // The snapshot matches the selected style through the single mapping helper.
    REQUIRE_BODY(snapshot, overlay, "- (void)refreshBackgroundSnapshot {");
    CHECK(contains(snapshot, "mapTypeForStyle"), "the snapshot reuses the style mapping");
    CHECK(!contains(snapshot, "options.mapType = MKMapTypeStandard"),
          "the snapshot is never hardcoded to the standard style");
    free(snapshot);

    REQUIRE_BODY(mapping, overlay, "- (MKMapType)mapTypeForStyle:(GPSLabMapStyle)style {");
    CHECK(contains(mapping, "MKMapTypeHybrid") && contains(mapping, "MKMapTypeSatellite") &&
              contains(mapping, "MKMapTypeStandard"),
          "the mapping covers all three styles");
    free(mapping);

    // No duplicated selection system.
    CHECK(count_occurrences(overlay, "- (void)applyMapStyle:(NSInteger)style {") == 1,
          "there is exactly one applyMapStyle entry point");
    CHECK(count_occurrences(overlay, "- (MKMapType)mapTypeForStyle:(GPSLabMapStyle)style {") == 1,
          "there is exactly one style-to-map-type helper");

    // The style selection is independent of the location Apply/Cancel draft.
    REQUIRE_BODY(apply, overlay, "- (void)applyTapped {");
    CHECK(!contains(apply, "GPSLabMapStyle"), "Apply never mutates the map style");
    free(apply);
    REQUIRE_BODY(cancel, overlay, "- (void)cancelTapped {");
    CHECK(!contains(cancel, "GPSLabMapStyle"), "Cancel never mutates the map style");
    free(cancel);
}

int main(void) {
    const char *overlay_path = "Source/GPSLabOverlayViewController.m";
    const char *sheet_path = "Source/GPSLabSheetViewController.m";
    const char *manual_path = "Source/GPSLabManualEntryViewController.m";
    const char *form_path = "Source/GPSLabProfileFormViewController.m";
    const char *subscription_path = "Source/GPSLabSubscriptionViewController.m";
    const char *altitude_path = "Source/GPSLabAltitudeViewController.m";
    const char *store_path = "Source/GPSLabStore.m";
    const char *store_header_path = "Source/GPSLabStore.h";
    const char *types_path = "Source/GPSLabTypes.h";
    const char *configuration_path = "Source/GPSLabConfiguration.m";
    const char *profile_path = "Source/GPSLabProfile.m";
    const char *catalog_path = "Source/GPSLabLocalizationCore.c";

    char *overlay = read_file(overlay_path);
    char *sheet = read_file(sheet_path);
    char *manual = read_file(manual_path);
    char *form = read_file(form_path);
    char *subscription = read_file(subscription_path);
    char *altitude = read_file(altitude_path);
    char *store = read_file(store_path);
    char *store_header = read_file(store_header_path);
    char *types = read_file(types_path);
    char *configuration = read_file(configuration_path);
    char *profile = read_file(profile_path);
    char *catalog = read_file(catalog_path);

    if (overlay == NULL || sheet == NULL || manual == NULL || form == NULL ||
        subscription == NULL || altitude == NULL || store == NULL ||
        store_header == NULL || types == NULL || configuration == NULL || profile == NULL ||
        catalog == NULL) {
        fprintf(stderr, "FAIL: cannot read one or more sources (run from the repository root)\n");
        free(overlay); free(sheet); free(manual); free(form); free(subscription);
        free(altitude); free(store); free(store_header); free(types); free(configuration);
        free(profile); free(catalog);
        return 1;
    }

    test_overlay_drift_draft(overlay, catalog);
    test_sheet_keyboard(sheet);
    test_form_actions_end_editing(manual, form, subscription, altitude);
    test_map_preference(overlay, store, store_header, types, configuration, profile);

    free(overlay);
    free(sheet);
    free(manual);
    free(form);
    free(subscription);
    free(altitude);
    free(store);
    free(store_header);
    free(types);
    free(configuration);
    free(profile);
    free(catalog);

    if (gFailures != 0) {
        fprintf(stderr, "%d/%d overlay UI wiring checks failed\n", gFailures, gChecks);
        return 1;
    }
    printf("ok: %d overlay UI wiring checks passed\n", gChecks);
    return 0;
}
