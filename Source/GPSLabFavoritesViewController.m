//
//  GPSLabFavoritesViewController.m
//  GPSLab
//
//  Native list of named anchors. All mutations go through GPSLabStore; the view
//  only reads/refreshes and reports a selection.
//

#import "GPSLabFavoritesViewController.h"

#import "GPSLabEngine.h"

@implementation GPSLabFavoritesViewController {
    NSMutableArray<GPSLabBookmark *> *_bookmarks;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Favorites";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                                                           target:self
                                                                                           action:@selector(addTapped)];
    [self reloadBookmarks];
}

- (void)reloadBookmarks {
    _bookmarks = [[[GPSLabStore sharedStore] loadBookmarks] mutableCopy];
    [self.tableView reloadData];
}

#pragma mark - Actions

- (void)addTapped {
    GPSLabConfiguration *configuration = [[GPSLabEngine sharedEngine] configuration];
    CLLocationCoordinate2D coordinate = [[GPSLabEngine sharedEngine] baseCoordinate];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Add favorite"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"Name";
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    GPSLabFavoritesViewController *__weak weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Save"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        (void)action;
        GPSLabFavoritesViewController *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        NSString *name = alert.textFields.firstObject.text;
        if (name.length == 0) {
            name = @"Favorite";
        }
        GPSLabBookmark *bookmark = [GPSLabBookmark bookmarkWithName:name
                                                          coordinate:coordinate
                                                            altitude:configuration.altitude];
        [[GPSLabStore sharedStore] addBookmark:bookmark];
        [strongSelf reloadBookmarks];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)renameBookmarkAtIndex:(NSUInteger)index {
    if (index >= _bookmarks.count) {
        return;
    }
    GPSLabBookmark *bookmark = _bookmarks[index];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Rename favorite"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.text = bookmark.name;
        textField.placeholder = @"Name";
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    GPSLabFavoritesViewController *__weak weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Rename"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        (void)action;
        GPSLabFavoritesViewController *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        NSString *name = alert.textFields.firstObject.text;
        [[GPSLabStore sharedStore] renameBookmarkAtIndex:index name:name];
        [strongSelf reloadBookmarks];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)_bookmarks.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"favoriteCell"];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"favoriteCell"];
    }
    GPSLabBookmark *bookmark = _bookmarks[(NSUInteger)indexPath.row];
    cell.textLabel.text = bookmark.name;
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%.4f, %.4f", bookmark.latitude, bookmark.longitude];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if ((NSUInteger)indexPath.row >= _bookmarks.count) {
        return;
    }
    if (self.selectHandler != nil) {
        self.selectHandler(_bookmarks[(NSUInteger)indexPath.row]);
    }
    [self gpslab_dismissSheet];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    GPSLabFavoritesViewController *__weak weakSelf = self;
    NSUInteger row = (NSUInteger)indexPath.row;

    UIContextualAction *rename = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                                                                         title:@"Rename"
                                                                       handler:^(UIContextualAction *action,
                                                                                 UIView *sourceView,
                                                                                 void (^completionHandler)(BOOL)) {
        (void)action;
        (void)sourceView;
        [weakSelf renameBookmarkAtIndex:row];
        completionHandler(YES);
    }];
    rename.backgroundColor = UIColor.systemBlueColor;

    UIContextualAction *delete = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                         title:@"Delete"
                                                                       handler:^(UIContextualAction *action,
                                                                                 UIView *sourceView,
                                                                                 void (^completionHandler)(BOOL)) {
        (void)action;
        (void)sourceView;
        GPSLabFavoritesViewController *strongSelf = weakSelf;
        if (strongSelf == nil) {
            completionHandler(NO);
            return;
        }
        [[GPSLabStore sharedStore] deleteBookmarkAtIndex:row];
        [strongSelf reloadBookmarks];
        completionHandler(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[rename, delete]];
}

@end
