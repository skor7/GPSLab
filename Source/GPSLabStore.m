//
//  GPSLabStore.m
//  GPSLab
//
//  NSUserDefaults-backed persistence with a dedicated suite and strict validation.
//  Corrupted entries fall back to safe defaults instead of crashing.
//

#import "GPSLabStore.h"

#import <os/lock.h>

#import "GPSLabGeodesy.h"

static NSString * const kGPSLabSuiteName = @"com.gpslab.runtime";
static NSString * const kGPSLabKeyConfiguration = @"GPSLab.configuration";
static NSString * const kGPSLabKeyBookmarks = @"GPSLab.bookmarks";
static NSString * const kGPSLabKeyRecents = @"GPSLab.recents";

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

static const NSUInteger kGPSLabMaxRecents = 20;
static const double kGPSLabRecentDedupeMeters = 5.0;

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

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = OS_UNFAIR_LOCK_INIT;
        NSUserDefaults *scoped = [[NSUserDefaults alloc] initWithSuiteName:kGPSLabSuiteName];
        _defaults = scoped != nil ? scoped : [NSUserDefaults standardUserDefaults];
    }
    return self;
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

- (void)addBookmark:(GPSLabBookmark *)bookmark {
    if (bookmark == nil) {
        return;
    }
    NSMutableArray *bookmarks = [[self loadBookmarks] mutableCopy];
    [bookmarks addObject:bookmark];
    [self saveBookmarks:bookmarks];
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
