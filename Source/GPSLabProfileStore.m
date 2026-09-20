//
//  GPSLabProfileStore.m
//  GPSLab
//

#import "GPSLabProfileStore.h"

#import <CoreFoundation/CoreFoundation.h>
#import <TargetConditionals.h>
#import <math.h>

static NSString * const kGPSLabProfileSchemaVersionKey = @"schemaVersion";
static NSString * const kGPSLabProfileProfilesKey = @"profiles";
static NSString * const kGPSLabProfileSelectedKey = @"selectedId";

static NSString * const kGPSLabProfileFolderName = @"GPSLab";
static NSString * const kGPSLabProfilesFolderName = @"Profiles";
static NSString * const kGPSLabProfilesFileName = @"profiles.json";

/** A profiles file is never legitimately larger than this; a bigger file is corruption. */
static const unsigned long long kGPSLabProfileMaxFileBytes = 1024ULL * 1024ULL;
/** Bound the number of quarantined corrupt files so repeated corruption cannot fill disk. */
static const NSUInteger kGPSLabProfileMaxQuarantineFiles = 5;
/** Largest magnitude a double holds without losing integer precision (2^53). */
static const double kGPSLabProfileIntegerSafeBound = 9007199254740992.0;

/** Strict schema-version reader: rejects booleans, fractions and out-of-range values. */
static BOOL GPSLabStoreReadSchemaVersion(id value, long long *outVersion) {
    if (![value isKindOfClass:[NSNumber class]]) {
        return NO;
    }
    if (CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) {
        return NO;
    }
    double number = [(NSNumber *)value doubleValue];
    if (!isfinite(number) || number != floor(number) ||
        number < -kGPSLabProfileIntegerSafeBound || number > kGPSLabProfileIntegerSafeBound) {
        return NO;
    }
    *outVersion = (long long)number;
    return YES;
}

NSString * const GPSLabProfileStoreErrorDomain = @"com.gpslab.profiles";

@implementation GPSLabProfileStore {
    dispatch_queue_t _queue;
    NSURL *_directoryURL;
    NSURL *_fileURL;
}

+ (instancetype)sharedStore {
    static GPSLabProfileStore *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSURL *base = nil;
        NSArray<NSURL *> *urls =
            [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory
                                                  inDomains:NSUserDomainMask];
        if (urls.count > 0) {
            base = [urls.firstObject URLByAppendingPathComponent:kGPSLabProfileFolderName
                                                     isDirectory:YES];
            base = [base URLByAppendingPathComponent:kGPSLabProfilesFolderName isDirectory:YES];
        }
        if (base == nil) {
            NSString *temporary = NSTemporaryDirectory();
            base = [NSURL fileURLWithPath:[temporary stringByAppendingPathComponent:@"GPSLab/Profiles"]
                              isDirectory:YES];
        }
        instance = [[GPSLabProfileStore alloc] initWithDirectoryURL:base];
    });
    return instance;
}

- (instancetype)initWithDirectoryURL:(NSURL *)directoryURL {
    self = [super init];
    if (self) {
        _directoryURL = [directoryURL copy];
        _fileURL = [_directoryURL URLByAppendingPathComponent:kGPSLabProfilesFileName];
        _queue = dispatch_queue_create("com.gpslab.runtime.profiles", DISPATCH_QUEUE_SERIAL);
        [self prepareDirectory];
    }
    return self;
}

- (NSURL *)directoryURL {
    return _directoryURL;
}

- (NSURL *)fileURL {
    return _fileURL;
}

#pragma mark - Directory

- (void)prepareDirectory {
    NSFileManager *manager = [NSFileManager defaultManager];
    NSError *error = nil;
    if (![manager createDirectoryAtURL:_directoryURL
           withIntermediateDirectories:YES
                            attributes:nil
                                 error:&error]) {
        return;
    }
    // Exclude the GPSLab-owned folder from backups. Best effort on all platforms.
    [_directoryURL setResourceValue:@(YES) forKey:NSURLIsExcludedFromBackupKey error:NULL];
#if TARGET_OS_IPHONE
    [manager setAttributes:@{ NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication }
              ofItemAtPath:_directoryURL.path
                     error:NULL];
#endif
}

#pragma mark - Public API (serialized on the private queue)

- (NSArray<GPSLabProfile *> *)loadProfiles {
    __block NSArray<GPSLabProfile *> *profiles = @[];
    dispatch_sync(_queue, ^{
        NSArray<GPSLabProfile *> *loaded = nil;
        NSString *selected = nil;
        [self loadOnQueueProfiles:&loaded selected:&selected];
        profiles = loaded;
    });
    return profiles;
}

