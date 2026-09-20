//
//  GPSLabRecentsViewController.m
//  GPSLab
//
//  Native list of recent anchors. Bounded to the store's allow-list entries.
//

#import "GPSLabRecentsViewController.h"

#import "GPSLabLocalization.h"
#import "GPSLabModalCoordinator.h"
#import "GPSLabStore.h"

@implementation GPSLabRecentsViewController {
    NSMutableArray<NSDictionary *> *_recents;
    UILabel *_emptyLabel;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@""
                                                                               style:UIBarButtonItemStylePlain
                                                                              target:self
                                                                              action:@selector(clearTapped)];
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
    [self reloadRecents];
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
    self.title = GPSLabLocalized(@"recents.title");
    self.navigationItem.rightBarButtonItem.title = GPSLabLocalized(@"recents.clear");
    _emptyLabel.text = GPSLabLocalized(@"recents.empty");
    [GPSLabLocalization applyLanguageAttributesToView:self.view];
}

- (void)reloadRecents {
    _recents = [[[GPSLabStore sharedStore] loadRecents] mutableCopy];
    self.tableView.backgroundView.hidden = _recents.count > 0;
    [self.tableView reloadData];
}

- (void)clearTapped {
    if (_recents.count == 0) {
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:GPSLabLocalized(@"recents.clear.title")
                                                                   message:GPSLabLocalized(@"recents.clear.message")
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [alert addAction:[UIAlertAction actionWithTitle:GPSLabLocalized(@"common.cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    GPSLabRecentsViewController *__weak weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:GPSLabLocalized(@"recents.clear")
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
        (void)action;
        GPSLabRecentsViewController *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        [[GPSLabStore sharedStore] clearRecents];
        [strongSelf reloadRecents];
    }]];
    // An action sheet needs an anchor on iPad; without it the presentation traps.
    if (alert.popoverPresentationController != nil) {
        alert.popoverPresentationController.sourceView = self.view;
        alert.popoverPresentationController.sourceRect = self.view.bounds;
    }
    [[GPSLabModalCoordinator sharedCoordinator] presentAlert:alert completion:nil];
}

#pragma mark - Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)_recents.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"recentCell"];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"recentCell"];
    }
    NSDictionary *recent = _recents[(NSUInteger)indexPath.row];
    cell.textLabel.text = GPSLabLocalized(@"recents.cell.title");
    NSString *latitude = [GPSLabLocalization decimalString:[recent[@"latitude"] doubleValue]
                                            fractionDigits:4];
    NSString *longitude = [GPSLabLocalization decimalString:[recent[@"longitude"] doubleValue]
                                             fractionDigits:4];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@, %@", latitude, longitude];
    [GPSLabLocalization forceLeftToRight:cell.detailTextLabel];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if ((NSUInteger)indexPath.row >= _recents.count) {
        return;
    }
    NSDictionary *recent = _recents[(NSUInteger)indexPath.row];
    CLLocationCoordinate2D coordinate = CLLocationCoordinate2DMake([recent[@"latitude"] doubleValue],
                                                                   [recent[@"longitude"] doubleValue]);
    double altitude = [recent[@"altitude"] doubleValue];
    if (self.selectHandler != nil) {
        self.selectHandler(coordinate, altitude);
    }
    [self gpslab_dismissSheet];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    GPSLabRecentsViewController *__weak weakSelf = self;
    NSUInteger row = (NSUInteger)indexPath.row;
    UIContextualAction *delete = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                         title:GPSLabLocalized(@"common.delete")
                                                                       handler:^(UIContextualAction *action,
                                                                                 UIView *sourceView,
                                                                                 void (^completionHandler)(BOOL)) {
        (void)action;
        (void)sourceView;
        GPSLabRecentsViewController *strongSelf = weakSelf;
        if (strongSelf == nil) {
            completionHandler(NO);
            return;
        }
        [[GPSLabStore sharedStore] deleteRecentAtIndex:row];
        [strongSelf reloadRecents];
        completionHandler(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[delete]];
}

@end
