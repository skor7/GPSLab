//
//  GPSLabStoreTests.m
//  GPSLab
//
//  Production-store coverage for the pending-selection draft, the committed
//  receipt, the favorite-add decision and the duplicate-aware bookmark insert.
//  Every test uses an isolated NSUserDefaults suite (initWithUserDefaults:) so
//  the shared runtime suite is never touched.
//
//  Build/run (macOS):
//    clang -fobjc-arc -fmodules -framework Foundation -framework CoreLocation -ISource \
//      tests/GPSLabStoreTests.m Source/GPSLabStore.m Source/GPSLabConfiguration.m \
//      Source/GPSLabGeodesy.m Source/GPSLabTypes.m Source/GPSLabProfileCore.c \
//      Source/GPSLabSelectionPolicyCore.c -o /tmp/gpslab-store-tests
//    /tmp/gpslab-store-tests
//

#import <Foundation/Foundation.h>

#include <math.h>
#include <stdlib.h>
#include <unistd.h>

#import "GPSLabConfiguration.h"
#import "GPSLabStore.h"

static int gFailures = 0;
static int gChecks = 0;

#define CHECK(condition, message)                                  \
    do {                                                           \
        gChecks++;                                                 \
        if (!(condition)) {                                        \
            gFailures++;                                           \
            fprintf(stderr, "FAIL: %s\n", [(message) UTF8String]); \
        }                                                          \
    } while (0)

static NSString *gSuite = nil;
static NSUserDefaults *gDefaults = nil;
static GPSLabStore *gStore = nil;
static int gSuiteCounter = 0;

static void beginStore(void) {
    gSuiteCounter++;
    gSuite = [NSString stringWithFormat:@"com.gpslab.tests.%d.%d", (int)getpid(), gSuiteCounter];
    gDefaults = [[NSUserDefaults alloc] initWithSuiteName:gSuite];
    [gDefaults removePersistentDomainForName:gSuite];
    gStore = [[GPSLabStore alloc] initWithUserDefaults:gDefaults];
}

static void endStore(void) {
    [gDefaults removePersistentDomainForName:gSuite];
    gSuite = nil;
    gDefaults = nil;
    gStore = nil;
}

/**
 * A second store on the same suite but a NEW NSUserDefaults instance (a real
 * reopen), proving persistence independent of the first object's cache.
 */
static GPSLabStore *reopenedStore(void) {
    [gDefaults synchronize];
    NSUserDefaults *fresh = [[NSUserDefaults alloc] initWithSuiteName:gSuite];
    return [[GPSLabStore alloc] initWithUserDefaults:fresh];
}

static GPSLabBookmark *makeBookmark(NSString *name, double latitude, double longitude, double altitude) {
    return [GPSLabBookmark bookmarkWithName:name
                                  coordinate:CLLocationCoordinate2DMake(latitude, longitude)
                                    altitude:altitude];
}

#pragma mark - Pending selection draft

static void test_pending_roundtrip(void) {
    beginStore();

    CHECK([gStore loadPendingSelection] == nil, @"fresh store has no draft");

    GPSLabPendingSelection *selection =
        [[GPSLabPendingSelection alloc] initWithLatitude:24.7136
                                               longitude:46.6753
                                                altitude:612.5
                                                 heading:45.0
                                             providerKey:@"search.source.google"];
    [gStore savePendingSelection:selection];

    GPSLabPendingSelection *loaded = [gStore loadPendingSelection];
    CHECK(loaded != nil, @"draft roundtrips");
    CHECK(loaded != nil && fabs(loaded.latitude - 24.7136) < 1e-9, @"draft latitude");
    CHECK(loaded != nil && fabs(loaded.longitude - 46.6753) < 1e-9, @"draft longitude");
    CHECK(loaded != nil && fabs(loaded.altitude - 612.5) < 1e-9, @"draft altitude");
    CHECK(loaded != nil && fabs(loaded.heading - 45.0) < 1e-9, @"draft heading");
    CHECK(loaded != nil && [loaded.providerKey isEqualToString:@"search.source.google"], @"draft provider");

    // Persists across a fresh store instance (close/reopen).
    CHECK(reopenedStore().loadPendingSelection != nil, @"draft survives reopen");

    // Provider is optional.
    GPSLabPendingSelection *noProvider =
        [[GPSLabPendingSelection alloc] initWithLatitude:1.0
                                               longitude:2.0
                                                altitude:3.0
                                                 heading:-1.0
                                             providerKey:nil];
    [gStore savePendingSelection:noProvider];
    CHECK([gStore loadPendingSelection].providerKey == nil, @"draft without provider loads");

    // Unknown provider is dropped, the coordinate is kept.
    GPSLabPendingSelection *unknownProvider =
        [[GPSLabPendingSelection alloc] initWithLatitude:1.0
                                               longitude:2.0
                                                altitude:3.0
                                                 heading:0.0
                                             providerKey:@"search.source.unknown"];
    [gStore savePendingSelection:unknownProvider];
    GPSLabPendingSelection *unknownLoaded = [gStore loadPendingSelection];
    CHECK(unknownLoaded != nil, @"unknown provider keeps the draft");
    CHECK(unknownLoaded != nil && unknownLoaded.providerKey == nil, @"unknown provider dropped");

    [gStore clearPendingSelection];
    CHECK([gStore loadPendingSelection] == nil, @"draft cleared");
    CHECK(reopenedStore().loadPendingSelection == nil, @"clear survives reopen");

    endStore();
}

