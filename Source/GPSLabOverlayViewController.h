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

/**
 * YES while the standalone search bar owns an active session. Kept as the
 * backwards-compatible adapter for the root-scene presentation contract.
 */
@property (nonatomic, readonly, getter=isSearchActive) BOOL searchActive;

/**
 * YES while the search session is active. The results controller is a
 * GPSLab-owned child (not a UIKit modal), so there is no dismissing phase and
 * this is equivalent to `isSearchActive` until the session is explicitly ended.
 */
@property (nonatomic, readonly, getter=isSearchSessionActive) BOOL searchSessionActive;

/** Ends an active search (idempotent; no-op when search is not active). */
- (void)endActiveSearch;

@end

NS_ASSUME_NONNULL_END
