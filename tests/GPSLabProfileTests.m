//
//  GPSLabProfileTests.m
//  GPSLab
//
//  Real Foundation tests for the profile model + store: schema parsing,
//  corruption handling, quarantine, atomic repeated writes, capacity and
//  selection — all in an injected temporary directory (no host data).
//
//  Build/run (macOS):
//    clang -fobjc-arc -fmodules -framework Foundation -framework CoreLocation \
//      -ISource tests/GPSLabProfileTests.m Source/GPSLabProfile.m \
//      Source/GPSLabProfileStore.m Source/GPSLabProfileCore.c -o /tmp/gpslab-profile-tests
//    /tmp/gpslab-profile-tests
//

#import <Foundation/Foundation.h>

#include <math.h>

#import "GPSLabProfile.h"
#import "GPSLabProfileStore.h"

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

static NSDictionary *ValidProfileDictionary(NSString *identifier, NSString *name) {
    return @{
        @"id": identifier,
        @"name": name,
        @"locationMode": @(GPSLabProfileLocationStatic),
        @"latitude": @(24.7136),
        @"longitude": @(46.6753),
        @"altitude": @(612.0),
        @"heading": @(-1.0),
        @"driftEnabled": @YES,
        @"driftRadiusMeters": @(30.0),
    };
}

static NSDictionary *ValidRouteDictionary(void) {
    return @{
        @"startLatitude": @(24.7136),
        @"startLongitude": @(46.6753),
        @"endLatitude": @(24.7749),
        @"endLongitude": @(46.7386),
        @"altitude": @(612.0),
        @"heading": @(-1.0),
        @"mode": @(0),
        @"customSpeedKmh": @(50.0),
    };
}

static NSDictionary *ValidWiFiDictionary(void) {
    return @{ @"profileName": @"Home net", @"ssid": @"GPSLab-Test", @"signal": @(80) };
}

static NSDictionary *ValidBLEDictionary(void) {
    return @{ @"profileName": @"BLE test", @"deviceName": @"GPSLab BLE",
              @"rssi": @(-60), @"pattern": @"public" };
}

static NSDictionary *ValidScheduleDictionary(void) {
    return @{ @"mode": @(GPSLabProfileScheduleOnce), @"startEpoch": @(1900000000),
              @"endEpoch": @(1900000000), @"timeZoneOffsetSeconds": @(10800) };
}

static void test_model_parsing(void) {
    GPSLabProfile *profile = [GPSLabProfile profileFromDictionary:ValidProfileDictionary(@"id-1", @"Home")];
    CHECK(profile != nil, @"valid static profile parses");
    CHECK([profile.identifier isEqualToString:@"id-1"], @"identifier preserved");
    CHECK([profile.name isEqualToString:@"Home"], @"name preserved");
    CHECK(profile.locationMode == GPSLabProfileLocationStatic, @"static mode preserved");
    CHECK(profile.driftEnabled, @"drift preserved");

    NSDictionary *round = [profile dictionaryRepresentation];
    GPSLabProfile *again = [GPSLabProfile profileFromDictionary:round];
    CHECK(again != nil, @"round-trip parses");
    CHECK([again.identifier isEqualToString:profile.identifier], @"round-trip id");
    CHECK([again.name isEqualToString:profile.name], @"round-trip name");

    // Route profile.
    NSMutableDictionary *routeDict = [ValidProfileDictionary(@"id-route", @"Riyadh test") mutableCopy];
    routeDict[@"locationMode"] = @(GPSLabProfileLocationRoute);
    routeDict[@"route"] = ValidRouteDictionary();
    GPSLabProfile *route = [GPSLabProfile profileFromDictionary:routeDict];
    CHECK(route != nil, @"valid route profile parses");
    CHECK(route.route != nil, @"route block preserved");
    CHECK(route.route.mode == GPSLabRouteModeDriving, @"route mode preserved");

    // Attachments.
    NSMutableDictionary *full = [ValidProfileDictionary(@"id-full", @"Full") mutableCopy];
    full[@"wifi"] = ValidWiFiDictionary();
    full[@"bluetooth"] = ValidBLEDictionary();
    full[@"schedule"] = ValidScheduleDictionary();
    GPSLabProfile *withAttachments = [GPSLabProfile profileFromDictionary:full];
    CHECK(withAttachments != nil, @"profile with attachments parses");
    CHECK(withAttachments.wifi != nil, @"wifi attachment preserved");
    CHECK(withAttachments.bluetooth != nil, @"bluetooth attachment preserved");
    CHECK(withAttachments.schedule != nil, @"schedule attachment preserved");
}