static void test_pending_altitude(void) {
    beginStore();
    GPSLabPendingSelection *selection =
        [[GPSLabPendingSelection alloc] initWithLatitude:10.0
                                               longitude:20.0
                                                altitude:-123.25
                                                 heading:0.0
                                             providerKey:nil];
    [gStore savePendingSelection:selection];
    CHECK(fabs([gStore loadPendingSelection].altitude - (-123.25)) < 1e-9, @"fractional altitude roundtrips");
    endStore();
}

static void writeRawDraft(id value) {
    [gDefaults setObject:value forKey:@"GPSLab.pendingSelection"];
    [gDefaults synchronize];
}

static void test_pending_corrupt(void) {
    beginStore();

    writeRawDraft(@"not a dictionary");
    CHECK([gStore loadPendingSelection] == nil, @"non-dictionary draft ignored");

    writeRawDraft(@[]);
    CHECK([gStore loadPendingSelection] == nil, @"array draft ignored");

    writeRawDraft(@{});
    CHECK([gStore loadPendingSelection] == nil, @"missing keys ignored");

    writeRawDraft(@{ @"latitude": @"24.0", @"longitude": @46.0, @"altitude": @0.0, @"heading": @0.0 });
    CHECK([gStore loadPendingSelection] == nil, @"string latitude ignored");

    writeRawDraft(@{ @"latitude": @YES, @"longitude": @46.0, @"altitude": @0.0, @"heading": @0.0 });
    CHECK([gStore loadPendingSelection] == nil, @"boolean latitude ignored");

    writeRawDraft(@{ @"latitude": @(NAN), @"longitude": @46.0, @"altitude": @0.0, @"heading": @0.0 });
    CHECK([gStore loadPendingSelection] == nil, @"nan latitude ignored");

    writeRawDraft(@{ @"latitude": @(INFINITY), @"longitude": @46.0, @"altitude": @0.0, @"heading": @0.0 });
    CHECK([gStore loadPendingSelection] == nil, @"inf latitude ignored");

    writeRawDraft(@{ @"latitude": @91.0, @"longitude": @46.0, @"altitude": @0.0, @"heading": @0.0 });
    CHECK([gStore loadPendingSelection] == nil, @"out-of-range latitude ignored");

    writeRawDraft(@{ @"latitude": @24.0, @"longitude": @181.0, @"altitude": @0.0, @"heading": @0.0 });
    CHECK([gStore loadPendingSelection] == nil, @"out-of-range longitude ignored");

    writeRawDraft(@{ @"latitude": @24.0, @"longitude": @46.0, @"altitude": @100001.0, @"heading": @0.0 });
    CHECK([gStore loadPendingSelection] == nil, @"out-of-range altitude ignored");

    writeRawDraft(@{ @"latitude": @24.0, @"longitude": @46.0, @"altitude": @0.0, @"heading": @361.0 });
    CHECK([gStore loadPendingSelection] == nil, @"out-of-range heading ignored");

    writeRawDraft(@{ @"latitude": @(NAN), @"longitude": @46.0, @"altitude": @0.0, @"heading": @0.0,
                     @"futureField": @{ @"nested": @1 } });
    CHECK([gStore loadPendingSelection] == nil, @"corrupt draft with future fields ignored");

    // A valid draft with unknown optional future fields still loads.
    writeRawDraft(@{ @"latitude": @24.0, @"longitude": @46.0, @"altitude": @0.0, @"heading": @-1.0,
                     @"futureField": @"anything" });
    CHECK([gStore loadPendingSelection] != nil, @"unknown future fields tolerated");

    endStore();
}

#pragma mark - Committed receipt + 0,0 policy

static void test_committed_receipt(void) {
    beginStore();
    CHECK([gStore loadCommittedSelection] == nil, @"fresh store has no receipt");
    [gStore recordCommittedSelection:[[GPSLabCommittedSelection alloc] initWithLatitude:24.7136
                                                                              longitude:46.6753
                                                                               altitude:612.5]];
    GPSLabCommittedSelection *receipt = [gStore loadCommittedSelection];
    CHECK(receipt != nil, @"receipt roundtrips");
    CHECK(receipt != nil && fabs(receipt.latitude - 24.7136) < 1e-9, @"receipt latitude");
    CHECK(reopenedStore().loadCommittedSelection != nil, @"receipt survives reopen");
    endStore();
}

