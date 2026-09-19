//
//  GPSLabOverlayViewController.m
//  GPSLab
//
//  Native-controls-only overlay UI. English only, no external branding.
//  The controller observes GPSLabEngine state and never reads real device location
//  except when the user explicitly opts in to display it (and it is never persisted).
//

#import "GPSLabOverlayViewController.h"

#import <CoreLocation/CoreLocation.h>
#import <MapKit/MapKit.h>

#import "CoreLocationHooks.h"
#import "Diagnostics.h"
#import "GPSLabEngine.h"
#import "GPSLabGeodesy.h"
#import "GPSLabOverlayPresenter.h"
#import "GPSLabStatusLog.h"
#import "GPSLabStore.h"
#import "GPSLabTypes.h"

#pragma mark - Annotation

@interface GPSLabSyntheticAnnotation : NSObject <MKAnnotation>
@property (nonatomic, assign) CLLocationCoordinate2D coordinate;
@property (nonatomic, copy, nullable) NSString *title;
@end

@implementation GPSLabSyntheticAnnotation
@end

#pragma mark - Overlay scroll view

// The overlay content scroll view hosts an interactive MKMapView. It keeps normal
// touch cancellation for fields/buttons (so the panel scrolls as expected) but never
// cancels touches that begin on the map, which would break MapKit pan/zoom. This is
// the minimal override; no gesture delegate is involved.
@interface GPSLabOverlayScrollView : UIScrollView
@end

@implementation GPSLabOverlayScrollView

- (BOOL)touchesShouldCancelInContentView:(UIView *)view {
    for (UIView *candidate = view; candidate != nil; candidate = candidate.superview) {
        if ([candidate isKindOfClass:[MKMapView class]]) {
            return NO;
        }
    }
    return [super touchesShouldCancelInContentView:view];
}

@end

#pragma mark - Search results

@interface GPSLabSearchResultsViewController : UITableViewController <UISearchResultsUpdating>
@property (nonatomic, strong) NSArray<MKMapItem *> *results;
@property (nonatomic, copy, nullable) void (^selectionHandler)(MKMapItem *item);
@property (nonatomic, strong, nullable) MKLocalSearch *activeSearch;
@property (nonatomic, assign) NSUInteger searchGeneration;
@property (nonatomic, copy) NSString *activeQuery;

/** Cancels the in-flight search and invalidates any pending completion. */
- (void)cancelActiveSearch;
@end

@implementation GPSLabSearchResultsViewController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStylePlain];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.results = @[];
    self.activeQuery = @"";
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"cell"];
}

- (void)dealloc {
    [self cancelActiveSearch];
}

- (void)cancelActiveSearch {
    // Bump the generation so any in-flight completion is ignored, and cancel it.
    self.searchGeneration += 1;
    if (self.activeSearch != nil) {
        [self.activeSearch cancel];
        self.activeSearch = nil;
    }
}

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

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.results.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell" forIndexPath:indexPath];
    MKMapItem *item = self.results[(NSUInteger)indexPath.row];
    cell.textLabel.text = item.name;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if ((NSUInteger)indexPath.row >= self.results.count) {
        return;
    }
    MKMapItem *item = self.results[(NSUInteger)indexPath.row];
    if (self.selectionHandler != nil) {
        self.selectionHandler(item);
    }
}

@end

#pragma mark - Overlay controller

@interface GPSLabOverlayViewController () <MKMapViewDelegate, CLLocationManagerDelegate,
                                            UISearchControllerDelegate, UITableViewDelegate,
                                            UITableViewDataSource, UITextFieldDelegate>

@property (nonatomic, strong) UIVisualEffectView *panel;
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) MKMapView *mapView;
@property (nonatomic, strong) MKPointAnnotation *routeStartPin;
@property (nonatomic, strong) MKPointAnnotation *routeEndPin;
@property (nonatomic, strong) GPSLabSyntheticAnnotation *syntheticAnnotation;
@property (nonatomic, strong) MKPolyline *routeOverlay;
@property (nonatomic, strong, nullable) NSLayoutConstraint *mapHeightConstraint;

@property (nonatomic, strong) UISwitch *enabledSwitch;
@property (nonatomic, strong) UITextField *latitudeField;
@property (nonatomic, strong) UITextField *longitudeField;
@property (nonatomic, strong) UITextField *altitudeField;
@property (nonatomic, strong) UITextField *headingField;
@property (nonatomic, strong) UILabel *coordinateLabel;

@property (nonatomic, strong) UISwitch *keepLastSwitch;
@property (nonatomic, strong) UISwitch *driftSwitch;
@property (nonatomic, strong) UISlider *driftSlider;
@property (nonatomic, strong) UILabel *radiusValueLabelRef;

@property (nonatomic, strong) UISegmentedControl *routeModeControl;
@property (nonatomic, strong) UITextField *customSpeedField;
@property (nonatomic, strong) UISegmentedControl *stopBehaviorControl;
@property (nonatomic, strong) UIProgressView *routeProgress;
@property (nonatomic, strong) UILabel *routeStatusLabel;
@property (nonatomic, strong) UIButton *setStartButton;
@property (nonatomic, strong) UIButton *setEndButton;
@property (nonatomic, strong) UIButton *playButton;
@property (nonatomic, strong) UIButton *pauseButton;
@property (nonatomic, strong) UIButton *stopButton;

@property (nonatomic, strong) UISwitch *showRealLocationSwitch;
@property (nonatomic, strong) MKPointAnnotation *realLocationAnnotation;
@property (nonatomic, strong) UISearchController *searchController;
@property (nonatomic, strong) GPSLabSearchResultsViewController *searchResultsController;

