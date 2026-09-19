//
//  GPSLabFluctuationViewController.h
//  GPSLab
//
//  Drift ("location fluctuation") toggle and radius, driving the existing bounded
//  random-walk model in GPSLabEngine.
//

#import "GPSLabSheetViewController.h"

NS_ASSUME_NONNULL_BEGIN

@interface GPSLabFluctuationViewController : GPSLabSheetViewController

@property (nonatomic, assign) BOOL fluctuationEnabled;
@property (nonatomic, assign) double radiusMeters;

/** Called whenever the toggle or radius changes. The sheet does not persist directly. */
@property (nonatomic, copy, nullable) void (^changeHandler)(BOOL enabled, double radiusMeters);

@end

NS_ASSUME_NONNULL_END
