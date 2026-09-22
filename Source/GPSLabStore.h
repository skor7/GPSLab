//
//  GPSLabStore.h
//  GPSLab
//
//  Persistence for the allow-listed synthetic state only:
//  enabled, anchor latitude/longitude/altitude, heading, drift settings,
//  bookmarks, recents, route preferences and keep-last.
//
//  It never stores host application data and never stores real device location.
//

#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

#import "GPSLabConfiguration.h"

NS_ASSUME_NONNULL_BEGIN

/** A named, user-created synthetic coordinate. */
@interface GPSLabBookmark : NSObject

@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) double latitude;
@property (nonatomic, assign) double longitude;
@property (nonatomic, assign) double altitude;

+ (instancetype)bookmarkWithName:(NSString *)name
                      coordinate:(CLLocationCoordinate2D)coordinate
                        altitude:(double)altitude;

- (instancetype)initWithDictionary:(NSDictionary *)dictionary;
- (NSDictionary *)dictionaryRepresentation;

@end

/**
 * A pending (preview) selection: shown on the map/readout but NOT written to the
 * engine. Persisted separately from the configuration so a preview survives a
 * close/background without ever being applied. Immutable and validated on decode.
 */
@interface GPSLabPendingSelection : NSObject

@property (nonatomic, readonly) double latitude;
@property (nonatomic, readonly) double longitude;
@property (nonatomic, readonly) double altitude;
@property (nonatomic, readonly) double heading;
/** Optional provider/localization key (e.g. `search.source.google`). */
@property (nonatomic, copy, readonly, nullable) NSString *providerKey;

- (instancetype)initWithLatitude:(double)latitude
                       longitude:(double)longitude
                        altitude:(double)altitude
                         heading:(double)heading
                     providerKey:(nullable NSString *)providerKey;

/** Validated decode; nil when missing/corrupt/non-finite/out of range. */
- (nullable instancetype)initWithDictionary:(NSDictionary *)dictionary;

- (NSDictionary *)dictionaryRepresentation;

@end

/**
 * A committed-selection receipt. Stores the coordinate (not a boolean) so a
 * stale nonzero receipt can never authorize a later reset-to-(0,0).
 */
@interface GPSLabCommittedSelection : NSObject

@property (nonatomic, readonly) double latitude;
@property (nonatomic, readonly) double longitude;
@property (nonatomic, readonly) double altitude;

- (instancetype)initWithLatitude:(double)latitude
                       longitude:(double)longitude
                        altitude:(double)altitude;

/** Validated decode; nil when missing/corrupt/non-finite/out of range. */
- (nullable instancetype)initWithDictionary:(NSDictionary *)dictionary;

- (NSDictionary *)dictionaryRepresentation;

@end

@interface GPSLabStore : NSObject

+ (instancetype)sharedStore;

/**
 * Isolated defaults seam: tests pass a private suite so they never touch the
 * shared runtime suite. Production uses `init` (the `com.gpslab.runtime` suite).
 */
- (instancetype)initWithUserDefaults:(NSUserDefaults *)userDefaults;

#pragma mark - Configuration

- (GPSLabConfiguration *)loadConfiguration;
- (void)saveConfiguration:(GPSLabConfiguration *)configuration;

/** Removes every persisted coordinate key (used when `keepLastCoordinate` turns off). */
- (void)clearPersistedCoordinate;

#pragma mark - Pending selection (preview draft)

- (nullable GPSLabPendingSelection *)loadPendingSelection;
- (void)savePendingSelection:(GPSLabPendingSelection *)selection;
- (void)clearPendingSelection;

#pragma mark - Committed selection receipt

- (nullable GPSLabCommittedSelection *)loadCommittedSelection;
- (void)recordCommittedSelection:(GPSLabCommittedSelection *)selection;

/**
 * YES when a favorite at `coordinate` may be created: an active pending selection
 * is always allowed, a valid non-zero committed coordinate is allowed, and an
 * exact (0,0) committed coordinate is allowed only when an EXACT valid stored
 * (0,0) proof exists (receipt or legacy recent/bookmark) — no geodesic tolerance,
 * so a near-origin nonzero selection never authorizes the pristine origin. Never
 * infers the real device location.
 */
- (BOOL)shouldAllowFavoriteAtCoordinate:(CLLocationCoordinate2D)coordinate
                             hasPending:(BOOL)hasPending;

#pragma mark - Bookmarks

- (NSArray<GPSLabBookmark *> *)loadBookmarks;
- (void)saveBookmarks:(NSArray<GPSLabBookmark *> *)bookmarks;
/**
 * Duplicate-aware insert. Returns NO when a bookmark within the 5 m geodesic
 * tolerance already exists; legacy duplicates are preserved, never purged.
 */
- (BOOL)addBookmarkIfNotDuplicate:(GPSLabBookmark *)bookmark;
/** Backwards-compatible wrapper for `addBookmarkIfNotDuplicate:`. */
- (void)addBookmark:(GPSLabBookmark *)bookmark;
- (void)deleteBookmarkAtIndex:(NSUInteger)index;
- (void)renameBookmarkAtIndex:(NSUInteger)index name:(NSString *)name;

#pragma mark - Recents

/** Each entry is a dictionary with `latitude`, `longitude` and `altitude` numbers. */
- (NSArray<NSDictionary *> *)loadRecents;
- (void)addRecentCoordinate:(CLLocationCoordinate2D)coordinate altitude:(double)altitude;
- (void)deleteRecentAtIndex:(NSUInteger)index;
- (void)clearRecents;

@end

NS_ASSUME_NONNULL_END