@property (nonatomic, strong) NSMutableArray<NSDictionary *> *recents;
@property (nonatomic, strong) NSMutableArray<GPSLabBookmark *> *bookmarks;
@property (nonatomic, strong) MKMapItem *pendingRouteStartItem;
@property (nonatomic, strong) MKMapItem *pendingRouteEndItem;
@property (nonatomic, assign) BOOL hasPendingStart;
@property (nonatomic, assign) BOOL hasPendingEnd;
@property (nonatomic, strong) NSTimer *tickTimer;

@property (nonatomic, strong) CLLocationManager *displayLocationManager;

@end

@implementation GPSLabOverlayViewController

#pragma mark - Lifecycle

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = UIColor.clearColor;
    [self buildBackground];
    // The map is constructed first so the panel can embed it in the scroll content.
    [self buildMap];
    [self buildPanel];
    [self buildSearch];
    [self attachSelectionHandler];
    [self reloadPersistedState];
    [self loadCurrentConfigurationIntoFields];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(engineStateDidChange:)
                                                 name:GPSLabEngineStateDidChangeNotification
                                               object:nil];
}

- (void)attachSelectionHandler {
    GPSLabOverlayViewController *__weak weakSelf = self;
    self.searchResultsController.selectionHandler = ^(MKMapItem *item) {
        [weakSelf applyMapItem:item];
    };
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self startTickTimer];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self stopTickTimer];
    [self stopRealLocationDisplay];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self stopTickTimer];
    [self stopRealLocationDisplay];
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    // Reconcile the map height with the current orientation each layout pass; only
    // assign on change so Auto Layout never loops. The map stays inside the scroll
    // content, so a short landscape simply scrolls instead of clipping.
    CGFloat height = [self preferredMapHeight];
    if (self.mapHeightConstraint.constant != height) {
        self.mapHeightConstraint.constant = height;
    }
}

#pragma mark - Construction

- (void)buildBackground {
    UIView *background = [[UIView alloc] initWithFrame:self.view.bounds];
    background.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.28];
    background.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:background];
}

- (void)buildPanel {
    UIVisualEffectView *panel = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    panel.layer.cornerRadius = 16.0;
    panel.layer.masksToBounds = YES;
    [self.view addSubview:panel];
    self.panel = panel;

    GPSLabOverlayScrollView *scrollView = [[GPSLabOverlayScrollView alloc] initWithFrame:CGRectZero];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.alwaysBounceVertical = YES;
    // Give the embedded map touches immediately (no 150ms delay). Cancellation stays
    // enabled for fields/buttons, while GPSLabOverlayScrollView refuses to cancel
    // touches that begin inside MKMapView so map pan/zoom is preserved.
    scrollView.delaysContentTouches = NO;
    [panel.contentView addSubview:scrollView];
    self.scrollView = scrollView;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectZero];
    title.text = @"GPSLab";
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle2];
    title.adjustsFontForContentSizeCategory = YES;

    UIButton *closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [closeButton setTitle:@"Close" forState:UIControlStateNormal];
    [closeButton addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[title, [UIView new], closeButton]];
    header.axis = UILayoutConstraintAxisHorizontal;
    header.alignment = UIStackViewAlignmentCenter;

    self.coordinateLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.coordinateLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    self.coordinateLabel.adjustsFontForContentSizeCategory = YES;
    self.coordinateLabel.numberOfLines = 2;

    UIStackView *column = [[UIStackView alloc] initWithArrangedSubviews:@[
        header,
        self.coordinateLabel,
        [self buildMapSection],
        [self buildAnchorSection],
        [self buildDriftSection],
        [self buildRouteSection],
        [self buildBookmarksSection],
        [self buildRecentsSection],
    ]];
    column.axis = UILayoutConstraintAxisVertical;
    column.spacing = 12.0;
    column.translatesAutoresizingMaskIntoConstraints = NO;
    [scrollView addSubview:column];

    UILayoutGuide *safeArea = self.view.safeAreaLayoutGuide;
    UILayoutGuide *contentGuide = scrollView.contentLayoutGuide;
    UILayoutGuide *frameGuide = scrollView.frameLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [panel.leadingAnchor constraintEqualToAnchor:safeArea.leadingAnchor constant:12.0],
        [panel.trailingAnchor constraintEqualToAnchor:safeArea.trailingAnchor constant:-12.0],
        [panel.topAnchor constraintEqualToAnchor:safeArea.topAnchor constant:12.0],
        [panel.bottomAnchor constraintEqualToAnchor:safeArea.bottomAnchor constant:-12.0],

        [scrollView.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor],
        [scrollView.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor],
        [scrollView.topAnchor constraintEqualToAnchor:panel.contentView.topAnchor],
        [scrollView.bottomAnchor constraintEqualToAnchor:panel.contentView.bottomAnchor],

        // Content size is defined by contentLayoutGuide; the width is pinned to the
        // visible frameLayoutGuide (minus insets) so there is never horizontal scroll
        // and vertical scrolling works in portrait and landscape.
        [column.leadingAnchor constraintEqualToAnchor:contentGuide.leadingAnchor constant:16.0],
        [column.trailingAnchor constraintEqualToAnchor:contentGuide.trailingAnchor constant:-16.0],
        [column.topAnchor constraintEqualToAnchor:contentGuide.topAnchor constant:16.0],
        [column.bottomAnchor constraintEqualToAnchor:contentGuide.bottomAnchor constant:-16.0],
        [column.widthAnchor constraintEqualToAnchor:frameGuide.widthAnchor constant:-32.0],
    ]];
}

- (UIStackView *)sectionWithTitle:(NSString *)title content:(UIView *)content {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.text = title;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    label.adjustsFontForContentSizeCategory = YES;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[label, content]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 8.0;
    return stack;
}