static void test_model_rejection(void) {
    NSMutableDictionary *dict = [ValidProfileDictionary(@"id", @"X") mutableCopy];
    dict[@"latitude"] = [NSNull null];
    CHECK([GPSLabProfile profileFromDictionary:dict] == nil, @"NSNull coordinate rejected");

    dict = [ValidProfileDictionary(@"id", @"X") mutableCopy];
    dict[@"latitude"] = @YES;
    CHECK([GPSLabProfile profileFromDictionary:dict] == nil, @"boolean coordinate rejected");

    dict = [ValidProfileDictionary(@"id", @"X") mutableCopy];
    dict[@"latitude"] = @(NAN);
    CHECK([GPSLabProfile profileFromDictionary:dict] == nil, @"non-finite coordinate rejected");

    dict = [ValidProfileDictionary(@"id", @"X") mutableCopy];
    dict[@"latitude"] = @(91.0);
    CHECK([GPSLabProfile profileFromDictionary:dict] == nil, @"out-of-range coordinate rejected");

    dict = [ValidProfileDictionary(@"id", @"X") mutableCopy];
    dict[@"locationMode"] = @(9);
    CHECK([GPSLabProfile profileFromDictionary:dict] == nil, @"invalid location mode rejected");

    dict = [ValidProfileDictionary(@"id", @"X") mutableCopy];
    dict[@"name"] = @"";
    CHECK([GPSLabProfile profileFromDictionary:dict] == nil, @"empty name rejected");

    dict = [ValidProfileDictionary(@"id", @"X") mutableCopy];
    dict[@"driftRadiusMeters"] = @(0.5);
    CHECK([GPSLabProfile profileFromDictionary:dict] == nil, @"out-of-range drift radius rejected");

    // Route mode without a route block is rejected.
    dict = [ValidProfileDictionary(@"id", @"X") mutableCopy];
    dict[@"locationMode"] = @(GPSLabProfileLocationRoute);
    CHECK([GPSLabProfile profileFromDictionary:dict] == nil, @"route mode without route rejected");

    // Present-but-invalid attachment rejects the profile.
    dict = [ValidProfileDictionary(@"id", @"X") mutableCopy];
    dict[@"wifi"] = @{ @"profileName": @"a", @"ssid": @"b", @"signal": @(500) };
    CHECK([GPSLabProfile profileFromDictionary:dict] == nil, @"invalid wifi attachment rejected");

    dict = [ValidProfileDictionary(@"id", @"X") mutableCopy];
    dict[@"schedule"] = @{ @"mode": @(1), @"startEpoch": @(2000), @"endEpoch": @(1000),
                           @"timeZoneOffsetSeconds": @(0) };
    CHECK([GPSLabProfile profileFromDictionary:dict] == nil, @"invalid schedule rejected");

    CHECK([GPSLabProfile profileFromDictionary:(NSDictionary *)@[]] == nil, @"non-dictionary rejected");
}

static void test_attachment_clearing(void) {
    NSMutableDictionary *full = [ValidProfileDictionary(@"id", @"Full") mutableCopy];
    full[@"wifi"] = ValidWiFiDictionary();
    full[@"bluetooth"] = ValidBLEDictionary();
    full[@"schedule"] = ValidScheduleDictionary();
    GPSLabProfile *profile = [GPSLabProfile profileFromDictionary:full];
    CHECK(profile.wifi != nil && profile.bluetooth != nil && profile.schedule != nil,
          @"attachments present before clearing");
    GPSLabProfile *cleared = [profile profileWithWiFi:nil bluetooth:nil schedule:nil];
    CHECK(cleared.wifi == nil && cleared.bluetooth == nil && cleared.schedule == nil,
          @"clearing removes every attachment (no stale config)");
    CHECK([cleared.identifier isEqualToString:profile.identifier], @"clearing keeps identifier");
    CHECK(cleared.dictionaryRepresentation[@"wifi"] == nil, @"cleared wifi absent from dictionary");
}

