//
//  GPSLabSearchResultsViewController.m
//  GPSLab
//
//  MKLocalSearch results with stale-response protection. This controller is a
//  GPSLab-owned child of the overlay canvas, driven directly with the live
//  query (no UISearchController presentation layer).
//

#import "GPSLabSearchResultsViewController.h"

#import "GPSLabLocalization.h"
#import "GPSLabSearchLayoutCore.h"
#import "GPSLabStatusLog.h"

// Height of the results header that hosts the localized Done escape. The empty
// message is centered in the area BELOW this header so a compact panel never
// overlaps Done.
static const CGFloat kGPSLabSearchResultsHeaderHeight = 48.0;

@interface GPSLabSearchResultsViewController ()
@property (nonatomic, strong) NSArray<MKMapItem *> *results;
@property (nonatomic, strong, nullable) MKLocalSearch *activeSearch;
@property (nonatomic, assign) NSUInteger searchGeneration;
@property (nonatomic, copy) NSString *activeQuery;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) UIButton *doneButton;
@end

@implementation GPSLabSearchResultsViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStylePlain];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.results = @[];
    self.activeQuery = @"";
    self.tableView.estimatedRowHeight = 56.0;
    self.tableView.rowHeight = UITableViewAutomaticDimension;

    self.emptyLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.numberOfLines = 0;
    self.emptyLabel.textColor = UIColor.secondaryLabelColor;
    self.emptyLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.emptyLabel.adjustsFontForContentSizeCategory = YES;

    // A container background keeps the empty message centered in the area below
    // the header, so the compact panel does not overlap the Done button.
    UIView *background = [[UIView alloc] initWithFrame:CGRectZero];
    self.emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [background addSubview:self.emptyLabel];
    NSLayoutConstraint *emptyCenter =
        [self.emptyLabel.centerYAnchor constraintEqualToAnchor:background.centerYAnchor
                                                      constant:kGPSLabSearchResultsHeaderHeight / 2.0];
    emptyCenter.priority = 999.0; // prefers below the header, never unsatisfiable
    [NSLayoutConstraint activateConstraints:@[
        [self.emptyLabel.topAnchor constraintGreaterThanOrEqualToAnchor:background.topAnchor],
        emptyCenter,
        [self.emptyLabel.leadingAnchor constraintEqualToAnchor:background.leadingAnchor constant:16.0],
        [self.emptyLabel.trailingAnchor constraintEqualToAnchor:background.trailingAnchor constant:-16.0],
    ]];
    self.tableView.backgroundView = background;

    // Public-API escape: while search covers the canvas, a GPSLab-owned,
    // localized Done button stays reachable in the results header.
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 1, kGPSLabSearchResultsHeaderHeight)];
    header.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.doneButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.doneButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.doneButton addTarget:self action:@selector(doneTapped) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:self.doneButton];
    [NSLayoutConstraint activateConstraints:@[
        [self.doneButton.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-16.0],
        [self.doneButton.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
    ]];
    self.tableView.tableHeaderView = header;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(languageDidChange:)
                                                 name:GPSLabLanguageDidChangeNotification
                                               object:nil];
    [self applyLocalization];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self cancelActiveSearch];
}

- (void)applyLocalization {
    self.emptyLabel.text = GPSLabLocalized(@"search.empty");
    [self.doneButton setTitle:GPSLabLocalized(@"common.done") forState:UIControlStateNormal];
    self.doneButton.accessibilityLabel = GPSLabLocalized(@"common.done");
    [GPSLabLocalization applyLanguageAttributesToView:self.view];
}

- (void)doneTapped {
    if (self.doneHandler != nil) {
        self.doneHandler();
    }
}

- (void)languageDidChange:(NSNotification *)notification {
    (void)notification;
    [self applyLocalization];
}

#pragma mark - Content state

- (BOOL)hasResults {
    return self.results.count > 0;
}

- (CGFloat)estimatedContentHeight {
    if (self.results.count == 0) {
        return 0.0;
    }
    CGFloat row = [UIFontMetrics.defaultMetrics scaledValueForValue:56.0];
    return kGPSLabSearchResultsHeaderHeight + (CGFloat)self.results.count * row;
}

- (void)notifyContentChanged {
    if (self.contentChangeHandler != nil) {
        self.contentChangeHandler();
    }
}

- (void)updateEmptyState {
    self.emptyLabel.hidden = self.results.count > 0;
}

- (void)applyResults:(NSArray<MKMapItem *> *)results {
    self.results = results ?: @[];
    [self updateEmptyState];
    [self.tableView reloadData];
    [self notifyContentChanged];
}

- (void)cancelActiveSearch {
    // Bump the generation so any in-flight completion is ignored, then cancel it.
    self.searchGeneration += 1;
    if (self.activeSearch != nil) {
        [self.activeSearch cancel];
        self.activeSearch = nil;
    }
}

- (void)endSearchSession {
    // The session is over: drop the live query so a late response can never
    // repopulate the table on the next activation.
    [self cancelActiveSearch];
    self.activeQuery = @"";
    [self applyResults:@[]];
}

#pragma mark - Live query

- (void)updateSearchResultsForQuery:(NSString *)query {
    NSString *safeQuery = query ?: @"";

    // Any keystroke supersedes the previous request.
    [self cancelActiveSearch];

    if (!GPSLabSearchQueryIsSearchable((size_t)safeQuery.length)) {
        self.activeQuery = safeQuery;
        [self applyResults:@[]];
        return;
    }
    if ([safeQuery isEqualToString:self.activeQuery] && self.results.count > 0) {
        return;
    }
    self.activeQuery = safeQuery;

    NSUInteger generation = self.searchGeneration;
    NSString *expectedQuery = [safeQuery copy];

    // MKLocalSearchRequest/Response are soft-deprecated in favor of the
    // MKLocalSearch.Request/Response pair on newer SDKs; the older spellings are
    // still supported on iOS 16 and keep this compile-warning-free.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    MKLocalSearchRequest *request = [[MKLocalSearchRequest alloc] init];
    request.naturalLanguageQuery = safeQuery;

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
            [strongSelf applyResults:@[]];
        } else {
            [strongSelf applyResults:response.mapItems ?: @[]];
        }
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
