//
//  GPSLabManualEntryViewController.h
//  GPSLab
//
//  Manual coordinate entry sheet with the same validation the dashboard used.
//

#import "GPSLabSheetViewController.h"

#import <CoreLocation/CoreLocation.h>

NS_ASSUME_NONNULL_BEGIN

@interface GPSLabManualEntryViewController : GPSLabSheetViewController

@property (nonatomic, assign) double initialLatitude;
@property (nonatomic, assign) double initialLongitude;
@property (nonatomic, assign) double initialAltitude;
@property (nonatomic, assign) double initialHeading;

/** Called only after validation passes. The sheet is expected to dismiss itself. */
@property (nonatomic, copy, nullable) void (^applyHandler)(CLLocationCoordinate2D coordinate,
                                                           double altitude,
                                                           double heading);

@end

NS_ASSUME_NONNULL_END
