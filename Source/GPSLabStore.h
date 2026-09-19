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

@interface GPSLabStore : NSObject

+ (instancetype)sharedStore;

#pragma mark - Configuration

- (GPSLabConfiguration *)loadConfiguration;
- (void)saveConfiguration:(GPSLabConfiguration *)configuration;

/** Removes every persisted coordinate key (used when `keepLastCoordinate` turns off). */
- (void)clearPersistedCoordinate;

#pragma mark - Bookmarks

- (NSArray<GPSLabBookmark *> *)loadBookmarks;
- (void)saveBookmarks:(NSArray<GPSLabBookmark *> *)bookmarks;
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
