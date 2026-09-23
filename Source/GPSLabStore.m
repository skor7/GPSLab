//
//  GPSLabStore.m
//  GPSLab
//
//  NSUserDefaults-backed persistence with a dedicated suite and strict validation.
//  Corrupted entries fall back to safe defaults instead of crashing.
//

#import "GPSLabStore.h"

#import <CoreFoundation/CoreFoundation.h>
#import <math.h>
#import <os/lock.h>

#import "GPSLabGeodesy.h"
#import "GPSLabProfileCore.h"
#import "GPSLabSelectionPolicyCore.h"

static NSString * const kGPSLabSuiteName = @"com.gpslab.runtime";
static NSString * const kGPSLabKeyConfiguration = @"GPSLab.configuration";
static NSString * const kGPSLabKeyBookmarks = @"GPSLab.bookmarks";
static NSString * const kGPSLabKeyRecents = @"GPSLab.recents";
// The pending preview draft is persisted separately from the configuration so a
// preview can survive a close/background without ever being applied.
static NSString * const kGPSLabKeyPendingSelection = @"GPSLab.pendingSelection";
// The committed-selection receipt stores the coordinate (not a boolean) so a
// stale nonzero receipt can never authorize a later reset-to-(0,0).
static NSString * const kGPSLabKeyCommittedSelection = @"GPSLab.committedSelection";
// A persisted UI preference (foreground map style); never part of the profile
// schema or the synthetic configuration.
static NSString * const kGPSLabKeyMapStyle = @"GPSLab.mapStyle";

static NSString * const kGPSLabBookmarkName = @"name";
static NSString * const kGPSLabBookmarkLatitude = @"latitude";
static NSString * const kGPSLabBookmarkLongitude = @"longitude";
static NSString * const kGPSLabBookmarkAltitude = @"altitude";

// Keys of the keep-last coordinate block inside the persisted configuration.
// They are removed explicitly when the user turns keep-last off.
static NSString * const kGPSLabKeyLatitude = @"latitude";
static NSString * const kGPSLabKeyLongitude = @"longitude";
static NSString * const kGPSLabKeyAltitude = @"altitude";
static NSString * const kGPSLabKeyHeading = @"heading";

// Optional provider key of a pending selection (a known localization key only).
static NSString * const kGPSLabKeyProvider = @"provider";

static const NSUInteger kGPSLabMaxRecents = 20;
static const double kGPSLabRecentDedupeMeters = 5.0;