- (UIStackView *)buildAnchorSection {
    self.enabledSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
    [self.enabledSwitch addTarget:self action:@selector(enabledChanged) forControlEvents:UIControlEventValueChanged];

    UIStackView *enabledRow = [self rowWithLabel:@"Enabled" control:self.enabledSwitch];

    self.latitudeField = [self decimalFieldWithPlaceholder:@"Latitude"];
    self.longitudeField = [self decimalFieldWithPlaceholder:@"Longitude"];
    self.altitudeField = [self decimalFieldWithPlaceholder:@"Altitude (m)"];
    self.headingField = [self decimalFieldWithPlaceholder:@"Course (deg or -1)"];

    UIButton *applyButton = [self actionButtonWithTitle:@"Apply" action:@selector(applyManualEntry)];

    self.keepLastSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
    [self.keepLastSwitch addTarget:self action:@selector(keepLastChanged) forControlEvents:UIControlEventValueChanged];
    UIStackView *keepLastRow = [self rowWithLabel:@"Keep last coordinate" control:self.keepLastSwitch];

    self.showRealLocationSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
    [self.showRealLocationSwitch addTarget:self action:@selector(showRealLocationChanged) forControlEvents:UIControlEventValueChanged];
    UIStackView *showRealRow = [self rowWithLabel:@"Show real user location" control:self.showRealLocationSwitch];

    UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:@[
        enabledRow,
        self.latitudeField,
        self.longitudeField,
        self.altitudeField,
        self.headingField,
        applyButton,
        keepLastRow,
        showRealRow,
    ]];
    content.axis = UILayoutConstraintAxisVertical;
    content.spacing = 8.0;

    return [self sectionWithTitle:@"Anchor" content:content];
}

- (UIStackView *)buildMapSection {
    // Search and Center live next to the map, reusing the existing handlers.
    UIButton *searchButton = [self actionButtonWithTitle:@"Search" action:@selector(presentSearch)];
    UIButton *centerButton = [self actionButtonWithTitle:@"Center on synthetic" action:@selector(centerOnSynthetic)];

    UIStackView *buttonRow = [[UIStackView alloc] initWithArrangedSubviews:@[searchButton, centerButton]];
    buttonRow.axis = UILayoutConstraintAxisHorizontal;
    buttonRow.distribution = UIStackViewDistributionFillEqually;
    buttonRow.spacing = 8.0;

    // A fixed, adaptive height keeps the map readable in both orientations while the
    // enclosing scroll view absorbs any short-landscape overflow (no conflicting
    // constraints with the scroll content).
    self.mapHeightConstraint = [self.mapView.heightAnchor constraintEqualToConstant:[self preferredMapHeight]];
    self.mapHeightConstraint.active = YES;

    UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:@[self.mapView, buttonRow]];
    content.axis = UILayoutConstraintAxisVertical;
    content.spacing = 8.0;

    return [self sectionWithTitle:@"Map" content:content];
}

- (CGFloat)preferredMapHeight {
    // Compact vertical size class (e.g. landscape iPhone) gets the lower bound.
    if (self.traitCollection.verticalSizeClass == UIUserInterfaceSizeClassCompact) {
        return 280.0;
    }
    return 300.0;
}

- (UIStackView *)buildDriftSection {
    self.driftSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
    [self.driftSwitch addTarget:self action:@selector(driftChanged) forControlEvents:UIControlEventValueChanged];
    UIStackView *driftRow = [self rowWithLabel:@"Bounded random walk" control:self.driftSwitch];

    UILabel *radiusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    radiusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    radiusLabel.adjustsFontForContentSizeCategory = YES;
    radiusLabel.textAlignment = NSTextAlignmentRight;
    self.radiusValueLabelRef = radiusLabel;

    self.driftSlider = [[UISlider alloc] initWithFrame:CGRectZero];
    self.driftSlider.minimumValue = 1.0;
    self.driftSlider.maximumValue = 100.0;
    [self.driftSlider addTarget:self action:@selector(driftRadiusChanged) forControlEvents:UIControlEventValueChanged];

    UIStackView *sliderRow = [[UIStackView alloc] initWithArrangedSubviews:@[self.driftSlider, radiusLabel]];
    sliderRow.axis = UILayoutConstraintAxisHorizontal;
    sliderRow.alignment = UIStackViewAlignmentCenter;
    sliderRow.spacing = 8.0;

    UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:@[driftRow, sliderRow]];
    content.axis = UILayoutConstraintAxisVertical;
    content.spacing = 8.0;
    return [self sectionWithTitle:@"Drift" content:content];
}

- (UIStackView *)buildRouteSection {
    self.routeModeControl = [[UISegmentedControl alloc] initWithItems:@[
        GPSLabRouteModeName(GPSLabRouteModeDriving),
        GPSLabRouteModeName(GPSLabRouteModeWalking),
        GPSLabRouteModeName(GPSLabRouteModeCycling),
        GPSLabRouteModeName(GPSLabRouteModeCustom),
    ]];
    [self.routeModeControl addTarget:self action:@selector(routeModeChanged) forControlEvents:UIControlEventValueChanged];

    self.customSpeedField = [self decimalFieldWithPlaceholder:@"Custom speed (km/h)"];
    self.customSpeedField.keyboardType = UIKeyboardTypeDecimalPad;

    self.stopBehaviorControl = [[UISegmentedControl alloc] initWithItems:@[
        GPSLabStopBehaviorName(GPSLabStopBehaviorStayAtCurrent),
        GPSLabStopBehaviorName(GPSLabStopBehaviorReturnToStart),
    ]];
    [self.stopBehaviorControl addTarget:self action:@selector(stopBehaviorChanged) forControlEvents:UIControlEventValueChanged];

    self.setStartButton = [self actionButtonWithTitle:@"Set route start" action:@selector(setRouteStart)];
    self.setEndButton = [self actionButtonWithTitle:@"Set route end" action:@selector(setRouteEnd)];

    self.playButton = [self actionButtonWithTitle:@"Start route" action:@selector(startRoute)];
    self.pauseButton = [self actionButtonWithTitle:@"Pause / Resume" action:@selector(togglePauseRoute)];
    self.stopButton = [self actionButtonWithTitle:@"Stop route" action:@selector(stopRoute)];

    self.routeProgress = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    self.routeProgress.progress = 0.0;
    self.routeStatusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.routeStatusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    self.routeStatusLabel.adjustsFontForContentSizeCategory = YES;
    self.routeStatusLabel.numberOfLines = 2;
    self.routeStatusLabel.text = @"Idle";

    UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.routeModeControl,
        self.customSpeedField,
        self.stopBehaviorControl,
        self.setStartButton,
        self.setEndButton,
        self.playButton,
        self.pauseButton,
        self.stopButton,
        self.routeProgress,
        self.routeStatusLabel,
    ]];
    content.axis = UILayoutConstraintAxisVertical;
    content.spacing = 8.0;
    return [self sectionWithTitle:@"Route" content:content];
}

