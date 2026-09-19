//
//  GPSLabFavoritesViewController.h
//  GPSLab
//
//  Favorites (named anchors): add, select, rename and delete.
//

#import "GPSLabSheetViewController.h"

#import "GPSLabStore.h"

NS_ASSUME_NONNULL_BEGIN

@interface GPSLabFavoritesViewController : UITableViewController

/** Called when the user selects a favorite. */
@property (nonatomic, copy, nullable) void (^selectHandler)(GPSLabBookmark *bookmark);

@end

NS_ASSUME_NONNULL_END