static NSURL *MakeTemporaryDirectory(void) {
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"gpslab-profiles-%@", [[NSUUID UUID] UUIDString]]];
    [[NSFileManager defaultManager] createDirectoryAtPath:path
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
    return [NSURL fileURLWithPath:path isDirectory:YES];
}

static void test_store_roundtrip(void) {
    NSURL *directory = MakeTemporaryDirectory();
    GPSLabProfileStore *store = [[GPSLabProfileStore alloc] initWithDirectoryURL:directory];
    CHECK(store.loadProfiles.count == 0, @"new store is empty");

    GPSLabProfile *profile = [GPSLabProfile profileFromDictionary:ValidProfileDictionary(@"a", @"Home")];
    NSError *error = nil;
    CHECK([store addProfile:profile error:&error], @"add profile succeeds");
    CHECK(store.loadProfiles.count == 1, @"profile persisted");
    CHECK([store.loadProfiles.firstObject.name isEqualToString:@"Home"], @"persisted name matches");

    CHECK([store setSelectedProfileIdentifier:@"a" error:&error], @"select profile succeeds");
    CHECK([store.selectedProfileIdentifier isEqualToString:@"a"], @"selection persisted");

    GPSLabProfile *renamed = [profile profileWithName:@"Home 2"];
    CHECK([store updateProfile:renamed error:&error], @"update profile succeeds");
    CHECK([store.loadProfiles.firstObject.name isEqualToString:@"Home 2"], @"update persisted");

    CHECK([store deleteProfileWithIdentifier:@"a" error:&error], @"delete profile succeeds");
    CHECK(store.loadProfiles.count == 0, @"delete persisted");
    CHECK(store.selectedProfileIdentifier == nil, @"selection cleared with its profile");
    CHECK(![store deleteProfileWithIdentifier:@"a" error:&error], @"deleting missing profile fails");

    [[NSFileManager defaultManager] removeItemAtURL:directory error:NULL];
}

static void test_store_atomic_repeated_writes(void) {
    NSURL *directory = MakeTemporaryDirectory();
    GPSLabProfileStore *store = [[GPSLabProfileStore alloc] initWithDirectoryURL:directory];
    NSError *error = nil;
    for (NSUInteger index = 0; index < 20; index++) {
        GPSLabProfile *profile = [GPSLabProfile profileFromDictionary:
            ValidProfileDictionary([NSString stringWithFormat:@"id-%lu", (unsigned long)index],
                                   [NSString stringWithFormat:@"P%lu", (unsigned long)index])];
        CHECK([store addProfile:profile error:&error], @"repeated add succeeds");
        CHECK(store.loadProfiles.count == index + 1, @"count grows by one each write");
    }
    CHECK(store.loadProfiles.count == 20, @"all profiles persisted after repeated writes");

    // The file must always be valid JSON (atomic writes never leave a partial file).
    NSData *data = [NSData dataWithContentsOfURL:store.fileURL];
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    CHECK([root isKindOfClass:[NSDictionary class]], @"persisted file is valid JSON");

    [[NSFileManager defaultManager] removeItemAtURL:directory error:NULL];
}

static void test_store_capacity(void) {
    NSURL *directory = MakeTemporaryDirectory();
    GPSLabProfileStore *store = [[GPSLabProfileStore alloc] initWithDirectoryURL:directory];
    NSError *error = nil;
    for (NSUInteger index = 0; index < (NSUInteger)GPSLAB_PROFILE_MAX_COUNT; index++) {
        GPSLabProfile *profile = [GPSLabProfile profileFromDictionary:
            ValidProfileDictionary([NSString stringWithFormat:@"cap-%lu", (unsigned long)index], @"P")];
        CHECK([store addProfile:profile error:&error], @"add up to the cap succeeds");
    }
    GPSLabProfile *overflow = [GPSLabProfile profileFromDictionary:ValidProfileDictionary(@"overflow", @"X")];
    CHECK(![store addProfile:overflow error:&error], @"add beyond the cap fails");
    CHECK(error.code == GPSLabProfileStoreErrorCapacity, @"capacity error code");
    [[NSFileManager defaultManager] removeItemAtURL:directory error:NULL];
}

