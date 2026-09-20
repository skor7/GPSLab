//
//  GPSLabOptionsViewController.h
//  GPSLab
//
//  Minimal options/preferences sheet: manual coordinate, recents, fluctuation,
//  keep-last, map style and the optional real-location display. No diagnostics.
//

#import "GPSLabSheetViewController.h"

NS_ASSUME_NONNULL_BEGIN

/** Map style values used by the canvas; kept in-memory for this phase. */
typedef NS_ENUM(NSInteger, GPSLabMapStyle) {
    GPSLabMapStyleStandard = 0,
    GPSLabMapStyleHybrid,
    GPSLabMapStyleSatellite,
};

@interface GPSLabOptionsViewController : GPSLabSheetViewController

@property (nonatomic, assign) BOOL keepLastCoordinate;
@property (nonatomic, assign) BOOL realLocationEnabled;
@property (nonatomic, assign) BOOL engineEnabled;
@property (nonatomic, assign) NSInteger mapStyle;

/** Non-empty only when a status should be surfaced in settings (e.g. Grace). */
@property (nonatomic, copy, nullable) NSString *subscriptionStatusText;

@property (nonatomic, copy, nullable) void (^keepLastHandler)(BOOL keepLast);
@property (nonatomic, copy, nullable) void (^realLocationHandler)(BOOL enabled);
@property (nonatomic, copy, nullable) void (^engineEnabledHandler)(BOOL enabled);
@property (nonatomic, copy, nullable) void (^mapStyleHandler)(NSInteger style);

@property (nonatomic, copy, nullable) void (^manualEntryHandler)(void);
@property (nonatomic, copy, nullable) void (^recentsHandler)(void);
@property (nonatomic, copy, nullable) void (^fluctuationHandler)(void);

@end

NS_ASSUME_NONNULL_END