static void test_favorite_zero_policy(void) {
    beginStore();

    // Pristine default: refused, even after an unrelated config save (enable/drift
    // persistence writes default coordinates and must NOT count as proof).
    CHECK(![gStore shouldAllowFavoriteAtCoordinate:CLLocationCoordinate2DMake(0.0, 0.0) hasPending:NO],
          @"pristine default 0,0 refused");
    [gStore saveConfiguration:[GPSLabConfiguration defaultConfiguration]];
    CHECK(![gStore shouldAllowFavoriteAtCoordinate:CLLocationCoordinate2DMake(0.0, 0.0) hasPending:NO],
          @"unrelated config save does not authorize 0,0");

    // Pending is always allowed (intentional 0,0).
    CHECK([gStore shouldAllowFavoriteAtCoordinate:CLLocationCoordinate2DMake(0.0, 0.0) hasPending:YES],
          @"pending intentional 0,0 allowed");

    // Nonzero committed is allowed.
    CHECK([gStore shouldAllowFavoriteAtCoordinate:CLLocationCoordinate2DMake(24.7136, 46.6753) hasPending:NO],
          @"nonzero committed allowed");

    // A stale nonzero receipt cannot authorize a reset-to-(0,0).
    [gStore recordCommittedSelection:[[GPSLabCommittedSelection alloc] initWithLatitude:24.7136
                                                                              longitude:46.6753
                                                                               altitude:612.5]];
    CHECK(![gStore shouldAllowFavoriteAtCoordinate:CLLocationCoordinate2DMake(0.0, 0.0) hasPending:NO],
          @"stale nonzero receipt rejects reset 0,0");

    // Intentional committed 0,0 is allowed once recorded.
    [gStore recordCommittedSelection:[[GPSLabCommittedSelection alloc] initWithLatitude:0.0
                                                                              longitude:0.0
                                                                               altitude:0.0]];
    CHECK([gStore shouldAllowFavoriteAtCoordinate:CLLocationCoordinate2DMake(0.0, 0.0) hasPending:NO],
          @"intentional committed 0,0 allowed");

    // Legacy proof: a valid recent at 0,0 authorizes 0,0 even without a receipt.
    endStore();
    beginStore();
    [gStore addRecentCoordinate:CLLocationCoordinate2DMake(0.0, 0.0) altitude:0.0];
    CHECK([gStore shouldAllowFavoriteAtCoordinate:CLLocationCoordinate2DMake(0.0, 0.0) hasPending:NO],
          @"legacy recent 0,0 authorizes 0,0");
    endStore();

    // A recent far away does not.
    beginStore();
    [gStore addRecentCoordinate:CLLocationCoordinate2DMake(24.7136, 46.6753) altitude:0.0];
    CHECK(![gStore shouldAllowFavoriteAtCoordinate:CLLocationCoordinate2DMake(0.0, 0.0) hasPending:NO],
          @"distant recent does not authorize 0,0");
    endStore();
}

#pragma mark - Duplicate-aware bookmarks

static void test_duplicate_add(void) {
    beginStore();

    GPSLabBookmark *first = makeBookmark(@"A", 24.7136, 46.6753, 100.0);
    CHECK([gStore addBookmarkIfNotDuplicate:first], @"first bookmark added");
    CHECK(![gStore addBookmarkIfNotDuplicate:makeBookmark(@"A2", 24.7136, 46.6753, 100.0)],
          @"exact duplicate rejected");
    // ~2.2 m away: inside the 5 m tolerance.
    CHECK(![gStore addBookmarkIfNotDuplicate:makeBookmark(@"A3", 24.71362, 46.6753, 100.0)],
          @"within-tolerance duplicate rejected");
    // ~11 m away: outside the 5 m tolerance.
    CHECK([gStore addBookmarkIfNotDuplicate:makeBookmark(@"A4", 24.7137, 46.6753, 100.0)],
          @"outside-tolerance point added");
    CHECK([gStore loadBookmarks].count == 2, @"two distinct bookmarks persisted");

    // Compat wrapper still inserts non-duplicates.
    [gStore addBookmark:makeBookmark(@"B", 10.0, 20.0, 0.0)];
    CHECK([gStore loadBookmarks].count == 3, @"compat addBookmark inserts a new point");

    // Legacy duplicates are preserved, never purged: write two identical raw rows.
    NSArray *legacy = @[
        @{ @"name": @"L1", @"latitude": @1.0, @"longitude": @2.0, @"altitude": @0.0 },
        @{ @"name": @"L2", @"latitude": @1.0, @"longitude": @2.0, @"altitude": @0.0 },
    ];
    NSData *legacyData = [NSJSONSerialization dataWithJSONObject:legacy options:0 error:NULL];
    [gDefaults setObject:legacyData forKey:@"GPSLab.bookmarks"];
    [gDefaults synchronize];
    CHECK([gStore loadBookmarks].count == 2, @"legacy duplicate rows preserved on load");
    CHECK(![gStore addBookmarkIfNotDuplicate:makeBookmark(@"L3", 1.0, 2.0, 0.0)],
          @"legacy duplicate blocks a new insert");
    CHECK([gStore loadBookmarks].count == 2, @"legacy duplicates not purged by a rejected insert");

    endStore();
}

static void test_rename_delete_persist(void) {
    beginStore();
    [gStore addBookmarkIfNotDuplicate:makeBookmark(@"One", 1.0, 2.0, 3.0)];
    [gStore addBookmarkIfNotDuplicate:makeBookmark(@"Two", 4.0, 5.0, 6.0)];

    [gStore renameBookmarkAtIndex:0 name:@"Renamed"];
    CHECK([[gStore loadBookmarks][0].name isEqualToString:@"Renamed"], @"rename persisted");

    [gStore deleteBookmarkAtIndex:1];
    NSArray<GPSLabBookmark *> *remaining = [gStore loadBookmarks];
    CHECK(remaining.count == 1, @"delete persisted");
    CHECK(remaining.count == 1 && [remaining[0].name isEqualToString:@"Renamed"], @"remaining row is the renamed one");

    // Reopen sees the same data.
    CHECK(reopenedStore().loadBookmarks.count == 1, @"rename/delete survive reopen");
    endStore();
}

