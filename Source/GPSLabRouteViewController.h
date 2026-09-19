//
//  GPSLabRouteViewController.h
//  GPSLab
//
//  Route simulation sheet. Modes and speeds are the existing engine contract:
//  walking 5 km/h, cycling 15 km/h, driving 50 km/h, custom clamped 1..300 km/h.
//  Start/end are chosen on the map; this sheet only requests a pick and plays.
//

#import "GPSLabSheetViewController.h"

#import <MapKit/MapKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface GPSLabRouteViewController : GPSLabSheetViewController

@property (nonatomic, strong, nullable) MKMapItem *startItem;
@property (nonatomic, strong, nullable) MKMapItem *endItem;

/** Dismiss the sheet and arm map picking for the start / end point. */
@property (nonatomic, copy, nullable) void (^pickStartHandler)(void);
@property (nonatomic, copy, nullable) void (^pickEndHandler)(void);

/** Called whenever the route starts, stops or fails, so the map can redraw. */
@property (nonatomic, copy, nullable) void (^routeChangedHandler)(void);

@end

NS_ASSUME_NONNULL_END