- (NSString *)selectedProfileIdentifier {
    __block NSString *selected = nil;
    dispatch_sync(_queue, ^{
        NSArray<GPSLabProfile *> *loaded = nil;
        NSString *selection = nil;
        [self loadOnQueueProfiles:&loaded selected:&selection];
        selected = selection;
    });
    return selected;
}

- (BOOL)hasProfiles {
    return self.loadProfiles.count > 0;
}

- (BOOL)saveProfiles:(NSArray<GPSLabProfile *> *)profiles error:(NSError **)error {
    __block BOOL success = NO;
    __block NSError *localError = nil;
    dispatch_sync(_queue, ^{
        NSString *selection = [self selectedOnQueue];
        success = [self writeOnQueueProfiles:profiles selection:selection error:&localError];
    });
    if (!success && error != NULL) {
        *error = localError;
    }
    return success;
}

- (BOOL)addProfile:(GPSLabProfile *)profile error:(NSError **)error {
    if (profile == nil) {
        if (error != NULL) {
            *error = [self invalidProfileError];
        }
        return NO;
    }
    __block BOOL success = NO;
    __block NSError *localError = nil;
    dispatch_sync(_queue, ^{
        NSArray<GPSLabProfile *> *profiles = nil;
        NSString *selection = nil;
        [self loadOnQueueProfiles:&profiles selected:&selection];
        if (!GPSLabProfileCountValid(profiles.count + 1)) {
            localError = [NSError errorWithDomain:GPSLabProfileStoreErrorDomain
                                             code:GPSLabProfileStoreErrorCapacity
                                         userInfo:@{ NSLocalizedDescriptionKey: @"profile capacity reached" }];
            return;
        }
        NSMutableArray<GPSLabProfile *> *updated = [profiles mutableCopy];
        [updated addObject:profile];
        success = [self writeOnQueueProfiles:updated selection:selection error:&localError];
    });
    if (!success && error != NULL) {
        *error = localError;
    }
    return success;
}

- (BOOL)updateProfile:(GPSLabProfile *)profile error:(NSError **)error {
    if (profile == nil) {
        if (error != NULL) {
            *error = [self invalidProfileError];
        }
        return NO;
    }
    __block BOOL success = NO;
    __block NSError *localError = nil;
    dispatch_sync(_queue, ^{
        NSArray<GPSLabProfile *> *profiles = nil;
        NSString *selection = nil;
        [self loadOnQueueProfiles:&profiles selected:&selection];
        NSMutableArray<GPSLabProfile *> *updated = [profiles mutableCopy];
        NSInteger index = [self indexOfIdentifier:profile.identifier inProfiles:updated];
        if (index < 0) {
            localError = [NSError errorWithDomain:GPSLabProfileStoreErrorDomain
                                             code:GPSLabProfileStoreErrorNotFound
                                         userInfo:@{ NSLocalizedDescriptionKey: @"profile not found" }];
            return;
        }
        updated[(NSUInteger)index] = profile;
        success = [self writeOnQueueProfiles:updated selection:selection error:&localError];
    });
    if (!success && error != NULL) {
        *error = localError;
    }
    return success;
}

- (BOOL)deleteProfileWithIdentifier:(NSString *)identifier error:(NSError **)error {
    if (identifier.length == 0) {
        if (error != NULL) {
            *error = [self invalidProfileError];
        }
        return NO;
    }
    __block BOOL success = NO;
    __block NSError *localError = nil;
    dispatch_sync(_queue, ^{
        NSArray<GPSLabProfile *> *profiles = nil;
        NSString *selection = nil;
        [self loadOnQueueProfiles:&profiles selected:&selection];
        NSMutableArray<GPSLabProfile *> *updated = [profiles mutableCopy];
        NSInteger index = [self indexOfIdentifier:identifier inProfiles:updated];
        if (index < 0) {
            localError = [NSError errorWithDomain:GPSLabProfileStoreErrorDomain
                                             code:GPSLabProfileStoreErrorNotFound
                                         userInfo:@{ NSLocalizedDescriptionKey: @"profile not found" }];
            return;
        }
        [updated removeObjectAtIndex:(NSUInteger)index];
        // The selected id must not survive its profile.
        if ([selection isEqualToString:identifier]) {
            selection = updated.count > 0 ? updated.firstObject.identifier : nil;
        }
        success = [self writeOnQueueProfiles:updated selection:selection error:&localError];
    });
    if (!success && error != NULL) {
        *error = localError;
    }
    return success;
}

