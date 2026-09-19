//
//  GPSLabRecentsViewController.m
//  GPSLab
//
//  Native list of recent anchors. Bounded to the store's allow-list entries.
//

#import "GPSLabRecentsViewController.h"

#import "GPSLabStore.h"

@implementation GPSLabRecentsViewController {
    NSMutableArray<NSDictionary *> *_recents;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Recents";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Clear"
                                                                               style:UIBarButtonItemStylePlain
                                                                              target:self
                                                                              action:@selector(clearTapped)];
    [self reloadRecents];
}

- (void)reloadRecents {
    _recents = [[[GPSLabStore sharedStore] loadRecents] mutableCopy];
    [self.tableView reloadData];
}

- (void)clearTapped {
    if (_recents.count == 0) {
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Clear recents"
                                                                   message:@"Remove every recent anchor?"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    GPSLabRecentsViewController *__weak weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Clear"
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
    [self presentViewController:alert animated:YES completion:nil];
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
    cell.textLabel.text = @"Recent";
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%.4f, %.4f",
                                 [recent[@"latitude"] doubleValue],
                                 [recent[@"longitude"] doubleValue]];
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
                                                                         title:@"Delete"
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