#pragma mark - Existing data independence

static void test_existing_data_untouched(void) {
    beginStore();

    GPSLabConfiguration *configuration = [GPSLabConfiguration defaultConfiguration];
    configuration.enabled = NO;
    configuration.latitude = 24.7136;
    configuration.longitude = 46.6753;
    configuration.altitude = 321.0;
    configuration.heading = 90.0;
    configuration.driftRadiusMeters = 12.0;
    configuration.keepLastCoordinate = YES;
    [gStore saveConfiguration:configuration];

    [gStore addBookmarkIfNotDuplicate:makeBookmark(@"Saved", 24.0, 46.0, 5.0)];
    [gStore addRecentCoordinate:CLLocationCoordinate2DMake(11.0, 22.0) altitude:33.0];

    NSUInteger bookmarksBefore = [gStore loadBookmarks].count;
    NSUInteger recentsBefore = [gStore loadRecents].count;

    // Draft and receipt operations must not disturb configuration/bookmarks/recents.
    [gStore savePendingSelection:[[GPSLabPendingSelection alloc] initWithLatitude:1.0
                                                                        longitude:2.0
                                                                         altitude:3.0
                                                                          heading:4.0
                                                                      providerKey:nil]];
    [gStore recordCommittedSelection:[[GPSLabCommittedSelection alloc] initWithLatitude:5.0
                                                                              longitude:6.0
                                                                               altitude:7.0]];
    [gStore clearPendingSelection];

    GPSLabConfiguration *reloaded = [gStore loadConfiguration];
    CHECK(reloaded.enabled == NO, @"enabled unchanged");
    CHECK(fabs(reloaded.latitude - 24.7136) < 1e-9, @"latitude unchanged");
    CHECK(fabs(reloaded.longitude - 46.6753) < 1e-9, @"longitude unchanged");
    CHECK(fabs(reloaded.altitude - 321.0) < 1e-9, @"altitude unchanged");
    CHECK(fabs(reloaded.heading - 90.0) < 1e-9, @"heading unchanged");
    CHECK(fabs(reloaded.driftRadiusMeters - 12.0) < 1e-9, @"drift radius unchanged");
    CHECK(reloaded.keepLastCoordinate, @"keep-last unchanged");
    CHECK([gStore loadBookmarks].count == bookmarksBefore, @"bookmarks unchanged");
    CHECK([gStore loadRecents].count == recentsBefore, @"recents unchanged");

    endStore();
}

static void test_store_isolation(void) {
    // Two isolated suites never share a draft.
    NSString *suiteA = [NSString stringWithFormat:@"com.gpslab.tests.isoA.%d", (int)getpid()];
    NSString *suiteB = [NSString stringWithFormat:@"com.gpslab.tests.isoB.%d", (int)getpid()];
    NSUserDefaults *defaultsA = [[NSUserDefaults alloc] initWithSuiteName:suiteA];
    NSUserDefaults *defaultsB = [[NSUserDefaults alloc] initWithSuiteName:suiteB];
    [defaultsA removePersistentDomainForName:suiteA];
    [defaultsB removePersistentDomainForName:suiteB];

    GPSLabStore *storeA = [[GPSLabStore alloc] initWithUserDefaults:defaultsA];
    GPSLabStore *storeB = [[GPSLabStore alloc] initWithUserDefaults:defaultsB];
    [storeA savePendingSelection:[[GPSLabPendingSelection alloc] initWithLatitude:1.0
                                                                       longitude:2.0
                                                                        altitude:3.0
                                                                         heading:4.0
                                                                     providerKey:nil]];
    CHECK([storeA loadPendingSelection] != nil, @"isolated store A has the draft");
    CHECK([storeB loadPendingSelection] == nil, @"isolated store B is unaffected");

    [defaultsA removePersistentDomainForName:suiteA];
    [defaultsB removePersistentDomainForName:suiteB];
}