- (BOOL)setSelectedProfileIdentifier:(nullable NSString *)identifier error:(NSError **)error {
    __block BOOL success = NO;
    __block NSError *localError = nil;
    dispatch_sync(_queue, ^{
        NSArray<GPSLabProfile *> *profiles = nil;
        NSString *selection = nil;
        [self loadOnQueueProfiles:&profiles selected:&selection];
        NSString *resolved = nil;
        if (identifier.length > 0 && [self indexOfIdentifier:identifier inProfiles:profiles] >= 0) {
            resolved = identifier;
        } else if (identifier.length > 0) {
            localError = [NSError errorWithDomain:GPSLabProfileStoreErrorDomain
                                             code:GPSLabProfileStoreErrorNotFound
                                         userInfo:@{ NSLocalizedDescriptionKey: @"profile not found" }];
            return;
        }
        success = [self writeOnQueueProfiles:profiles selection:resolved error:&localError];
    });
    if (!success && error != NULL) {
        *error = localError;
    }
    return success;
}

- (BOOL)clearAllWithError:(NSError **)error {
    __block BOOL success = NO;
    __block NSError *localError = nil;
    dispatch_sync(_queue, ^{
        success = [self writeOnQueueProfiles:@[] selection:nil error:&localError];
    });
    if (!success && error != NULL) {
        *error = localError;
    }
    return success;
}

#pragma mark - Queue-private helpers

- (NSError *)invalidProfileError {
    return [NSError errorWithDomain:GPSLabProfileStoreErrorDomain
                               code:GPSLabProfileStoreErrorInvalidProfile
                           userInfo:@{ NSLocalizedDescriptionKey: @"invalid profile" }];
}

- (NSInteger)indexOfIdentifier:(NSString *)identifier inProfiles:(NSArray<GPSLabProfile *> *)profiles {
    for (NSUInteger index = 0; index < profiles.count; index++) {
        if ([profiles[index].identifier isEqualToString:identifier]) {
            return (NSInteger)index;
        }
    }
    return -1;
}

- (NSString *)selectedOnQueue {
    NSArray<GPSLabProfile *> *profiles = nil;
    NSString *selection = nil;
    [self loadOnQueueProfiles:&profiles selected:&selection];
    return selection;
}

/** Reads + validates. On any corruption the file is quarantined and empty is returned. */
- (void)loadOnQueueProfiles:(NSArray<GPSLabProfile *> **)outProfiles
                   selected:(NSString **)outSelected {
    *outProfiles = @[];
    *outSelected = nil;

    NSURL *url = self.fileURL;
    // Reject an oversized file from metadata BEFORE reading it, and re-check the
    // byte length after the read to close the metadata/read race.
    NSNumber *fileSize = nil;
    [url getResourceValue:&fileSize forKey:NSURLFileSizeKey error:NULL];
    if (fileSize != nil && fileSize.unsignedLongLongValue > kGPSLabProfileMaxFileBytes) {
        [self quarantineOnQueue];
        return;
    }

    NSData *data = [NSData dataWithContentsOfURL:url];
    if (data.length == 0) {
        return;
    }
    if (data.length > kGPSLabProfileMaxFileBytes) {
        [self quarantineOnQueue];
        return;
    }

    NSError *jsonError = nil;
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    BOOL valid = [root isKindOfClass:[NSDictionary class]];
    NSDictionary *dictionary = valid ? (NSDictionary *)root : nil;

    long long version = -1;
    if (valid) {
        valid = GPSLabStoreReadSchemaVersion(dictionary[kGPSLabProfileSchemaVersionKey], &version) &&
                GPSLabProfileSchemaVersionValid(version) ? YES : NO;
    }

    id profilesValue = valid ? dictionary[kGPSLabProfileProfilesKey] : nil;
    if (valid && ![profilesValue isKindOfClass:[NSArray class]]) {
        valid = NO;
    }

    if (!valid) {
        [self quarantineOnQueue];
        return;
    }

    NSMutableArray<GPSLabProfile *> *profiles = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (id entry in (NSArray *)profilesValue) {
        // Cap at read time: never accumulate one past the limit.
        if (!GPSLabProfileCountValid(profiles.count + 1)) {
            break;
        }
        if (![entry isKindOfClass:[NSDictionary class]]) {
            continue; // skip malformed entries instead of failing the whole file
        }
        GPSLabProfile *profile = [GPSLabProfile profileFromDictionary:(NSDictionary *)entry];
        if (profile == nil) {
            continue;
        }
        if ([seen containsObject:profile.identifier]) {
            continue; // deterministic: the first occurrence wins, never overwrite
        }
        [seen addObject:profile.identifier];
        [profiles addObject:profile];
    }

    NSString *selection = nil;
    id selectedValue = dictionary[kGPSLabProfileSelectedKey];
    if ([selectedValue isKindOfClass:[NSString class]]) {
        NSString *candidate = (NSString *)selectedValue;
        if ([seen containsObject:candidate]) {
            selection = candidate;
        }
    }

    *outProfiles = profiles;
    *outSelected = selection;
}