- (UIStackView *)buildBookmarksSection {
    UIButton *addButton = [self actionButtonWithTitle:@"Add bookmark" action:@selector(addBookmark)];

    UITableView *tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    tableView.dataSource = self;
    tableView.delegate = self;
    tableView.tag = 1;
    tableView.scrollEnabled = NO;
    tableView.translatesAutoresizingMaskIntoConstraints = NO;
    [tableView.heightAnchor constraintGreaterThanOrEqualToConstant:44.0].active = YES;

    UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:@[addButton, tableView]];
    content.axis = UILayoutConstraintAxisVertical;
    content.spacing = 8.0;
    return [self sectionWithTitle:@"Bookmarks" content:content];
}

- (UIStackView *)buildRecentsSection {
    UIButton *clearButton = [self actionButtonWithTitle:@"Clear recents" action:@selector(clearRecents)];

    UITableView *tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    tableView.dataSource = self;
    tableView.delegate = self;
    tableView.tag = 2;
    tableView.scrollEnabled = NO;
    tableView.translatesAutoresizingMaskIntoConstraints = NO;
    [tableView.heightAnchor constraintGreaterThanOrEqualToConstant:44.0].active = YES;

    UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:@[clearButton, tableView]];
    content.axis = UILayoutConstraintAxisVertical;
    content.spacing = 8.0;
    return [self sectionWithTitle:@"Recents" content:content];
}

- (UIStackView *)rowWithLabel:(NSString *)text control:(UIView *)control {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.text = text;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    label.adjustsFontForContentSizeCategory = YES;

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[label, [UIView new], control]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    return row;
}

- (UITextField *)decimalFieldWithPlaceholder:(NSString *)placeholder {
    UITextField *field = [[UITextField alloc] initWithFrame:CGRectZero];
    field.placeholder = placeholder;
    field.borderStyle = UITextBorderStyleRoundedRect;
    field.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.delegate = self;
    return field;
}

- (UIButton *)actionButtonWithTitle:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.adjustsFontForContentSizeCategory = YES;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)buildMap {
    // The map is a visible arranged subview of the panel's scroll content (inserted
    // by buildMapSection). It is intentionally NOT placed behind the panel.
    MKMapView *mapView = [[MKMapView alloc] initWithFrame:CGRectZero];
    mapView.translatesAutoresizingMaskIntoConstraints = NO;
    mapView.delegate = self;
    mapView.showsUserLocation = NO;
    mapView.pointOfInterestFilter = [MKPointOfInterestFilter filterIncludingAllCategories];
    // Keep MapKit interaction enabled; the outer scroll view is configured in
    // buildPanel to not steal touches that begin on the map.
    mapView.scrollEnabled = YES;
    mapView.zoomEnabled = YES;
    self.mapView = mapView;

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(mapTapped:)];
    [mapView addGestureRecognizer:tap];

    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(mapLongPressed:)];
    [mapView addGestureRecognizer:longPress];

    self.syntheticAnnotation = [[GPSLabSyntheticAnnotation alloc] init];
    self.syntheticAnnotation.title = @"Synthetic";
    [mapView addAnnotation:self.syntheticAnnotation];
}

- (void)buildSearch {
    GPSLabSearchResultsViewController *results = [[GPSLabSearchResultsViewController alloc] init];
    self.searchResultsController = results;
}

- (void)presentSearch {
    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:self.searchResultsController];
    search.searchResultsUpdater = self.searchResultsController;
    search.delegate = self;
    search.obscuresBackgroundDuringPresentation = NO;
    search.searchBar.placeholder = @"Search address or place";
    self.searchController = search;
    [self presentViewController:search animated:YES completion:nil];
}

#pragma mark - UISearchControllerDelegate

- (void)didDismissSearchController:(UISearchController *)searchController {
    // A dismissed search must not keep an in-flight request alive or let a late
    // response repopulate the (now hidden) results table.
    [self.searchResultsController cancelActiveSearch];
}

#pragma mark - Persistence loading

- (void)reloadPersistedState {
    self.recents = [[[GPSLabStore sharedStore] loadRecents] mutableCopy];
    self.bookmarks = [[[GPSLabStore sharedStore] loadBookmarks] mutableCopy];
    for (UITableView *tableView in [self overlayTableViews]) {
        [tableView reloadData];
    }
}

- (NSArray<UITableView *> *)overlayTableViews {
    NSMutableArray<UITableView *> *tables = [NSMutableArray array];
    [self collectTableViewsIn:self.view into:tables];
    return tables;
}

- (void)collectTableViewsIn:(UIView *)view into:(NSMutableArray<UITableView *> *)tables {
    for (UIView *subview in view.subviews) {
        if ([subview isKindOfClass:[UITableView class]]) {
            [tables addObject:(UITableView *)subview];
        } else {
            [self collectTableViewsIn:subview into:tables];
        }
    }
}

