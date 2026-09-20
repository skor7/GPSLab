//
//  GPSLabSearchResultsViewController.h
//  GPSLab
//
//  A concise search-results table backed by MKLocalSearch (never the completion-only
//  API), with generation-guarded cancellation so stale responses never win.
//
//  This controller is a GPSLab-owned CHILD of the overlay canvas: it is mounted
//  once with addChildViewController/didMove and is never presented by UIKit for
//  search. It receives the live query directly (no UISearchController involved)
//  and reports content changes so the overlay can bound its panel height.
//

#import <Foundation/Foundation.h>
#import <MapKit/MapKit.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface GPSLabSearchResultsViewController : UITableViewController

/** Invoked on the main queue when the user selects a result. */
@property (nonatomic, copy, nullable) void (^selectionHandler)(MKMapItem *item);

/**
 * Invoked when the user taps the always-available, GPSLab-localized Done escape
 * in the results header.
 */
@property (nonatomic, copy, nullable) void (^doneHandler)(void);

/** Invoked on the main queue whenever the result set / empty state changes. */
@property (nonatomic, copy, nullable) void (^contentChangeHandler)(void);

/** Drives the live query directly (replaces the UISearchResultsUpdating adapter). */
- (void)updateSearchResultsForQuery:(NSString *)query;

/** YES when the current result set has at least one row. */
@property (nonatomic, readonly) BOOL hasResults;

/** Estimated table height (header + rows) used to size the bounded panel. */
@property (nonatomic, readonly) CGFloat estimatedContentHeight;

/** Cancels the in-flight search and invalidates any pending completion. */
- (void)cancelActiveSearch;

/** Cancels the search and clears the live query/results when the session ends. */
- (void)endSearchSession;

@end

NS_ASSUME_NONNULL_END