- (BOOL)writeOnQueueProfiles:(NSArray<GPSLabProfile *> *)profiles
                   selection:(nullable NSString *)selection
                       error:(NSError **)error {
    if (!GPSLabProfileCountValid(profiles.count)) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:GPSLabProfileStoreErrorDomain
                                         code:GPSLabProfileStoreErrorCapacity
                                     userInfo:@{ NSLocalizedDescriptionKey: @"profile capacity reached" }];
        }
        return NO;
    }

    NSMutableArray *representations = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (GPSLabProfile *profile in profiles) {
        // Validate every entry strictly BEFORE encoding; never silently skip or
        // persist a malformed typed-initialized profile.
        if (![profile isKindOfClass:[GPSLabProfile class]] || ![profile isValidForApplication]) {
            if (error != NULL) {
                *error = [self invalidProfileError];
            }
            return NO;
        }
        if ([seen containsObject:profile.identifier]) {
            if (error != NULL) {
                *error = [self invalidProfileError];
            }
            return NO;
        }
        [seen addObject:profile.identifier];
        [representations addObject:[profile dictionaryRepresentation]];
    }

    NSString *resolvedSelection = (selection.length > 0 && [seen containsObject:selection])
        ? selection : nil;
    NSMutableDictionary *root = [@{
        kGPSLabProfileSchemaVersionKey: @(GPSLAB_PROFILE_SCHEMA_VERSION),
        kGPSLabProfileProfilesKey: representations,
    } mutableCopy];
    if (resolvedSelection.length > 0) {
        root[kGPSLabProfileSelectedKey] = resolvedSelection;
    }

    NSError *jsonError = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:root
                                                   options:NSJSONWritingSortedKeys
                                                     error:&jsonError];
    if (data == nil) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:GPSLabProfileStoreErrorDomain
                                         code:GPSLabProfileStoreErrorWriteFailed
                                     userInfo:@{ NSLocalizedDescriptionKey: @"could not encode profiles" }];
        }
        return NO;
    }

    [self prepareDirectory];
    NSURL *url = self.fileURL;
    BOOL written = [data writeToURL:url options:NSDataWritingAtomic error:&jsonError];
    if (!written) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:GPSLabProfileStoreErrorDomain
                                         code:GPSLabProfileStoreErrorWriteFailed
                                     userInfo:@{ NSLocalizedDescriptionKey: @"could not write profiles" }];
        }
        return NO;
    }

#if TARGET_OS_IPHONE
    [[NSFileManager defaultManager]
        setAttributes:@{ NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication }
        ofItemAtPath:url.path
               error:NULL];
#endif
    return YES;
}

- (void)quarantineOnQueue {
    NSFileManager *manager = [NSFileManager defaultManager];
    NSString *path = self.fileURL.path;
    if (![manager fileExistsAtPath:path]) {
        return;
    }

    // Bound the number of quarantined files: only operate on our own directory
    // and our own "profiles.corrupt-*" files.
    NSArray<NSURL *> *contents = [manager contentsOfDirectoryAtURL:self.directoryURL
                                        includingPropertiesForKeys:@[ NSURLContentModificationDateKey ]
                                                           options:0
                                                             error:NULL];
    NSMutableArray<NSURL *> *corrupt = [NSMutableArray array];
    for (NSURL *url in contents) {
        if ([url.lastPathComponent hasPrefix:@"profiles.corrupt-"]) {
            [corrupt addObject:url];
        }
    }
    if (corrupt.count >= kGPSLabProfileMaxQuarantineFiles) {
        NSURL *oldest = nil;
        NSDate *oldestDate = nil;
        for (NSURL *url in corrupt) {
            NSDate *date = nil;
            [url getResourceValue:&date forKey:NSURLContentModificationDateKey error:NULL];
            if (oldestDate == nil || (date != nil && [date compare:oldestDate] == NSOrderedAscending)) {
                oldest = url;
                oldestDate = date;
            }
        }
        if (oldest != nil) {
            [manager removeItemAtURL:oldest error:NULL];
        }
    }

    NSString *stamp = [NSString stringWithFormat:@"%.0f", [NSDate date].timeIntervalSince1970];
    NSString *name = [NSString stringWithFormat:@"profiles.corrupt-%@.json", stamp];
    NSURL *destination = [self.directoryURL URLByAppendingPathComponent:name];
    [manager removeItemAtURL:destination error:NULL];
    [manager moveItemAtURL:self.fileURL toURL:destination error:NULL];
}

@end
