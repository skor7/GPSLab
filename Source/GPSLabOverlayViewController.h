//
//  GPSLabOverlayViewController.h
//  GPSLab
//
//  The floating overlay: a MapKit map, a draggable synthetic pin, search,
//  validated manual entry, keep-last, recents, bookmarks, drift and route controls.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface GPSLabOverlayViewController : UIViewController

/** YES while the search controller is active and owns the presentation context. */
@property (nonatomic, readonly, getter=isSearchActive) BOOL searchActive;

/** YES while the search session is active OR still dismissing (until didDismiss). */
@property (nonatomic, readonly, getter=isSearchSessionActive) BOOL searchSessionActive;

/** Ends an active search (no-op when search is not active). */
- (void)endActiveSearch;

@end

NS_ASSUME_NONNULL_END