static void test_commit_clear_lifecycle(void) {
    beginStore();
    GPSLabConfiguration *before = [GPSLabConfiguration defaultConfiguration];
    before.latitude = 24.7136;
    before.longitude = 46.6753;
    before.keepLastCoordinate = YES;
    [gStore saveConfiguration:before];

    // Commit ordering (mirrors the overlay's applyCoordinate): a draft exists, an
    // explicit commit records a receipt, then the draft is cleared; the committed
    // configuration is untouched.
    [gStore savePendingSelection:[[GPSLabPendingSelection alloc] initWithLatitude:1.0
                                                                       longitude:2.0
                                                                        altitude:3.0
                                                                         heading:4.0
                                                                     providerKey:nil]];
    CHECK([gStore loadPendingSelection] != nil, @"draft present before commit");
    [gStore recordCommittedSelection:[[GPSLabCommittedSelection alloc] initWithLatitude:1.0
                                                                              longitude:2.0
                                                                               altitude:3.0]];
    [gStore clearPendingSelection];
    CHECK([gStore loadPendingSelection] == nil, @"commit clears the draft");
    CHECK([gStore loadCommittedSelection] != nil, @"commit records the receipt");
    CHECK(fabs([gStore loadConfiguration].latitude - 24.7136) < 1e-9,
          @"commit does not touch the committed config");

    // Cancel ordering: a draft exists, then cancel clears it; config unchanged.
    [gStore savePendingSelection:[[GPSLabPendingSelection alloc] initWithLatitude:5.0
                                                                       longitude:6.0
                                                                        altitude:7.0
                                                                         heading:8.0
                                                                     providerKey:@"search.source.apple"]];
    [gStore clearPendingSelection];
    CHECK([gStore loadPendingSelection] == nil, @"cancel clears the draft");
    CHECK(fabs([gStore loadConfiguration].longitude - 46.6753) < 1e-9,
          @"cancel does not touch the committed config");
    endStore();
}

static void test_altitude_overwrite_survives_reopen(void) {
    beginStore();
    [gStore savePendingSelection:[[GPSLabPendingSelection alloc] initWithLatitude:10.0
                                                                       longitude:20.0
                                                                        altitude:100.0
                                                                         heading:0.0
                                                                     providerKey:nil]];
    // An altitude edit overwrites the prior draft in place.
    [gStore savePendingSelection:[[GPSLabPendingSelection alloc] initWithLatitude:10.0
                                                                       longitude:20.0
                                                                        altitude:250.5
                                                                         heading:0.0
                                                                     providerKey:nil]];
    GPSLabPendingSelection *loaded = [gStore loadPendingSelection];
    CHECK(loaded != nil && fabs(loaded.altitude - 250.5) < 1e-9, @"altitude edit overwrites the draft");
    GPSLabPendingSelection *reopened = reopenedStore().loadPendingSelection;
    CHECK(reopened != nil && fabs(reopened.altitude - 250.5) < 1e-9,
          @"overwritten altitude survives a fresh defaults instance");
    endStore();
}

static void test_near_origin_proof(void) {
    // A real direct-coordinate path: 0.000001,0 (~0.11 m) is a user-enterable
    // intentional nonzero selection, so it must NOT authorize the pristine origin.
    beginStore();
    [gStore recordCommittedSelection:[[GPSLabCommittedSelection alloc] initWithLatitude:0.000001
                                                                              longitude:0.0
                                                                               altitude:0.0]];
    CHECK(![gStore shouldAllowFavoriteAtCoordinate:CLLocationCoordinate2DMake(0.0, 0.0) hasPending:NO],
          @"0.000001,0 receipt does not authorize default 0,0");
    endStore();

    // A stale nonzero receipt ~1 m away must NOT authorize default 0,0 either.
    beginStore();
    [gStore recordCommittedSelection:[[GPSLabCommittedSelection alloc] initWithLatitude:0.000009
                                                                              longitude:0.0
                                                                               altitude:0.0]];
    CHECK(![gStore shouldAllowFavoriteAtCoordinate:CLLocationCoordinate2DMake(0.0, 0.0) hasPending:NO],
          @"near-origin nonzero receipt does not authorize default 0,0");
    endStore();

    // An exact (signed) zero receipt does.
    beginStore();
    [gStore recordCommittedSelection:[[GPSLabCommittedSelection alloc] initWithLatitude:-0.0
                                                                              longitude:-0.0
                                                                               altitude:0.0]];
    CHECK([gStore shouldAllowFavoriteAtCoordinate:CLLocationCoordinate2DMake(0.0, 0.0) hasPending:NO],
          @"signed/exact-zero receipt authorizes intentional 0,0");
    endStore();

    // Legacy proof: a recent at 0.000001,0 does not authorize 0,0.
    beginStore();
    [gStore addRecentCoordinate:CLLocationCoordinate2DMake(0.000001, 0.0) altitude:0.0];
    CHECK(![gStore shouldAllowFavoriteAtCoordinate:CLLocationCoordinate2DMake(0.0, 0.0) hasPending:NO],
          @"0.000001,0 recent does not authorize default 0,0");
    endStore();

    // Legacy proof: an exact-zero recent does.
    beginStore();
    [gStore addRecentCoordinate:CLLocationCoordinate2DMake(0.0, 0.0) altitude:0.0];
    CHECK([gStore shouldAllowFavoriteAtCoordinate:CLLocationCoordinate2DMake(0.0, 0.0) hasPending:NO],
          @"exact-zero recent authorizes intentional 0,0");
    endStore();
}

static void test_add_rejects_invalid_altitude(void) {
    beginStore();
    [gStore addBookmarkIfNotDuplicate:makeBookmark(@"Good", 1.0, 2.0, 0.0)];
    CHECK(![gStore addBookmarkIfNotDuplicate:makeBookmark(@"NaN", 3.0, 4.0, NAN)], @"nan altitude rejected");
    CHECK(![gStore addBookmarkIfNotDuplicate:makeBookmark(@"Inf", 5.0, 6.0, INFINITY)], @"inf altitude rejected");
    CHECK(![gStore addBookmarkIfNotDuplicate:makeBookmark(@"Range", 7.0, 8.0, 100001.0)],
          @"out-of-range altitude rejected");
    CHECK([gStore loadBookmarks].count == 1, @"invalid altitude never disturbs existing bookmarks");
    endStore();
}