static void test_store_corruption_quarantine(void) {
    NSURL *directory = MakeTemporaryDirectory();
    GPSLabProfileStore *store = [[GPSLabProfileStore alloc] initWithDirectoryURL:directory];
    [@"not json at all" writeToURL:store.fileURL atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    CHECK(store.loadProfiles.count == 0, @"corrupt file loads empty instead of crashing");

    NSArray<NSURL *> *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:directory
                                                               includingPropertiesForKeys:nil
                                                                                  options:0
                                                                                    error:NULL];
    BOOL quarantined = NO;
    for (NSURL *url in contents) {
        if ([url.lastPathComponent hasPrefix:@"profiles.corrupt-"]) {
            quarantined = YES;
        }
    }
    CHECK(quarantined, @"corrupt file is quarantined");

    // Schema mismatch is also quarantined.
    NSDictionary *future = @{ @"schemaVersion": @(99), @"profiles": @[] };
    NSData *data = [NSJSONSerialization dataWithJSONObject:future options:0 error:NULL];
    [data writeToURL:store.fileURL options:NSDataWritingAtomic error:NULL];
    CHECK(store.loadProfiles.count == 0, @"future schema loads empty");
    [[NSFileManager defaultManager] removeItemAtURL:directory error:NULL];
}

static void test_store_skips_malformed_entries(void) {
    NSURL *directory = MakeTemporaryDirectory();
    GPSLabProfileStore *store = [[GPSLabProfileStore alloc] initWithDirectoryURL:directory];
    NSDictionary *root = @{
        @"schemaVersion": @(GPSLAB_PROFILE_SCHEMA_VERSION),
        @"profiles": @[
            [NSNull null],
            @{ @"id": @(5), @"name": @"bad" },
            ValidProfileDictionary(@"good", @"Good"),
        ],
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:root options:0 error:NULL];
    [data writeToURL:store.fileURL options:NSDataWritingAtomic error:NULL];
    NSArray<GPSLabProfile *> *profiles = store.loadProfiles;
    CHECK(profiles.count == 1, @"malformed entries skipped, valid retained");
    CHECK([profiles.firstObject.identifier isEqualToString:@"good"], @"valid entry retained");
    [[NSFileManager defaultManager] removeItemAtURL:directory error:NULL];
}

static void test_schema_version_strict(void) {
    NSURL *directory = MakeTemporaryDirectory();
    GPSLabProfileStore *store = [[GPSLabProfileStore alloc] initWithDirectoryURL:directory];
    NSArray<NSNumber *> *badVersions = @[@YES, @NO, @1.5, @(1e100), @(-1)];
    for (NSNumber *version in badVersions) {
        NSDictionary *root = @{ @"schemaVersion": version, @"profiles": @[] };
        NSData *data = [NSJSONSerialization dataWithJSONObject:root options:0 error:NULL];
        [data writeToURL:store.fileURL options:NSDataWritingAtomic error:NULL];
        CHECK(store.loadProfiles.count == 0, @"non-integral/invalid schema version is rejected");
    }
    [[NSFileManager defaultManager] removeItemAtURL:directory error:NULL];
}

static void test_duplicate_ids_deterministic(void) {
    NSURL *directory = MakeTemporaryDirectory();
    GPSLabProfileStore *store = [[GPSLabProfileStore alloc] initWithDirectoryURL:directory];
    NSDictionary *root = @{
        @"schemaVersion": @(GPSLAB_PROFILE_SCHEMA_VERSION),
        @"profiles": @[
            ValidProfileDictionary(@"dup", @"First"),
            ValidProfileDictionary(@"dup", @"Second"),
        ],
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:root options:0 error:NULL];
    [data writeToURL:store.fileURL options:NSDataWritingAtomic error:NULL];
    NSArray<GPSLabProfile *> *profiles = store.loadProfiles;
    CHECK(profiles.count == 1, @"duplicate ids collapse to one");
    CHECK([profiles.firstObject.name isEqualToString:@"First"], @"first occurrence wins");
    [[NSFileManager defaultManager] removeItemAtURL:directory error:NULL];
}

