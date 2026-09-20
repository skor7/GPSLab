//
//  GPSLabSearchResultsViewController.h
//  GPSLab
//
//  A concise search-results table backed by MKLocalSearch (never the completion-only
//  API), with generation-guarded cancellation so stale responses never win.
//

#import <Foundation/Foundation.h>
#import <MapKit/MapKit.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface GPSLabSearchResultsViewController : UITableViewController <UISearchResultsUpdating>

/** Invoked on the main queue when the user selects a result. */
@property (nonatomic, copy, nullable) void (^selectionHandler)(MKMapItem *item);

/**
 * Invoked when the user taps the always-available, GPSLab-localized Done escape
 * in the results header. Keeps a public-API exit reachable while the results
 * layer covers the canvas.
 */
@property (nonatomic, copy, nullable) void (^doneHandler)(void);

/** Cancels the in-flight search and invalidates any pending completion. */
- (void)cancelActiveSearch;

/** Cancels the search and clears the live query/results when the session ends. */
- (void)endSearchSession;

@end

NS_ASSUME_NONNULL_END