static void test_concurrent_duplicate_insert(void) {
    beginStore();
    NSLock *counterLock = [[NSLock alloc] init];
    __block int successes = 0;
    dispatch_group_t group = dispatch_group_create();
    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    for (int index = 0; index < 8; index++) {
        dispatch_group_async(group, queue, ^{
            GPSLabBookmark *bookmark = makeBookmark(@"Race", 24.7136, 46.6753, 1.0);
            if ([gStore addBookmarkIfNotDuplicate:bookmark]) {
                [counterLock lock];
                successes++;
                [counterLock unlock];
            }
        });
    }
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    CHECK(successes == 1, @"concurrent duplicate insert allows exactly one");
    CHECK([gStore loadBookmarks].count == 1, @"concurrent insert stores exactly one");
    endStore();
}

static void test_reopen_keep_last_independent(void) {
    beginStore();
    GPSLabConfiguration *configuration = [GPSLabConfiguration defaultConfiguration];
    configuration.keepLastCoordinate = YES;
    configuration.latitude = 24.7136;
    configuration.longitude = 46.6753;
    [gStore saveConfiguration:configuration];
    [gStore savePendingSelection:[[GPSLabPendingSelection alloc] initWithLatitude:1.0
                                                                       longitude:2.0
                                                                        altitude:3.0
                                                                         heading:0.0
                                                                     providerKey:nil]];

    GPSLabConfiguration *reopenedConfiguration = [reopenedStore() loadConfiguration];
    CHECK(reopenedConfiguration.keepLastCoordinate, @"reopen keeps keepLast YES");
    CHECK(fabs(reopenedConfiguration.latitude - 24.7136) < 1e-9, @"reopen keeps the committed latitude");
    CHECK(reopenedStore().loadPendingSelection != nil, @"reopen keeps the draft");

    [gStore clearPendingSelection];
    CHECK([reopenedStore() loadConfiguration].keepLastCoordinate, @"clearing the draft never flips keepLast");

    configuration.keepLastCoordinate = NO;
    [gStore saveConfiguration:configuration];
    GPSLabConfiguration *off = [reopenedStore() loadConfiguration];
    CHECK(!off.keepLastCoordinate, @"keepLast off persists across reopen");
    CHECK(fabs(off.latitude) < 1e-9 && fabs(off.longitude) < 1e-9,
          @"keepLast off hides the coordinate on load");
    endStore();
}

static void test_drift_config_backward_compatible(void) {
    beginStore();
    // A fresh/absent configuration uses the production drift default.
    GPSLabConfiguration *fresh = [gStore loadConfiguration];
    CHECK(fabs(fresh.driftRadiusMeters - 5.0) < 1e-9, @"missing drift data defaults to 5 m");
    CHECK(fresh.driftEnabled, @"drift defaults to enabled");
    endStore();

    // A legacy dictionary without the drift radius key parses to 5 m, still enabled.
    NSDictionary *legacy = @{ @"enabled": @YES, @"latitude": @(24.7136), @"longitude": @(46.6753) };
    GPSLabConfiguration *parsed = [GPSLabConfiguration configurationFromDictionary:legacy];
    CHECK(fabs(parsed.driftRadiusMeters - 5.0) < 1e-9,
          @"legacy config without a drift radius defaults to 5 m");
    CHECK(parsed.driftEnabled, @"legacy config keeps drift enabled by default");

    // A legacy out-of-range radius is clamped into [0, 50], never rejected.
    NSDictionary *oversized = @{ @"driftRadiusMeters": @(999.0) };
    CHECK(fabs([GPSLabConfiguration configurationFromDictionary:oversized].driftRadiusMeters - 50.0) < 1e-9,
          @"legacy oversized radius clamps to 50 m");
    NSDictionary *negative = @{ @"driftRadiusMeters": @(-3.0) };
    CHECK(fabs([GPSLabConfiguration configurationFromDictionary:negative].driftRadiusMeters) < 1e-9,
          @"legacy negative radius clamps to 0 m");
}

#pragma mark - Auto-saved drift radius preference