- (void)loadCurrentConfigurationIntoFields {
    GPSLabConfiguration *configuration = [[GPSLabEngine sharedEngine] configuration];

    self.enabledSwitch.on = configuration.enabled;
    self.latitudeField.text = [NSString stringWithFormat:@"%.6f", configuration.latitude];
    self.longitudeField.text = [NSString stringWithFormat:@"%.6f", configuration.longitude];
    self.altitudeField.text = [NSString stringWithFormat:@"%.1f", configuration.altitude];
    self.headingField.text = [NSString stringWithFormat:@"%.1f", configuration.heading];

    self.keepLastSwitch.on = configuration.keepLastCoordinate;
    self.driftSwitch.on = configuration.driftEnabled;
    self.driftSlider.value = (float)configuration.driftRadiusMeters;
    self.radiusValueLabelRef.text = [NSString stringWithFormat:@"%.0f m", configuration.driftRadiusMeters];

    self.routeModeControl.selectedSegmentIndex = configuration.routeMode;
    self.customSpeedField.text = [NSString stringWithFormat:@"%.1f", configuration.routeCustomSpeedKmh];
    self.stopBehaviorControl.selectedSegmentIndex = configuration.stopBehavior;

    [self updateCoordinateLabel];
    [self updateMapFromState];
}

#pragma mark - Actions

- (void)closeTapped {
    [[GPSLabOverlayPresenter sharedPresenter] dismissOverlay];
}

- (void)enabledChanged {
    [[GPSLabEngine sharedEngine] setEnabledAndNotify:self.enabledSwitch.on];
    [GPSLabStatusLog append:(self.enabledSwitch.on ? @"Engine enabled" : @"Engine disabled")];
}

- (void)applyManualEntry {
    double latitude = [self.latitudeField.text doubleValue];
    double longitude = [self.longitudeField.text doubleValue];
    double altitude = [self.altitudeField.text doubleValue];
    double heading = [self.headingField.text length] > 0 ? [self.headingField.text doubleValue] : -1.0;

    if (!GPSLabIsValidCoordinate(latitude, longitude)) {
        [self showAlertWithTitle:@"Invalid coordinate" message:@"Latitude must be -90..90 and longitude -180..180."];
        return;
    }

    GPSLabConfiguration *configuration = [[GPSLabEngine sharedEngine] configuration];
    configuration.latitude = latitude;
    configuration.longitude = longitude;
    configuration.altitude = GPSLabClampDouble(altitude, -500.0, 100000.0);
    configuration.heading = heading;
    [[GPSLabEngine sharedEngine] applyConfiguration:configuration];
    [[GPSLabEngine sharedEngine] persistConfiguration];

    [[GPSLabStore sharedStore] addRecentCoordinate:CLLocationCoordinate2DMake(latitude, longitude)
                                          altitude:configuration.altitude];
    [self reloadPersistedState];
    [self updateCoordinateLabel];
    [self updateMapFromState];
    [GPSLabStatusLog append:@"Anchor applied"];
}

- (void)keepLastChanged {
    [[GPSLabEngine sharedEngine] setKeepLastCoordinate:self.keepLastSwitch.on];
    [self loadCurrentConfigurationIntoFields];
    [GPSLabStatusLog append:(self.keepLastSwitch.on ? @"Keep last on" : @"Keep last off")];
}

- (void)driftChanged {
    [[GPSLabEngine sharedEngine] setDriftEnabled:self.driftSwitch.on];
}

- (void)driftRadiusChanged {
    self.radiusValueLabelRef.text = [NSString stringWithFormat:@"%.0f m", self.driftSlider.value];
    [[GPSLabEngine sharedEngine] setDriftRadiusMeters:self.driftSlider.value];
}

- (void)centerOnSynthetic {
    CLLocationCoordinate2D coordinate = [[GPSLabEngine sharedEngine] baseCoordinate];
    [self.mapView setRegion:MKCoordinateRegionMakeWithDistance(coordinate, 800.0, 800.0) animated:YES];
}

- (void)routeModeChanged {
    GPSLabConfiguration *configuration = [[GPSLabEngine sharedEngine] configuration];
    configuration.routeMode = (GPSLabRouteMode)self.routeModeControl.selectedSegmentIndex;
    [[GPSLabEngine sharedEngine] applyConfiguration:configuration];
    [[GPSLabEngine sharedEngine] persistConfiguration];
}

- (void)stopBehaviorChanged {
    GPSLabConfiguration *configuration = [[GPSLabEngine sharedEngine] configuration];
    configuration.stopBehavior = (GPSLabStopBehavior)self.stopBehaviorControl.selectedSegmentIndex;
    [[GPSLabEngine sharedEngine] applyConfiguration:configuration];
    [[GPSLabEngine sharedEngine] persistConfiguration];
}

- (void)setRouteStart {
    CLLocationCoordinate2D coordinate = [[GPSLabEngine sharedEngine] baseCoordinate];
    self.pendingRouteStartItem = [self mapItemForCoordinate:coordinate name:@"Start"];
    self.hasPendingStart = YES;
    [self updateRoutePins];
    [GPSLabStatusLog append:@"Route start set"];
}

- (void)setRouteEnd {
    CLLocationCoordinate2D coordinate = [[GPSLabEngine sharedEngine] baseCoordinate];
    self.pendingRouteEndItem = [self mapItemForCoordinate:coordinate name:@"End"];
    self.hasPendingEnd = YES;
    [self updateRoutePins];
    [GPSLabStatusLog append:@"Route end set"];
}

- (MKMapItem *)mapItemForCoordinate:(CLLocationCoordinate2D)coordinate name:(NSString *)name {
    MKPlacemark *placemark = [[MKPlacemark alloc] initWithCoordinate:coordinate];
    MKMapItem *item = [[MKMapItem alloc] initWithPlacemark:placemark];
    item.name = name;
    return item;
}

