//
//  GPSLabSearchResultsViewController.m
//  GPSLab
//
//  MKLocalSearch results with stale-response protection. Extracted from the old
//  dashboard so the map canvas stays small and focused.
//

#import "GPSLabSearchResultsViewController.h"

#import "GPSLabStatusLog.h"

@interface GPSLabSearchResultsViewController ()
@property (nonatomic, strong) NSArray<MKMapItem *> *results;
@property (nonatomic, strong, nullable) MKLocalSearch *activeSearch;
@property (nonatomic, assign) NSUInteger searchGeneration;
@property (nonatomic, copy) NSString *activeQuery;
@end

@implementation GPSLabSearchResultsViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStylePlain];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.results = @[];
    self.activeQuery = @"";
}

- (void)dealloc {
    [self cancelActiveSearch];
}

- (void)cancelActiveSearch {
    // Bump the generation so any in-flight completion is ignored, then cancel it.
    self.searchGeneration += 1;
    if (self.activeSearch != nil) {
        [self.activeSearch cancel];
        self.activeSearch = nil;
    }
}

#pragma mark - UISearchResultsUpdating

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *query = searchController.searchBar.text ?: @"";

    // Any keystroke supersedes the previous request.
    [self cancelActiveSearch];

    if (query.length < 3) {
        self.activeQuery = query;
        self.results = @[];
        [self.tableView reloadData];
        return;
    }
    if ([query isEqualToString:self.activeQuery] && self.results.count > 0) {
        return;
    }
    self.activeQuery = query;

    NSUInteger generation = self.searchGeneration;
    NSString *expectedQuery = [query copy];

    // MKLocalSearchRequest/Response are soft-deprecated in favor of the
    // MKLocalSearch.Request/Response pair on newer SDKs; the older spellings are
    // still supported on iOS 16 and keep this compile-warning-free.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    MKLocalSearchRequest *request = [[MKLocalSearchRequest alloc] init];
    request.naturalLanguageQuery = query;

    MKLocalSearch *search = [[MKLocalSearch alloc] initWithRequest:request];
    self.activeSearch = search;

    GPSLabSearchResultsViewController *__weak weakSelf = self;
    [search startWithCompletionHandler:^(MKLocalSearchResponse *response, NSError *error) {
        GPSLabSearchResultsViewController *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        // Ignore stale results: a newer search started, the query changed, or a
        // different request is now active.
        if (generation != strongSelf.searchGeneration) {
            return;
        }
        if (![expectedQuery isEqualToString:strongSelf.activeQuery]) {
            return;
        }
        strongSelf.activeSearch = nil;

        if (error != nil) {
            [GPSLabStatusLog append:@"Search failed"];
            strongSelf.results = @[];
        } else {
            strongSelf.results = response.mapItems ?: @[];
        }
        [strongSelf.tableView reloadData];
    }];
#pragma clang diagnostic pop
}

#pragma mark - Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.results.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"cell"];
    }
    MKMapItem *item = self.results[(NSUInteger)indexPath.row];
    cell.textLabel.text = item.name;
    cell.textLabel.numberOfLines = 1;
    cell.detailTextLabel.text = item.placemark.title;
    cell.detailTextLabel.numberOfLines = 1;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if ((NSUInteger)indexPath.row >= self.results.count) {
        return;
    }
    MKMapItem *item = self.results[(NSUInteger)indexPath.row];
    if (self.selectionHandler != nil) {
        self.selectionHandler(item);
    }
}

@end
