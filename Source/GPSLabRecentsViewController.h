//
//  GPSLabRecentsViewController.h
//  GPSLab
//
//  Recent anchors: select, swipe-delete and clear all. The 20-entry cap and the
//  5 m de-duplication live in GPSLabStore; this view only presents them.
//

#import "GPSLabSheetViewController.h"

#import <CoreLocation/CoreLocation.h>

NS_ASSUME_NONNULL_BEGIN

@interface GPSLabRecentsViewController : UITableViewController

/** Called when the user selects a recent. */
@property (nonatomic, copy, nullable) void (^selectHandler)(CLLocationCoordinate2D coordinate, double altitude);

@end

NS_ASSUME_NONNULL_END