- (void)startRoute {
    if (!self.hasPendingStart || !self.hasPendingEnd) {
        [self showAlertWithTitle:@"Route incomplete" message:@"Set both a start and an end point first."];
        return;
    }

    GPSLabConfiguration *configuration = [[GPSLabEngine sharedEngine] configuration];
    double customSpeed = [self.customSpeedField.text doubleValue];
    if (customSpeed > 0.0) {
        configuration.routeCustomSpeedKmh = customSpeed;
    }

    CLLocationCoordinate2D startCoordinate = self.pendingRouteStartItem.placemark.coordinate;
    GPSLabOverlayViewController *__weak weakSelf = self;
    [[GPSLabEngine sharedEngine] startRouteFrom:startCoordinate
                                             to:self.pendingRouteEndItem.placemark.coordinate
                                           mode:(GPSLabRouteMode)self.routeModeControl.selectedSegmentIndex
                                 customSpeedKmh:configuration.routeCustomSpeedKmh
                                     completion:^(NSError *error) {
        GPSLabOverlayViewController *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        if (error != nil) {
            [strongSelf showAlertWithTitle:@"Route failed" message:error.localizedDescription];
        }
        [strongSelf updateRouteStatus];
    }];

    [[GPSLabStore sharedStore] addRecentCoordinate:startCoordinate altitude:0.0];
    [self reloadPersistedState];
    [self updateRouteStatus];
}

- (void)togglePauseRoute {
    GPSLabRouteSimulator *simulator = [[GPSLabEngine sharedEngine] routeSimulator];
    if ([simulator state] == GPSLabRouteStatePaused) {
        [[GPSLabEngine sharedEngine] resumeRoute];
    } else {
        [[GPSLabEngine sharedEngine] pauseRoute];
    }
    [self updateRouteStatus];
}

- (void)stopRoute {
    [[GPSLabEngine sharedEngine] stopRoute];
    [self clearRoutePins];
    [self.mapView removeOverlay:self.routeOverlay];
    self.routeOverlay = nil;
    [self updateRouteStatus];
    [self updateCoordinateLabel];
    [self updateMapFromState];
}

- (void)showRealLocationChanged {
    if (self.showRealLocationSwitch.on) {
        if (self.displayLocationManager == nil) {
            self.displayLocationManager = [[CLLocationManager alloc] init];
            // Bypass keeps this manager on real CoreLocation and out of the synthetic stream.
            [GPSLabCoreLocationHooks setBypassed:YES forManager:self.displayLocationManager];
            self.displayLocationManager.delegate = self;
        }
        [self.displayLocationManager requestWhenInUseAuthorization];
        [self.displayLocationManager startUpdatingLocation];
        [GPSLabStatusLog append:@"Displaying real location (not persisted)"];
    } else {
        [self stopRealLocationDisplay];
        [GPSLabStatusLog append:@"Real location display off"];
    }
}

- (void)addBookmark {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Add bookmark"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"Name";
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    GPSLabOverlayViewController *__weak weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action; // The save path reads the text field, not the action object.
        GPSLabOverlayViewController *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        NSString *name = alert.textFields.firstObject.text;
        if (name.length == 0) {
            name = @"Bookmark";
        }
        CLLocationCoordinate2D coordinate = [[GPSLabEngine sharedEngine] baseCoordinate];
        GPSLabConfiguration *configuration = [[GPSLabEngine sharedEngine] configuration];
        GPSLabBookmark *bookmark = [GPSLabBookmark bookmarkWithName:name
                                                          coordinate:coordinate
                                                             altitude:configuration.altitude];
        [[GPSLabStore sharedStore] addBookmark:bookmark];
        [strongSelf reloadPersistedState];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)clearRecents {
    [[GPSLabStore sharedStore] clearRecents];
    [self reloadPersistedState];
}

#pragma mark - Table view

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (tableView.tag == 1) {
        return (NSInteger)self.bookmarks.count;
    }
    return (NSInteger)self.recents.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"overlayCell"];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"overlayCell"];
    }

    if (tableView.tag == 1) {
        GPSLabBookmark *bookmark = self.bookmarks[(NSUInteger)indexPath.row];
        cell.textLabel.text = bookmark.name;
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%.4f, %.4f", bookmark.latitude, bookmark.longitude];
    } else {
        NSDictionary *recent = self.recents[(NSUInteger)indexPath.row];
        cell.textLabel.text = @"Recent";
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%.4f, %.4f",
                                     [recent[@"latitude"] doubleValue],
                                     [recent[@"longitude"] doubleValue]];
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    double latitude = 0.0;
    double longitude = 0.0;
    double altitude = 0.0;

    if (tableView.tag == 1) {
        if ((NSUInteger)indexPath.row >= self.bookmarks.count) {
            return;
        }
        GPSLabBookmark *bookmark = self.bookmarks[(NSUInteger)indexPath.row];
        latitude = bookmark.latitude;
        longitude = bookmark.longitude;
        altitude = bookmark.altitude;
    } else {
        if ((NSUInteger)indexPath.row >= self.recents.count) {
            return;
        }
        NSDictionary *recent = self.recents[(NSUInteger)indexPath.row];
        latitude = [recent[@"latitude"] doubleValue];
        longitude = [recent[@"longitude"] doubleValue];
        altitude = [recent[@"altitude"] doubleValue];
    }

    [self applyCoordinate:CLLocationCoordinate2DMake(latitude, longitude) altitude:altitude];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    GPSLabOverlayViewController *__weak weakSelf = self;
    UIContextualAction *delete = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                         title:@"Delete"
                                                                       handler:^(UIContextualAction *action,
                                                                                 UIView *sourceView,
                                                                                 void (^completionHandler)(BOOL)) {
        (void)action;     // Unused: the row index path identifies the target.
        (void)sourceView; // Unused: the action is not presented from a view.
        GPSLabOverlayViewController *strongSelf = weakSelf;
        if (strongSelf == nil) {
            completionHandler(NO);
            return;
        }
        if (tableView.tag == 1) {
            [[GPSLabStore sharedStore] deleteBookmarkAtIndex:(NSUInteger)indexPath.row];
        } else {
            [[GPSLabStore sharedStore] deleteRecentAtIndex:(NSUInteger)indexPath.row];
        }
        [strongSelf reloadPersistedState];
        completionHandler(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[delete]];
}

