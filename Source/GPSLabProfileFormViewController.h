//
//  GPSLabProfileFormViewController.h
//  GPSLab
//
//  Native 2-column profile form (reference layout). Captures the candidate
//  static/route parameters, drift, optional test attachments and optional
//  schedule into a validated, immutable GPSLabProfile.
//

#import "GPSLabSheetViewController.h"

#import "GPSLabProfile.h"

NS_ASSUME_NONNULL_BEGIN

@interface GPSLabProfileFormViewController : GPSLabSheetViewController

/** nil creates a new profile from the supplied candidate defaults. */
@property (nonatomic, copy, nullable) GPSLabProfile *existingProfile;

/** Candidate defaults for a NEW profile (current static/route/drift values). */
@property (nonatomic, copy, nullable) GPSLabProfile *candidateProfile;

/** Returns YES when the profile was persisted; the sheet dismisses only then. */
@property (nonatomic, copy, nullable) BOOL (^saveHandler)(GPSLabProfile *profile);
@property (nonatomic, copy, nullable) void (^deleteHandler)(void);

@end

NS_ASSUME_NONNULL_END
