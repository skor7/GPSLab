//
//  GPSLabProfileStore.h
//  GPSLab
//
//  Durable, corruption-safe storage for user-authored profiles.
//
//  Location: <Application Support>/GPSLab/Profiles/profiles.json, inside a
//  GPSLab-owned folder excluded from backups. Writes are serialized on a private
//  queue and written atomically with file protection. A corrupted file is
//  quarantined (renamed) and an empty store is returned; the host never crashes
//  and no host data is read or touched.
//

#import <Foundation/Foundation.h>

#import "GPSLabProfile.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const GPSLabProfileStoreErrorDomain;

typedef NS_ENUM(NSInteger, GPSLabProfileStoreError) {
    GPSLabProfileStoreErrorCapacity = 1,
    GPSLabProfileStoreErrorNotFound,
    GPSLabProfileStoreErrorInvalidProfile,
    GPSLabProfileStoreErrorWriteFailed,
};

@interface GPSLabProfileStore : NSObject

+ (instancetype)sharedStore;

/** Test seam: a store rooted at an injected directory (no host Application Support). */
- (instancetype)initWithDirectoryURL:(NSURL *)directoryURL NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly, copy) NSURL *directoryURL;
@property (nonatomic, readonly, copy) NSURL *fileURL;

/** Every valid stored profile (invalid entries are skipped). Never nil. */
- (NSArray<GPSLabProfile *> *)loadProfiles;

/** The persisted selected profile id, or nil when absent/invalid. */
- (nullable NSString *)selectedProfileIdentifier;

- (BOOL)saveProfiles:(NSArray<GPSLabProfile *> *)profiles error:(NSError **)error;

- (BOOL)addProfile:(GPSLabProfile *)profile error:(NSError **)error;
- (BOOL)updateProfile:(GPSLabProfile *)profile error:(NSError **)error;
- (BOOL)deleteProfileWithIdentifier:(NSString *)identifier error:(NSError **)error;
- (BOOL)setSelectedProfileIdentifier:(nullable NSString *)identifier error:(NSError **)error;
- (BOOL)clearAllWithError:(NSError **)error;

/** YES when at least one profile exists. */
- (BOOL)hasProfiles;

@end

NS_ASSUME_NONNULL_END
