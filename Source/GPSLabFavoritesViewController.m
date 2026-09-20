//
//  GPSLabFavoritesViewController.m
//  GPSLab
//
//  Native list of named anchors. All mutations go through GPSLabStore; the view
//  only reads/refreshes and reports a selection. User-entered names are never
//  translated; only GPSLab UI strings are localized.
//

#import "GPSLabFavoritesViewController.h"

#import "GPSLabEngine.h"
#import "GPSLabLocalization.h"
#import "GPSLabModalCoordinator.h"

@implementation GPSLabFavoritesViewController {
    NSMutableArray<GPSLabBookmark *> *_bookmarks;
    UILabel *_emptyLabel;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                                                           target:self
                                                                                           action:@selector(addTapped)];
    _emptyLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _emptyLabel.textAlignment = NSTextAlignmentCenter;
    _emptyLabel.numberOfLines = 0;
    _emptyLabel.textColor = UIColor.secondaryLabelColor;
    _emptyLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    _emptyLabel.adjustsFontForContentSizeCategory = YES;
    self.tableView.backgroundView = _emptyLabel;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(languageDidChange:)
                                                 name:GPSLabLanguageDidChangeNotification
                                               object:nil];
    [self gpslab_applyLocalization];
    [self reloadBookmarks];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Localization

- (void)languageDidChange:(NSNotification *)notification {
    (void)notification;
    [self gpslab_applyLocalization];
    [self.tableView reloadData];
}

- (void)gpslab_applyLocalization {
    self.title = GPSLabLocalized(@"favorites.title");
    self.navigationItem.rightBarButtonItem.accessibilityLabel =
        GPSLabLocalized(@"favorites.accessibility.add");
    _emptyLabel.text = GPSLabLocalized(@"favorites.empty");
    [GPSLabLocalization applyLanguageAttributesToView:self.view];
}

- (void)reloadBookmarks {
    _bookmarks = [[[GPSLabStore sharedStore] loadBookmarks] mutableCopy];
    self.tableView.backgroundView.hidden = _bookmarks.count > 0;
    [self.tableView reloadData];
}

#pragma mark - Actions

- (void)addTapped {
    GPSLabConfiguration *configuration = [[GPSLabEngine sharedEngine] configuration];
    CLLocationCoordinate2D coordinate = [[GPSLabEngine sharedEngine] baseCoordinate];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:GPSLabLocalized(@"favorites.add")
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = GPSLabLocalized(@"common.name");
    }];
    [alert addAction:[UIAlertAction actionWithTitle:GPSLabLocalized(@"common.cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    GPSLabFavoritesViewController *__weak weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:GPSLabLocalized(@"common.save")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        (void)action;
        GPSLabFavoritesViewController *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        NSString *name = alert.textFields.firstObject.text;
        if (name.length == 0) {
            name = GPSLabLocalized(@"favorites.defaultName");
        }
        GPSLabBookmark *bookmark = [GPSLabBookmark bookmarkWithName:name
                                                          coordinate:coordinate
                                                            altitude:configuration.altitude];
        [[GPSLabStore sharedStore] addBookmark:bookmark];
        [strongSelf reloadBookmarks];
    }]];
    [[GPSLabModalCoordinator sharedCoordinator] presentAlert:alert completion:nil];
}

- (void)renameBookmarkAtIndex:(NSUInteger)index {
    if (index >= _bookmarks.count) {
        return;
    }
    GPSLabBookmark *bookmark = _bookmarks[index];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:GPSLabLocalized(@"favorites.rename")
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.text = bookmark.name;
        textField.placeholder = GPSLabLocalized(@"common.name");
    }];
    [alert addAction:[UIAlertAction actionWithTitle:GPSLabLocalized(@"common.cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    GPSLabFavoritesViewController *__weak weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:GPSLabLocalized(@"common.rename")
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
    [[GPSLabModalCoordinator sharedCoordinator] presentAlert:alert completion:nil];
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
    NSString *latitude = [GPSLabLocalization decimalString:bookmark.latitude fractionDigits:4];
    NSString *longitude = [GPSLabLocalization decimalString:bookmark.longitude fractionDigits:4];
    NSString *coordinate = [NSString stringWithFormat:@"%@, %@", latitude, longitude];
    cell.detailTextLabel.text = coordinate;
    // Coordinates stay LTR even in Arabic.
    [GPSLabLocalization forceLeftToRight:cell.detailTextLabel];
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
                                                                         title:GPSLabLocalized(@"common.rename")
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
                                                                         title:GPSLabLocalized(@"common.delete")
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