static void test_read_cap_exact_fifty(void) {
    NSURL *directory = MakeTemporaryDirectory();
    GPSLabProfileStore *store = [[GPSLabProfileStore alloc] initWithDirectoryURL:directory];
    NSMutableArray *entries = [NSMutableArray array];
    for (NSUInteger index = 0; index < 60; index++) {
        [entries addObject:ValidProfileDictionary([NSString stringWithFormat:@"cap-%lu", (unsigned long)index], @"P")];
    }
    NSDictionary *root = @{ @"schemaVersion": @(GPSLAB_PROFILE_SCHEMA_VERSION), @"profiles": entries };
    NSData *data = [NSJSONSerialization dataWithJSONObject:root options:0 error:NULL];
    [data writeToURL:store.fileURL options:NSDataWritingAtomic error:NULL];
    CHECK(store.loadProfiles.count == GPSLAB_PROFILE_MAX_COUNT, @"read caps at exactly 50");
    [[NSFileManager defaultManager] removeItemAtURL:directory error:NULL];
}

static void test_oversize_file_quarantined(void) {
    NSURL *directory = MakeTemporaryDirectory();
    GPSLabProfileStore *store = [[GPSLabProfileStore alloc] initWithDirectoryURL:directory];
    NSMutableData *huge = [NSMutableData dataWithLength:2 * 1024 * 1024];
    [huge writeToURL:store.fileURL options:NSDataWritingAtomic error:NULL];
    CHECK(store.loadProfiles.count == 0, @"oversized file loads empty");
    NSArray<NSURL *> *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:directory
                                                               includingPropertiesForKeys:nil
                                                                                  options:0
                                                                                    error:NULL];
    BOOL quarantined = NO;
    for (NSURL *url in contents) {
        if ([url.lastPathComponent hasPrefix:@"profiles.corrupt-"]) {
            quarantined = YES;
        }
    }
    CHECK(quarantined, @"oversized file quarantined");
    [[NSFileManager defaultManager] removeItemAtURL:directory error:NULL];
}

static void test_atomic_failure_preserves_old_record(void) {
    NSURL *directory = MakeTemporaryDirectory();
    GPSLabProfileStore *store = [[GPSLabProfileStore alloc] initWithDirectoryURL:directory];
    NSError *error = nil;
    CHECK([store addProfile:[GPSLabProfile profileFromDictionary:ValidProfileDictionary(@"keep", @"Keep")]
                      error:&error], @"initial profile saved");
    // A malformed typed profile must fail validation and NOT overwrite the file.
    GPSLabProfile *bad = [[GPSLabProfile alloc] initWithIdentifier:@"bad"
                                                               name:@"Bad"
                                                       locationMode:GPSLabProfileLocationRoute
                                                          latitude:24.0
                                                         longitude:46.0
                                                          altitude:0.0
                                                           heading:-1.0
                                                      driftEnabled:NO
                                                 driftRadiusMeters:30.0
                                                             route:nil
                                                              wifi:nil
                                                         bluetooth:nil
                                                          schedule:nil];
    CHECK(![store addProfile:bad error:&error], @"malformed add fails");
    CHECK(error.code == GPSLabProfileStoreErrorInvalidProfile, @"invalid-profile error surfaced");
    NSArray<GPSLabProfile *> *profiles = store.loadProfiles;
    CHECK(profiles.count == 1, @"old record preserved after a failed write");
    CHECK([profiles.firstObject.identifier isEqualToString:@"keep"], @"old record intact");
    [[NSFileManager defaultManager] removeItemAtURL:directory error:NULL];
}

static void test_nonfinite_and_huge_rejected(void) {
    NSMutableDictionary *dict = [ValidProfileDictionary(@"x", @"X") mutableCopy];
    dict[@"locationMode"] = @(1e100);
    CHECK([GPSLabProfile profileFromDictionary:dict] == nil, @"huge location mode rejected");

    dict = [ValidProfileDictionary(@"x", @"X") mutableCopy];
    dict[@"driftRadiusMeters"] = @(1e100);
    CHECK([GPSLabProfile profileFromDictionary:dict] == nil, @"huge drift radius rejected");

    dict = [ValidProfileDictionary(@"x", @"X") mutableCopy];
    dict[@"driftEnabled"] = @(2);
    CHECK([GPSLabProfile profileFromDictionary:dict] == nil, @"non-boolean bool rejected");

    dict = [ValidProfileDictionary(@"x", @"X") mutableCopy];
    dict[@"driftEnabled"] = @(-1);
    CHECK([GPSLabProfile profileFromDictionary:dict] == nil, @"negative bool rejected");
}

