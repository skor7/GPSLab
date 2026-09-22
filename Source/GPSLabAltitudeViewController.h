//
//  GPSLabAltitudeViewController.h
//  GPSLab
//
//  Reference-styled altitude card presented through the existing sheet/modal
//  coordinator (no UIAlertController). A signed numeric meter field with a unit
//  label and zero/apply/cancel actions. The value is validated against the same
//  finite/range policy the engine/profile path enforces; this controller never
//  writes the engine — the caller applies the returned value to the preview.
//

#import "GPSLabSheetViewController.h"

NS_ASSUME_NONNULL_BEGIN

@interface GPSLabAltitudeViewController : GPSLabSheetViewController

/** The value shown when the editor opens (the current preview/engine altitude). */
@property (nonatomic, assign) double initialValue;

/** Called with a validated value when the user applies (or resets to zero). */
@property (nonatomic, copy, nullable) void (^applyHandler)(double value);

@end

NS_ASSUME_NONNULL_END