#pragma mark - Map

- (void)mapTapped:(UITapGestureRecognizer *)recognizer {
    CGPoint point = [recognizer locationInView:self.mapView];
    CLLocationCoordinate2D coordinate = [self.mapView convertPoint:point toCoordinateFromView:self.mapView];
    [self applyCoordinate:coordinate altitude:[[GPSLabEngine sharedEngine] configuration].altitude];
}

- (void)mapLongPressed:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateBegan) {
        return;
    }
    CGPoint point = [recognizer locationInView:self.mapView];
    CLLocationCoordinate2D coordinate = [self.mapView convertPoint:point toCoordinateFromView:self.mapView];
    [self applyCoordinate:coordinate altitude:[[GPSLabEngine sharedEngine] configuration].altitude];
}

- (void)annotationDragged:(UIPanGestureRecognizer *)recognizer {
    CGPoint point = [recognizer locationInView:self.mapView];
    CLLocationCoordinate2D coordinate = [self.mapView convertPoint:point toCoordinateFromView:self.mapView];
    self.syntheticAnnotation.coordinate = coordinate;

    if (recognizer.state == UIGestureRecognizerStateEnded ||
        recognizer.state == UIGestureRecognizerStateCancelled) {
        [self applyCoordinate:coordinate altitude:[[GPSLabEngine sharedEngine] configuration].altitude];
    }
}

- (MKAnnotationView *)mapView:(MKMapView *)mapView viewForAnnotation:(id<MKAnnotation>)annotation {
    if ([annotation isKindOfClass:[MKUserLocation class]]) {
        return nil;
    }
    static NSString *identifier = @"gpslabPin";
    static NSString *realIdentifier = @"gpslabRealPin";

    // The real-location annotation is display-only: distinct pin, never draggable.
    if (annotation == self.realLocationAnnotation) {
        MKMarkerAnnotationView *marker =
            (MKMarkerAnnotationView *)[mapView dequeueReusableAnnotationViewWithIdentifier:realIdentifier];
        if (marker == nil) {
            marker = [[MKMarkerAnnotationView alloc] initWithAnnotation:annotation
                                                        reuseIdentifier:realIdentifier];
            marker.draggable = NO;
            marker.canShowCallout = YES;
            marker.markerTintColor = UIColor.systemGreenColor;
        }
        marker.annotation = annotation;
        return marker;
    }

    MKAnnotationView *view = [mapView dequeueReusableAnnotationViewWithIdentifier:identifier];
    if (view == nil) {
        MKMarkerAnnotationView *marker = [[MKMarkerAnnotationView alloc] initWithAnnotation:annotation
                                                                             reuseIdentifier:identifier];
        marker.draggable = YES;
        marker.canShowCallout = YES;
        marker.markerTintColor = UIColor.systemBlueColor;
        view = marker;
    }
    view.annotation = annotation;

    if ([annotation isKindOfClass:[GPSLabSyntheticAnnotation class]] && view.gestureRecognizers.count == 0) {
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                             action:@selector(annotationDragged:)];
        [view addGestureRecognizer:pan];
    }
    return view;
}

- (MKOverlayRenderer *)mapView:(MKMapView *)mapView rendererForOverlay:(id<MKOverlay>)overlay {
    if ([overlay isKindOfClass:[MKPolyline class]]) {
        MKPolylineRenderer *renderer = [[MKPolylineRenderer alloc] initWithPolyline:(MKPolyline *)overlay];
        renderer.strokeColor = UIColor.systemBlueColor;
        renderer.lineWidth = 4.0;
        return renderer;
    }
    return nil;
}

- (void)applyMapItem:(MKMapItem *)item {
    if (item == nil) {
        return;
    }
    CLLocationCoordinate2D coordinate = item.placemark.coordinate;
    [self applyCoordinate:coordinate altitude:[[GPSLabEngine sharedEngine] configuration].altitude];
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)applyCoordinate:(CLLocationCoordinate2D)coordinate altitude:(double)altitude {
    if (!GPSLabIsValidCoordinate(coordinate.latitude, coordinate.longitude)) {
        return;
    }

    GPSLabConfiguration *configuration = [[GPSLabEngine sharedEngine] configuration];
    configuration.latitude = coordinate.latitude;
    configuration.longitude = coordinate.longitude;
    configuration.altitude = GPSLabClampDouble(altitude, -500.0, 100000.0);
    [[GPSLabEngine sharedEngine] applyConfiguration:configuration];
    [[GPSLabEngine sharedEngine] persistConfiguration];

    [[GPSLabStore sharedStore] addRecentCoordinate:coordinate altitude:configuration.altitude];

    self.latitudeField.text = [NSString stringWithFormat:@"%.6f", coordinate.latitude];
    self.longitudeField.text = [NSString stringWithFormat:@"%.6f", coordinate.longitude];
    [self reloadPersistedState];
    [self updateCoordinateLabel];
    [self updateMapFromState];
}

- (void)updateMapFromState {
    CLLocationCoordinate2D anchor = [[GPSLabEngine sharedEngine] baseCoordinate];
    self.syntheticAnnotation.coordinate = anchor;
    if (self.hasPendingStart) {
        self.routeStartPin.coordinate = self.pendingRouteStartItem.placemark.coordinate;
    }
    if (self.hasPendingEnd) {
        self.routeEndPin.coordinate = self.pendingRouteEndItem.placemark.coordinate;
    }
}

- (void)updateRoutePins {
    if (self.routeStartPin == nil) {
        self.routeStartPin = [[MKPointAnnotation alloc] init];
        self.routeStartPin.title = @"Start";
        [self.mapView addAnnotation:self.routeStartPin];
    }
    if (self.routeEndPin == nil) {
        self.routeEndPin = [[MKPointAnnotation alloc] init];
        self.routeEndPin.title = @"End";
        [self.mapView addAnnotation:self.routeEndPin];
    }
    [self updateMapFromState];
}