/** YES only for a real NSNumber (rejects strings/null) that is not a boolean. */
static BOOL GPSLabStoreIsBooleanNumber(id value) {
    return CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

/** Strict numeric read: NSNumber, not boolean, finite. Rejects everything else. */
static BOOL GPSLabStoreStrictDouble(NSDictionary *dictionary, NSString *key, double *outValue) {
    id value = dictionary[key];
    if (![value isKindOfClass:[NSNumber class]] || GPSLabStoreIsBooleanNumber(value)) {
        return NO;
    }
    double number = [value doubleValue];
    if (!isfinite(number)) {
        return NO;
    }
    *outValue = number;
    return YES;
}

/** The optional provider is kept only when it is one of the known keys. */
static NSString *GPSLabStoreValidatedProvider(id value) {
    if (![value isKindOfClass:[NSString class]]) {
        return nil;
    }
    NSString *string = (NSString *)value;
    const char *utf8 = string.UTF8String;
    if (utf8 == NULL) {
        return nil;
    }
    if (!GPSLabSelectionProviderKeyKnown(utf8, [string lengthOfBytesUsingEncoding:NSUTF8StringEncoding])) {
        return nil;
    }
    return string;
}

@implementation GPSLabBookmark

+ (instancetype)bookmarkWithName:(NSString *)name
                      coordinate:(CLLocationCoordinate2D)coordinate
                        altitude:(double)altitude {
    GPSLabBookmark *bookmark = [[GPSLabBookmark alloc] init];
    bookmark.name = name.length > 0 ? name : @"Bookmark";
    bookmark.latitude = coordinate.latitude;
    bookmark.longitude = coordinate.longitude;
    bookmark.altitude = altitude;
    return bookmark;
}

- (instancetype)initWithDictionary:(NSDictionary *)dictionary {
    self = [super init];
    if (self) {
        _name = @"Bookmark";
        _latitude = 0.0;
        _longitude = 0.0;
        _altitude = 0.0;

        id nameValue = dictionary[kGPSLabBookmarkName];
        if ([nameValue isKindOfClass:[NSString class]] && [(NSString *)nameValue length] > 0) {
            _name = [(NSString *)nameValue copy];
        }

        id latValue = dictionary[kGPSLabBookmarkLatitude];
        id lonValue = dictionary[kGPSLabBookmarkLongitude];
        id altValue = dictionary[kGPSLabBookmarkAltitude];
        if ([latValue isKindOfClass:[NSNumber class]] && [lonValue isKindOfClass:[NSNumber class]]) {
            double latitude = [latValue doubleValue];
            double longitude = [lonValue doubleValue];
            if (GPSLabIsValidCoordinate(latitude, longitude)) {
                _latitude = latitude;
                _longitude = longitude;
            }
        }
        if ([altValue isKindOfClass:[NSNumber class]]) {
            _altitude = GPSLabClampDouble([altValue doubleValue], -500.0, 100000.0);
        }
    }
    return self;
}

- (NSDictionary *)dictionaryRepresentation {
    return @{
        kGPSLabBookmarkName: self.name,
        kGPSLabBookmarkLatitude: @(self.latitude),
        kGPSLabBookmarkLongitude: @(self.longitude),
        kGPSLabBookmarkAltitude: @(self.altitude),
    };
}

@end

@implementation GPSLabPendingSelection

- (instancetype)initWithLatitude:(double)latitude
                       longitude:(double)longitude
                        altitude:(double)altitude
                         heading:(double)heading
                     providerKey:(nullable NSString *)providerKey {
    self = [super init];
    if (self) {
        _latitude = latitude;
        _longitude = longitude;
        _altitude = altitude;
        _heading = heading;
        _providerKey = [providerKey copy];
    }
    return self;
}

- (instancetype)initWithDictionary:(NSDictionary *)dictionary {
    if (![dictionary isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    double latitude = 0.0;
    double longitude = 0.0;
    double altitude = 0.0;
    double heading = 0.0;
    if (!GPSLabStoreStrictDouble(dictionary, kGPSLabKeyLatitude, &latitude) ||
        !GPSLabStoreStrictDouble(dictionary, kGPSLabKeyLongitude, &longitude) ||
        !GPSLabStoreStrictDouble(dictionary, kGPSLabKeyAltitude, &altitude) ||
        !GPSLabStoreStrictDouble(dictionary, kGPSLabKeyHeading, &heading)) {
        return nil;
    }
    if (!GPSLabSelectionFieldsValid(latitude, longitude, altitude, heading)) {
        return nil;
    }
    NSString *provider = GPSLabStoreValidatedProvider(dictionary[kGPSLabKeyProvider]);
    return [self initWithLatitude:latitude
                        longitude:longitude
                         altitude:altitude
                          heading:heading
                      providerKey:provider];
}

- (NSDictionary *)dictionaryRepresentation {
    NSMutableDictionary *representation = [@{
        kGPSLabKeyLatitude: @(self.latitude),
        kGPSLabKeyLongitude: @(self.longitude),
        kGPSLabKeyAltitude: @(self.altitude),
        kGPSLabKeyHeading: @(self.heading),
    } mutableCopy];
    if (self.providerKey.length > 0) {
        representation[kGPSLabKeyProvider] = self.providerKey;
    }
    return representation;
}

@end

@implementation GPSLabCommittedSelection

- (instancetype)initWithLatitude:(double)latitude
                       longitude:(double)longitude
                        altitude:(double)altitude {
    self = [super init];
    if (self) {
        _latitude = latitude;
        _longitude = longitude;
        _altitude = altitude;
    }
    return self;
}

- (instancetype)initWithDictionary:(NSDictionary *)dictionary {
    if (![dictionary isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    double latitude = 0.0;
    double longitude = 0.0;
    double altitude = 0.0;
    if (!GPSLabStoreStrictDouble(dictionary, kGPSLabKeyLatitude, &latitude) ||
        !GPSLabStoreStrictDouble(dictionary, kGPSLabKeyLongitude, &longitude) ||
        !GPSLabStoreStrictDouble(dictionary, kGPSLabKeyAltitude, &altitude)) {
        return nil;
    }
    if (!GPSLabProfileCoordinateValid(latitude, longitude) || !GPSLabProfileAltitudeValid(altitude)) {
        return nil;
    }
    return [self initWithLatitude:latitude longitude:longitude altitude:altitude];
}

- (NSDictionary *)dictionaryRepresentation {
    return @{
        kGPSLabKeyLatitude: @(self.latitude),
        kGPSLabKeyLongitude: @(self.longitude),
        kGPSLabKeyAltitude: @(self.altitude),
    };
}

@end

@implementation GPSLabStore {
    NSUserDefaults *_defaults;
    os_unfair_lock _lock;
}

+ (instancetype)sharedStore {
    static GPSLabStore *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[GPSLabStore alloc] init];
    });
    return instance;
}

- (instancetype)initWithUserDefaults:(NSUserDefaults *)userDefaults {
    self = [super init];
    if (self) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _defaults = userDefaults ?: [NSUserDefaults standardUserDefaults];
    }
    return self;
}

- (instancetype)init {
    NSUserDefaults *scoped = [[NSUserDefaults alloc] initWithSuiteName:kGPSLabSuiteName];
    return [self initWithUserDefaults:(scoped ?: [NSUserDefaults standardUserDefaults])];
}

#pragma mark - Configuration

- (GPSLabConfiguration *)loadConfiguration {
    os_unfair_lock_lock(&_lock);
    id stored = [_defaults objectForKey:kGPSLabKeyConfiguration];
    os_unfair_lock_unlock(&_lock);

    if ([stored isKindOfClass:[NSDictionary class]]) {
        return [GPSLabConfiguration configurationFromDictionary:(NSDictionary *)stored];
    }
    return [GPSLabConfiguration defaultConfiguration];
}

- (void)saveConfiguration:(GPSLabConfiguration *)configuration {
    if (configuration == nil) {
        return;
    }
    [configuration sanitize];
    NSDictionary *representation = [configuration dictionaryRepresentation];

    os_unfair_lock_lock(&_lock);
    [_defaults setObject:representation forKey:kGPSLabKeyConfiguration];
    os_unfair_lock_unlock(&_lock);
}

- (void)clearPersistedCoordinate {
    // Erase the keep-last coordinate keys from the stored configuration so a
    // true -> false transition cannot leave a stale coordinate behind. The rest
    // of the allow-list (enabled, drift, route prefs, keepLast) is preserved.
    os_unfair_lock_lock(&_lock);
    id stored = [_defaults objectForKey:kGPSLabKeyConfiguration];
    if ([stored isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *dictionary = [(NSDictionary *)stored mutableCopy];
        [dictionary removeObjectForKey:kGPSLabKeyLatitude];
        [dictionary removeObjectForKey:kGPSLabKeyLongitude];
        [dictionary removeObjectForKey:kGPSLabKeyAltitude];
        [dictionary removeObjectForKey:kGPSLabKeyHeading];
        [_defaults setObject:dictionary forKey:kGPSLabKeyConfiguration];
    }
    os_unfair_lock_unlock(&_lock);
}

#pragma mark - Map style preference

- (GPSLabMapStyle)loadMapStyle {
    os_unfair_lock_lock(&_lock);
    id stored = [_defaults objectForKey:kGPSLabKeyMapStyle];
    os_unfair_lock_unlock(&_lock);

    // Missing/invalid (wrong type, boolean, or out-of-range) falls back to Satellite.
    if (![stored isKindOfClass:[NSNumber class]] || GPSLabStoreIsBooleanNumber(stored)) {
        return GPSLabMapStyleSatellite;
    }
    NSInteger raw = [stored integerValue];
    if (raw < GPSLabMapStyleStandard || raw > GPSLabMapStyleSatellite) {
        return GPSLabMapStyleSatellite;
    }
    return (GPSLabMapStyle)raw;
}

- (void)saveMapStyle:(GPSLabMapStyle)style {
    GPSLabMapStyle sanitized = (style >= GPSLabMapStyleStandard && style <= GPSLabMapStyleSatellite)
        ? style
        : GPSLabMapStyleSatellite;
    os_unfair_lock_lock(&_lock);
    [_defaults setInteger:(NSInteger)sanitized forKey:kGPSLabKeyMapStyle];
    os_unfair_lock_unlock(&_lock);
}

#pragma mark - Pending selection (preview draft)

- (nullable GPSLabPendingSelection *)loadPendingSelection {
    os_unfair_lock_lock(&_lock);
    id stored = [_defaults objectForKey:kGPSLabKeyPendingSelection];
    os_unfair_lock_unlock(&_lock);

    if (![stored isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    // Corrupted drafts (wrong types, non-finite, out of range) are ignored safely.
    return [[GPSLabPendingSelection alloc] initWithDictionary:(NSDictionary *)stored];
}

- (void)savePendingSelection:(GPSLabPendingSelection *)selection {
    if (selection == nil) {
        return;
    }
    // Re-validate through the typed value so a caller cannot persist a bad draft.
    GPSLabPendingSelection *validated =
        [[GPSLabPendingSelection alloc] initWithDictionary:[selection dictionaryRepresentation]];
    if (validated == nil) {
        return;
    }

    os_unfair_lock_lock(&_lock);
    [_defaults setObject:[validated dictionaryRepresentation] forKey:kGPSLabKeyPendingSelection];
    os_unfair_lock_unlock(&_lock);
}

- (void)clearPendingSelection {
    os_unfair_lock_lock(&_lock);
    [_defaults removeObjectForKey:kGPSLabKeyPendingSelection];
    os_unfair_lock_unlock(&_lock);
}

#pragma mark - Committed selection receipt

- (nullable GPSLabCommittedSelection *)loadCommittedSelection {
    os_unfair_lock_lock(&_lock);
    id stored = [_defaults objectForKey:kGPSLabKeyCommittedSelection];
    os_unfair_lock_unlock(&_lock);

    if (![stored isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    return [[GPSLabCommittedSelection alloc] initWithDictionary:(NSDictionary *)stored];
}

- (void)recordCommittedSelection:(GPSLabCommittedSelection *)selection {
    if (selection == nil) {
        return;
    }
    GPSLabCommittedSelection *validated =
        [[GPSLabCommittedSelection alloc] initWithDictionary:[selection dictionaryRepresentation]];
    if (validated == nil) {
        return;
    }

    os_unfair_lock_lock(&_lock);
    [_defaults setObject:[validated dictionaryRepresentation] forKey:kGPSLabKeyCommittedSelection];
    os_unfair_lock_unlock(&_lock);
}

- (BOOL)shouldAllowFavoriteAtCoordinate:(CLLocationCoordinate2D)coordinate hasPending:(BOOL)hasPending {
    if (!GPSLabIsValidCoordinate(coordinate.latitude, coordinate.longitude)) {
        return NO;
    }
    int allowed = GPSLabFavoriteSelectionAllowed(hasPending ? 1 : 0,
                                                 coordinate.latitude,
                                                 coordinate.longitude,
                                                 [self hasExactZeroIntentProof] ? 1 : 0);
    return allowed ? YES : NO;
}

/**
 * Streams the intentional-selection proofs under a single lock (no allocation):
 * the committed receipt plus any strictly-valid recents/bookmarks, testing each
 * with the core's EXACT-zero predicate. Raw dictionaries are read directly so a
 * corrupt bookmark defaulting to (0,0) can never act as a proof, and a
 * near-origin nonzero selection never authorizes the pristine origin.
 */
- (BOOL)hasExactZeroIntentProof {
    os_unfair_lock_lock(&_lock);

    BOOL hasProof = NO;
    id receiptStored = [_defaults objectForKey:kGPSLabKeyCommittedSelection];
    if ([receiptStored isKindOfClass:[NSDictionary class]]) {
        double latitude = 0.0;
        double longitude = 0.0;
        if (GPSLabStoreStrictDouble((NSDictionary *)receiptStored, kGPSLabKeyLatitude, &latitude) &&
            GPSLabStoreStrictDouble((NSDictionary *)receiptStored, kGPSLabKeyLongitude, &longitude) &&
            GPSLabProfileCoordinateValid(latitude, longitude) &&
            GPSLabSelectionPointIsExactZero(latitude, longitude)) {
            hasProof = YES;
        }
    }

    if (!hasProof) {
        NSArray *recentEntries = [self decodeArrayForKey:kGPSLabKeyRecents];
        NSArray *bookmarkEntries = [self decodeArrayForKey:kGPSLabKeyBookmarks];
        for (NSArray *entries in @[ recentEntries, bookmarkEntries ]) {
            for (id entry in entries) {
                if (![entry isKindOfClass:[NSDictionary class]]) {
                    continue;
                }
                double latitude = 0.0;
                double longitude = 0.0;
                if (GPSLabStoreStrictDouble((NSDictionary *)entry, kGPSLabKeyLatitude, &latitude) &&
                    GPSLabStoreStrictDouble((NSDictionary *)entry, kGPSLabKeyLongitude, &longitude) &&
                    GPSLabProfileCoordinateValid(latitude, longitude) &&
                    GPSLabSelectionPointIsExactZero(latitude, longitude)) {
                    hasProof = YES;
                    break;
                }
            }
            if (hasProof) {
                break;
            }
        }
    }

    os_unfair_lock_unlock(&_lock);
    return hasProof;
}

#pragma mark - Bookmarks

- (NSArray<GPSLabBookmark *> *)loadBookmarks {
    os_unfair_lock_lock(&_lock);
    NSArray *stored = [self decodeArrayForKey:kGPSLabKeyBookmarks];
    os_unfair_lock_unlock(&_lock);

    NSMutableArray<GPSLabBookmark *> *bookmarks = [NSMutableArray array];
    for (id entry in stored) {
        if ([entry isKindOfClass:[NSDictionary class]]) {
            [bookmarks addObject:[[GPSLabBookmark alloc] initWithDictionary:(NSDictionary *)entry]];
        }
    }
    return bookmarks;
}

- (void)saveBookmarks:(NSArray<GPSLabBookmark *> *)bookmarks {
    NSMutableArray *representation = [NSMutableArray array];
    for (GPSLabBookmark *bookmark in bookmarks) {
        if ([bookmark isKindOfClass:[GPSLabBookmark class]]) {
            [representation addObject:[bookmark dictionaryRepresentation]];
        }
    }

    os_unfair_lock_lock(&_lock);
    [self encodeArray:representation forKey:kGPSLabKeyBookmarks];
    os_unfair_lock_unlock(&_lock);
}

- (BOOL)addBookmarkIfNotDuplicate:(GPSLabBookmark *)bookmark {
    // Reject malformed input up front (finite/range) so an invalid altitude can
    // never fail serialization of the whole existing bookmark list.
    if (bookmark == nil ||
        !GPSLabIsValidCoordinate(bookmark.latitude, bookmark.longitude) ||
        !GPSLabProfileAltitudeValid(bookmark.altitude)) {
        return NO;
    }

    // Atomic check + insert under a single lock acquisition (no allocation, no
    // load/save re-entrancy). The stored coordinates are read raw and strictly
    // validated, then compared with the existing geodesic helper.
    os_unfair_lock_lock(&_lock);
    NSArray *stored = [self decodeArrayForKey:kGPSLabKeyBookmarks];
    for (id entry in stored) {
        if (![entry isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        double latitude = 0.0;
        double longitude = 0.0;
        if (!GPSLabStoreStrictDouble((NSDictionary *)entry, kGPSLabKeyLatitude, &latitude) ||
            !GPSLabStoreStrictDouble((NSDictionary *)entry, kGPSLabKeyLongitude, &longitude) ||
            !GPSLabProfileCoordinateValid(latitude, longitude)) {
            continue;
        }
        if (GPSLabSelectionDistanceMeters(latitude, longitude,
                                          bookmark.latitude, bookmark.longitude) <=
            GPSLAB_SELECTION_DUPLICATE_TOLERANCE_METERS) {
            os_unfair_lock_unlock(&_lock);
            return NO;
        }
    }

    NSMutableArray *updated = [stored mutableCopy];
    [updated addObject:[bookmark dictionaryRepresentation]];
    [self encodeArray:updated forKey:kGPSLabKeyBookmarks];
    os_unfair_lock_unlock(&_lock);
    return YES;
}

- (void)addBookmark:(GPSLabBookmark *)bookmark {
    // Backwards-compatible wrapper: existing callers keep compiling, duplicates
    // are simply skipped rather than purged from previously stored data.
    (void)[self addBookmarkIfNotDuplicate:bookmark];
}

- (void)deleteBookmarkAtIndex:(NSUInteger)index {
    NSMutableArray *bookmarks = [[self loadBookmarks] mutableCopy];
    if (index >= bookmarks.count) {
        return;
    }
    [bookmarks removeObjectAtIndex:index];
    [self saveBookmarks:bookmarks];
}

- (void)renameBookmarkAtIndex:(NSUInteger)index name:(NSString *)name {
    NSMutableArray *bookmarks = [[self loadBookmarks] mutableCopy];
    if (index >= bookmarks.count) {
        return;
    }
    GPSLabBookmark *bookmark = bookmarks[index];
    if (name.length > 0) {
        bookmark.name = name;
    }
    [self saveBookmarks:bookmarks];
}

#pragma mark - Recents

- (NSArray<NSDictionary *> *)loadRecents {
    os_unfair_lock_lock(&_lock);
    NSArray *stored = [self decodeArrayForKey:kGPSLabKeyRecents];
    os_unfair_lock_unlock(&_lock);

    NSMutableArray<NSDictionary *> *recents = [NSMutableArray array];
    for (id entry in stored) {
        if (![entry isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSDictionary *dictionary = (NSDictionary *)entry;
        id latValue = dictionary[kGPSLabBookmarkLatitude];
        id lonValue = dictionary[kGPSLabBookmarkLongitude];
        if (![latValue isKindOfClass:[NSNumber class]] || ![lonValue isKindOfClass:[NSNumber class]]) {
            continue;
        }
        double latitude = [latValue doubleValue];
        double longitude = [lonValue doubleValue];
        if (!GPSLabIsValidCoordinate(latitude, longitude)) {
            continue;
        }
        [recents addObject:dictionary];
    }
    return recents;
}

- (void)addRecentCoordinate:(CLLocationCoordinate2D)coordinate altitude:(double)altitude {
    if (!GPSLabIsValidCoordinate(coordinate.latitude, coordinate.longitude)) {
        return;
    }

    NSMutableArray<NSDictionary *> *recents = [[self loadRecents] mutableCopy];

    if (recents.count > 0) {
        NSDictionary *first = recents.firstObject;
        CLLocationCoordinate2D firstCoordinate = CLLocationCoordinate2DMake([first[kGPSLabBookmarkLatitude] doubleValue],
                                                                           [first[kGPSLabBookmarkLongitude] doubleValue]);
        if (GPSLabDistanceMeters(firstCoordinate, coordinate) < kGPSLabRecentDedupeMeters) {
            return;
        }
    }

    NSDictionary *entry = @{
        kGPSLabBookmarkLatitude: @(coordinate.latitude),
        kGPSLabBookmarkLongitude: @(coordinate.longitude),
        kGPSLabBookmarkAltitude: @(GPSLabClampDouble(altitude, -500.0, 100000.0)),
    };
    [recents insertObject:entry atIndex:0];
    while (recents.count > kGPSLabMaxRecents) {
        [recents removeLastObject];
    }

    os_unfair_lock_lock(&_lock);
    [self encodeArray:recents forKey:kGPSLabKeyRecents];
    os_unfair_lock_unlock(&_lock);
}

- (void)deleteRecentAtIndex:(NSUInteger)index {
    NSMutableArray *recents = [[self loadRecents] mutableCopy];
    if (index >= recents.count) {
        return;
    }
    [recents removeObjectAtIndex:index];
    os_unfair_lock_lock(&_lock);
    [self encodeArray:recents forKey:kGPSLabKeyRecents];
    os_unfair_lock_unlock(&_lock);
}

- (void)clearRecents {
    os_unfair_lock_lock(&_lock);
    [_defaults removeObjectForKey:kGPSLabKeyRecents];
    os_unfair_lock_unlock(&_lock);
}

#pragma mark - Private helpers (lock held by caller)

- (NSArray *)decodeArrayForKey:(NSString *)key {
    id stored = [_defaults objectForKey:key];
    if ([stored isKindOfClass:[NSArray class]]) {
        return stored;
    }
    if ([stored isKindOfClass:[NSData class]]) {
        id decoded = [NSJSONSerialization JSONObjectWithData:(NSData *)stored options:0 error:NULL];
        if ([decoded isKindOfClass:[NSArray class]]) {
            return decoded;
        }
    }
    return @[];
}

- (void)encodeArray:(NSArray *)array forKey:(NSString *)key {
    if (array.count == 0) {
        [_defaults removeObjectForKey:key];
        return;
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:array options:0 error:NULL];
    if (data != nil) {
        [_defaults setObject:data forKey:key];
    }
}

@end
