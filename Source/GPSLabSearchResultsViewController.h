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

/** Cancels the in-flight search and invalidates any pending completion. */
- (void)cancelActiveSearch;

@end

NS_ASSUME_NONNULL_END
