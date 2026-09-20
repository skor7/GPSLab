//
//  GPSLabScheduleViewController.h
//  GPSLab
//
//  Native schedule editor (once / time window). Stores UTC epoch seconds plus a
//  display timezone offset. The UI states the foreground-only limitation.
//

#import "GPSLabSheetViewController.h"

#import "GPSLabProfile.h"

NS_ASSUME_NONNULL_BEGIN

@interface GPSLabScheduleViewController : GPSLabSheetViewController

@property (nonatomic, copy, nullable) GPSLabProfileSchedule *schedule;

/** Passing nil clears the schedule. Returns YES when persisted; dismiss only then. */
@property (nonatomic, copy, nullable) BOOL (^saveHandler)(GPSLabProfileSchedule * _Nullable schedule);

@end

NS_ASSUME_NONNULL_END