static void test_drift_radius_preference(void) {
    beginStore();

    // First launch: nothing auto-saved, so the configuration default (5 m) is used.
    CHECK([gStore loadDriftRadiusMeters] == nil, @"fresh store has no auto-saved radius");
    CHECK(fabs([gStore loadConfiguration].driftRadiusMeters - 5.0) < 1e-9,
          @"first launch uses the 5 m default");

    // A changed value persists and is restored on a fresh defaults instance (relaunch).
    [gStore saveDriftRadiusMeters:20.0];
    CHECK([gStore loadDriftRadiusMeters] != nil &&
          fabs([gStore loadDriftRadiusMeters].doubleValue - 20.0) < 1e-9,
          @"20 m round-trips");
    CHECK(fabs(reopenedStore().loadConfiguration.driftRadiusMeters - 20.0) < 1e-9,
          @"relaunch restores the saved 20 m radius without an Apply");

    // The new maximum persists across a relaunch too.
    [gStore saveDriftRadiusMeters:50.0];
    CHECK(fabs(reopenedStore().loadConfiguration.driftRadiusMeters - 50.0) < 1e-9,
          @"relaunch restores the saved 50 m radius without an Apply");

    // A stale out-of-range value clamps safely instead of loading raw.
    [gStore saveDriftRadiusMeters:999.0];
    CHECK([gStore loadDriftRadiusMeters] != nil &&
          fabs([gStore loadDriftRadiusMeters].doubleValue - 50.0) < 1e-9,
          @"oversized saved radius clamps to the 50 m maximum");
    [gStore saveDriftRadiusMeters:-10.0];
    CHECK([gStore loadDriftRadiusMeters] != nil &&
          fabs([gStore loadDriftRadiusMeters].doubleValue) < 1e-9,
          @"negative saved radius clamps to 0 m");

    // Disabling then re-enabling drift retains the auto-saved radius (the preference
    // is independent of the enabled flag and the committed configuration).
    [gStore saveDriftRadiusMeters:30.0];
    GPSLabConfiguration *disabled = [gStore loadConfiguration];
    disabled.driftEnabled = NO;
    [gStore saveConfiguration:disabled];
    CHECK(![gStore loadConfiguration].driftEnabled &&
          fabs([gStore loadConfiguration].driftRadiusMeters - 30.0) < 1e-9,
          @"a disabled drift config retains the saved radius");
    GPSLabConfiguration *enabled = [gStore loadConfiguration];
    enabled.driftEnabled = YES;
    [gStore saveConfiguration:enabled];
    CHECK([gStore loadConfiguration].driftEnabled &&
          fabs([gStore loadConfiguration].driftRadiusMeters - 30.0) < 1e-9,
          @"re-enabling drift retains the saved radius");

    // Saving the preference never overwrites the persisted coordinate/other fields;
    // the overlay only replaces the radius of the loaded configuration.
    GPSLabConfiguration *kept = [gStore loadConfiguration];
    kept.latitude = 24.5;
    kept.longitude = 46.5;
    kept.altitude = 111.0;
    kept.heading = 12.0;
    kept.driftRadiusMeters = 7.0;
    [gStore saveConfiguration:kept];
    [gStore saveDriftRadiusMeters:44.0];
    GPSLabConfiguration *again = [gStore loadConfiguration];
    CHECK(fabs(again.latitude - 24.5) < 1e-9 && fabs(again.longitude - 46.5) < 1e-9 &&
          fabs(again.altitude - 111.0) < 1e-9 && fabs(again.heading - 12.0) < 1e-9,
          @"saving the drift radius never overwrites the coordinate");
    CHECK(fabs(again.driftRadiusMeters - 44.0) < 1e-9,
          @"the saved radius overlays the loaded configuration radius");

    // Regression: an unrelated engine/config save repeats the radius the persisted
    // configuration already holds and must NOT erase an in-flight slider draft.
    // Establish a persisted configuration radius of 5 m (a genuine 7 -> 5 commit).
    GPSLabConfiguration *baseline = [gStore loadConfiguration];
    baseline.driftRadiusMeters = 5.0;
    [gStore saveConfiguration:baseline];
    // The user drags the slider to 20 m without applying: only the draft changes.
    [gStore saveDriftRadiusMeters:20.0];
    // An unrelated save repeats the already-persisted 5 m radius.
    GPSLabConfiguration *unrelated = [gStore loadConfiguration];
    unrelated.driftRadiusMeters = 5.0;
    [gStore saveConfiguration:unrelated];
    CHECK([gStore loadDriftRadiusMeters] != nil &&
          fabs([gStore loadDriftRadiusMeters].doubleValue - 20.0) < 1e-9,
          @"an unrelated same-radius save leaves the draft preference untouched");
    CHECK(fabs(reopenedStore().loadConfiguration.driftRadiusMeters - 20.0) < 1e-9,
          @"relaunch after an unrelated save resumes the draft 20 m, not the stale 5 m");

    // A GENUINE radius change (5 -> 7) stays authoritative and beats the draft.
    GPSLabConfiguration *changed = [gStore loadConfiguration];
    changed.driftRadiusMeters = 7.0;
    [gStore saveConfiguration:changed];
    CHECK(fabs(reopenedStore().loadConfiguration.driftRadiusMeters - 7.0) < 1e-9,
          @"a genuinely changed committed radius updates the preference to 7 m");

    // Corrupt stored values are ignored (nil), never crash and never fabricate.
    [gDefaults setObject:@"nope" forKey:@"GPSLab.driftRadius"];
    [gDefaults synchronize];
    CHECK([gStore loadDriftRadiusMeters] == nil, @"non-numeric stored radius ignored");
    [gDefaults setBool:YES forKey:@"GPSLab.driftRadius"];
    [gDefaults synchronize];
    CHECK([gStore loadDriftRadiusMeters] == nil, @"boolean stored radius ignored");
    [gDefaults setObject:@[ @1 ] forKey:@"GPSLab.driftRadius"];
    [gDefaults synchronize];
    CHECK([gStore loadDriftRadiusMeters] == nil, @"non-number stored radius ignored");

    endStore();
}