static void test_is_valid_for_application(void) {
    GPSLabProfile *valid = [GPSLabProfile profileFromDictionary:ValidProfileDictionary(@"v", @"V")];
    CHECK([valid isValidForApplication], @"valid profile passes preflight");

    GPSLabProfile *nilRoute = [[GPSLabProfile alloc] initWithIdentifier:@"b"
                                                                   name:@"B"
                                                           locationMode:GPSLabProfileLocationRoute
                                                              latitude:24.0
                                                             longitude:46.0
                                                              altitude:0.0
                                                               heading:-1.0
                                                          driftEnabled:NO
                                                     driftRadiusMeters:30.0
                                                                 route:nil
                                                                  wifi:nil
                                                             bluetooth:nil
                                                              schedule:nil];
    CHECK(![nilRoute isValidForApplication], @"route with nil route fails preflight");

    // Parser canonicalization: a static entry that carries a route payload is
    // accepted and the irrelevant route block is dropped (never an active route).
    NSMutableDictionary *staticWithRoute = [ValidProfileDictionary(@"s", @"S") mutableCopy];
    staticWithRoute[@"route"] = ValidRouteDictionary();
    GPSLabProfile *parsed = [GPSLabProfile profileFromDictionary:staticWithRoute];
    CHECK(parsed != nil, @"static entry with a route payload parses");
    CHECK(parsed.route == nil, @"parser drops the irrelevant route block for static");
    CHECK([parsed isValidForApplication], @"canonicalized static profile passes preflight");

    // Canonical round-trip keeps identifier/coordinates and stays route-free.
    NSDictionary *round = [parsed dictionaryRepresentation];
    GPSLabProfile *again = [GPSLabProfile profileFromDictionary:round];
    CHECK(again != nil, @"canonical round-trip parses");
    CHECK([again.identifier isEqualToString:@"s"], @"round-trip keeps the identifier");
    CHECK(fabs(again.latitude - 24.7136) < 1e-9 && fabs(again.longitude - 46.6753) < 1e-9,
          @"round-trip keeps the coordinates");
    CHECK(round[@"route"] == nil, @"canonical representation has no route block");

    // The type guard rejects a typed static profile that still carries a route.
    GPSLabProfileRoute *route = [[GPSLabProfileRoute alloc] initWithStartLatitude:24.7136
                                                                    startLongitude:46.6753
                                                                      endLatitude:24.7749
                                                                    endLongitude:46.7386
                                                                          altitude:612.0
                                                                           heading:-1.0
                                                                              mode:GPSLabRouteModeDriving
                                                                    customSpeedKmh:50.0];
    GPSLabProfile *typedStaticWithRoute = [[GPSLabProfile alloc] initWithIdentifier:@"ts"
                                                                               name:@"TS"
                                                                       locationMode:GPSLabProfileLocationStatic
                                                                          latitude:24.7136
                                                                         longitude:46.6753
                                                                          altitude:612.0
                                                                           heading:-1.0
                                                                      driftEnabled:NO
                                                                 driftRadiusMeters:30.0
                                                                             route:route
                                                                              wifi:nil
                                                                         bluetooth:nil
                                                                          schedule:nil];
    CHECK(![typedStaticWithRoute isValidForApplication],
          @"typed static profile carrying a route fails preflight");
}

int main(void) {
    @autoreleasepool {
        test_model_parsing();
        test_model_rejection();
        test_attachment_clearing();
        test_store_roundtrip();
        test_store_atomic_repeated_writes();
        test_store_capacity();
        test_store_corruption_quarantine();
        test_store_skips_malformed_entries();
        test_schema_version_strict();
        test_duplicate_ids_deterministic();
        test_read_cap_exact_fifty();
        test_oversize_file_quarantined();
        test_atomic_failure_preserves_old_record();
        test_nonfinite_and_huge_rejected();
        test_is_valid_for_application();
    }

    if (gFailures == 0) {
        printf("GPSLabProfileTests: %d checks passed\n", gChecks);
        return 0;
    }
    fprintf(stderr, "GPSLabProfileTests: %d/%d checks failed\n", gFailures, gChecks);
    return 1;
}