- (void)clearRoutePins {
    if (self.routeStartPin != nil) {
        [self.mapView removeAnnotation:self.routeStartPin];
        self.routeStartPin = nil;
    }
    if (self.routeEndPin != nil) {
        [self.mapView removeAnnotation:self.routeEndPin];
        self.routeEndPin = nil;
    }
    self.hasPendingStart = NO;
    self.hasPendingEnd = NO;
    self.pendingRouteStartItem = nil;
    self.pendingRouteEndItem = nil;
}

- (void)rebuildRoutePolylineIfPossible {
    if (self.routeOverlay != nil) {
        [self.mapView removeOverlay:self.routeOverlay];
        self.routeOverlay = nil;
    }
    // The route geometry is owned by the simulator; the overlay draws the traversed
    // segment (start -> current position) as a visual aid while a route is active.
    GPSLabRouteSimulator *simulator = [[GPSLabEngine sharedEngine] routeSimulator];
    CLLocationCoordinate2D start = CLLocationCoordinate2DMake(0.0, 0.0);
    CLLocationCoordinate2D current = start;
    double course = 0.0; // The polyline only needs positions; keep a real out-param.
    if ([simulator routeStartCoordinate:&start] &&
        [simulator currentCoordinate:&current course:&course]) {
        CLLocationCoordinate2D coordinates[2] = { start, current };
        self.routeOverlay = [MKPolyline polylineWithCoordinates:coordinates count:2];
        [self.mapView addOverlay:self.routeOverlay];
    }
}

#pragma mark - Real location display

// The display manager is BYPASSED in the hook layer, so it always talks to real
// CoreLocation and never receives synthetic fixes. Its coordinate is drawn on a
// dedicated annotation and is never persisted or logged. `MKMapView.showsUserLocation`
// is intentionally NOT used, because that uses an internal manager subject to the
// hooks.
- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations {
    if (!self.showRealLocationSwitch.on) {
        return;
    }
    CLLocation *location = locations.lastObject;
    if (location == nil) {
        return;
    }
    [self updateRealLocationAnnotationWithCoordinate:location.coordinate];
}

- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager {
    if (!self.showRealLocationSwitch.on) {
        return;
    }
    CLAuthorizationStatus status = manager.authorizationStatus;
    if (status == kCLAuthorizationStatusAuthorizedWhenInUse ||
        status == kCLAuthorizationStatusAuthorizedAlways) {
        [manager startUpdatingLocation];
    }
}

- (void)updateRealLocationAnnotationWithCoordinate:(CLLocationCoordinate2D)coordinate {
    if (self.realLocationAnnotation == nil) {
        self.realLocationAnnotation = [[MKPointAnnotation alloc] init];
        self.realLocationAnnotation.title = @"Real (not spoofed)";
        [self.mapView addAnnotation:self.realLocationAnnotation];
    }
    self.realLocationAnnotation.coordinate = coordinate;
}

- (void)stopRealLocationDisplay {
    if (self.displayLocationManager != nil) {
        [self.displayLocationManager stopUpdatingLocation];
        [GPSLabCoreLocationHooks setBypassed:NO forManager:self.displayLocationManager];
        self.displayLocationManager.delegate = nil;
        self.displayLocationManager = nil;
    }
    if (self.realLocationAnnotation != nil) {
        [self.mapView removeAnnotation:self.realLocationAnnotation];
        self.realLocationAnnotation = nil;
    }
}

#pragma mark - Periodic UI refresh

- (void)startTickTimer {
    if (self.tickTimer != nil) {
        return;
    }
    GPSLabOverlayViewController *__weak weakSelf = self;
    self.tickTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                     repeats:YES
                                                       block:^(NSTimer *timer) {
        (void)timer; // The tick only needs the current engine state.
        [weakSelf updateRouteStatus];
    }];
}

- (void)stopTickTimer {
    if (self.tickTimer != nil) {
        [self.tickTimer invalidate];
        self.tickTimer = nil;
    }
}

- (void)updateRouteStatus {
    GPSLabRouteSimulator *simulator = [[GPSLabEngine sharedEngine] routeSimulator];
    GPSLabRouteState state = [simulator state];

    self.routeProgress.progress = (float)[simulator progress];

    NSString *stateName = @"Idle";
    if ([simulator isLoading]) {
        stateName = @"Loading route";
    } else if (state == GPSLabRouteStatePlaying) {
        stateName = @"Playing";
    } else if (state == GPSLabRouteStatePaused) {
        stateName = @"Paused";
    }

    double distance = [simulator totalDistanceMeters];
    self.routeStatusLabel.text = [NSString stringWithFormat:@"%@  %.0f m  %.0f%%",
                                  stateName, distance, [simulator progress] * 100.0];

    if (state == GPSLabRouteStatePlaying) {
        [self rebuildRoutePolylineIfPossible];
    }
}

- (void)updateCoordinateLabel {
    GPSLabConfiguration *configuration = [[GPSLabEngine sharedEngine] configuration];
    self.coordinateLabel.text = [NSString stringWithFormat:@"Synth: %.6f, %.6f  alt %.1f m\nEnabled: %@",
                                 configuration.latitude,
                                 configuration.longitude,
                                 configuration.altitude,
                                 configuration.enabled ? @"YES" : @"NO"];
}

- (void)engineStateDidChange:(NSNotification *)notification {
    [self updateCoordinateLabel];
    [self updateMapFromState];
    [self updateRouteStatus];
}

#pragma mark - Helpers

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    // The overlay hosts UI in its own window; whichever controller is currently
    // visible on top presents the alert.
    UIViewController *presenter = self;
    while (presenter.presentedViewController != nil) {
        presenter = presenter.presentedViewController;
    }
    [presenter presentViewController:alert animated:YES completion:nil];
}

@end