/**
 * The first configuration save has no previously persisted radius to compare
 * against, so it must seed the preference from the committed value when the user
 * has never set one, and preserve an already-saved draft preference otherwise.
 */
static void test_drift_radius_first_config_save(void) {
    beginStore();

    CHECK([gStore loadDriftRadiusMeters] == nil, @"fresh store has no draft preference");
    [gStore saveConfiguration:[GPSLabConfiguration defaultConfiguration]];  // 5 m
    CHECK([gStore loadDriftRadiusMeters] != nil &&
          fabs([gStore loadDriftRadiusMeters].doubleValue - 5.0) < 1e-9,
          @"first config save seeds the preference from the committed radius");
    CHECK(fabs(reopenedStore().loadConfiguration.driftRadiusMeters - 5.0) < 1e-9,
          @"the seeded first-save preference survives a relaunch");

    endStore();

    // A draft preference already exists before the first configuration save: the
    // draft wins, because an unrelated first save must not erase an unapplied edit.
    beginStore();
    [gStore saveDriftRadiusMeters:20.0];
    GPSLabConfiguration *first = [gStore loadConfiguration];
    first.driftRadiusMeters = 5.0;
    [gStore saveConfiguration:first];
    CHECK([gStore loadDriftRadiusMeters] != nil &&
          fabs([gStore loadDriftRadiusMeters].doubleValue - 20.0) < 1e-9,
          @"first config save preserves an explicit draft preference");
    CHECK(fabs(reopenedStore().loadConfiguration.driftRadiusMeters - 20.0) < 1e-9,
          @"the preserved first-save draft survives a relaunch");

    endStore();
}

#pragma mark - Map style preference (UI only)

static void test_map_style_preference(void) {
    beginStore();

    // Missing value resolves to Satellite.
    CHECK([gStore loadMapStyle] == GPSLabMapStyleSatellite, @"missing map style defaults to satellite");

    // All three valid styles roundtrip, including across a fresh defaults instance.
    [gStore saveMapStyle:GPSLabMapStyleStandard];
    CHECK([gStore loadMapStyle] == GPSLabMapStyleStandard, @"standard persists");
    CHECK(reopenedStore().loadMapStyle == GPSLabMapStyleStandard, @"standard survives reopen");
    [gStore saveMapStyle:GPSLabMapStyleHybrid];
    CHECK([gStore loadMapStyle] == GPSLabMapStyleHybrid, @"hybrid persists");
    [gStore saveMapStyle:GPSLabMapStyleSatellite];
    CHECK([gStore loadMapStyle] == GPSLabMapStyleSatellite, @"satellite persists");

    // Invalid stored values resolve to Satellite (wrong type / boolean / out-of-range).
    [gDefaults setInteger:99 forKey:@"GPSLab.mapStyle"];
    [gDefaults synchronize];
    CHECK([gStore loadMapStyle] == GPSLabMapStyleSatellite, @"out-of-range style falls back to satellite");
    [gDefaults setInteger:-1 forKey:@"GPSLab.mapStyle"];
    [gDefaults synchronize];
    CHECK([gStore loadMapStyle] == GPSLabMapStyleSatellite, @"negative style falls back to satellite");
    [gDefaults setObject:@"hybrid" forKey:@"GPSLab.mapStyle"];
    [gDefaults synchronize];
    CHECK([gStore loadMapStyle] == GPSLabMapStyleSatellite, @"non-numeric style falls back to satellite");
    [gDefaults setBool:NO forKey:@"GPSLab.mapStyle"];
    [gDefaults synchronize];
    CHECK([gStore loadMapStyle] == GPSLabMapStyleSatellite, @"boolean style falls back to satellite");

    // An out-of-range save never stores a value outside the three styles.
    [gStore saveMapStyle:(GPSLabMapStyle)42];
    CHECK([gStore loadMapStyle] == GPSLabMapStyleSatellite, @"out-of-range save stores satellite");

    // The preference is independent of the configuration/profile schema.
    [gStore saveMapStyle:GPSLabMapStyleHybrid];
    GPSLabConfiguration *configuration = [gStore loadConfiguration];
    CHECK(![[configuration dictionaryRepresentation].allKeys containsObject:@"mapStyle"],
          @"the map style is not part of the persisted configuration");

    endStore();
}

int main(void) {
    @autoreleasepool {
        test_pending_roundtrip();
        test_pending_altitude();
        test_pending_corrupt();
        test_committed_receipt();
        test_favorite_zero_policy();
        test_duplicate_add();
        test_rename_delete_persist();
        test_existing_data_untouched();
        test_store_isolation();
        test_commit_clear_lifecycle();
        test_altitude_overwrite_survives_reopen();
        test_near_origin_proof();
        test_add_rejects_invalid_altitude();
        test_concurrent_duplicate_insert();
        test_reopen_keep_last_independent();
        test_drift_config_backward_compatible();
        test_drift_radius_preference();
        test_drift_radius_first_config_save();
        test_map_style_preference();

        if (gFailures != 0) {
            fprintf(stderr, "%d/%d checks failed\n", gFailures, gChecks);
            return 1;
        }
        printf("ok: %d store checks passed\n", gChecks);
    }
    return 0;
}
