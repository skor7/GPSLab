//
//  GPSLabOverlayViewController.m
//  GPSLab
//
//  Map-first canvas. The MKMapView owns the remaining safe area (it is not inside a
//  scrolling panel); the header, floating controls and pick banner float above it.
//  All configuration lives in small, native sheets presented by this controller.
//
//  The synthetic engine, hook layer, drift model, route simulator and persistence
//  allow-list are unchanged; this controller only drives them.
//

#import "GPSLabOverlayViewController.h"

#import <CoreLocation/CoreLocation.h>
#import <MapKit/MapKit.h>

#import "CoreLocationHooks.h"
#import "GPSLabEngine.h"
#import "GPSLabFavoritesViewController.h"
#import "GPSLabFluctuationViewController.h"
#import "GPSLabGeodesy.h"
#import "GPSLabLicenseManager.h"
#import "GPSLabManualEntryViewController.h"
#import "GPSLabOptionsViewController.h"
#import "GPSLabOverlayPresenter.h"
#import "GPSLabRecentsViewController.h"
#import "GPSLabRouteViewController.h"
#import "GPSLabSearchResultsViewController.h"
#import "GPSLabSheetViewController.h"
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

#pragma mark - Pick mode

typedef NS_ENUM(NSInteger, GPSLabMapPickMode) {
    GPSLabMapPickModeNone = 0,
    GPSLabMapPickModeRouteStart,
    GPSLabMapPickModeRouteEnd,
};

#pragma mark - Overlay controller

@interface GPSLabOverlayViewController () <MKMapViewDelegate, CLLocationManagerDelegate,
                                            UISearchControllerDelegate, UISearchBarDelegate,
                                            UIGestureRecognizerDelegate>

@property (nonatomic, strong) MKMapView *mapView;

@property (nonatomic, strong) UIVisualEffectView *headerView;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UISwitch *enabledSwitch;
@property (nonatomic, strong) UIVisualEffectView *searchBarContainer;
@property (nonatomic, strong) UIStackView *controlsStack;

@property (nonatomic, strong) UIVisualEffectView *pickBanner;
@property (nonatomic, strong) UILabel *pickBannerLabel;

@property (nonatomic, strong) GPSLabSyntheticAnnotation *syntheticAnnotation;
@property (nonatomic, strong, nullable) MKPointAnnotation *routeStartPin;
@property (nonatomic, strong, nullable) MKPointAnnotation *routeEndPin;
@property (nonatomic, strong, nullable) MKPolyline *routeOverlay;

@property (nonatomic, strong, nullable) MKMapItem *pendingRouteStartItem;
@property (nonatomic, strong, nullable) MKMapItem *pendingRouteEndItem;

@property (nonatomic, assign) GPSLabMapPickMode pickMode;
@property (nonatomic, assign) BOOL reopenRouteAfterPick;

@property (nonatomic, assign) NSInteger mapStyle;
@property (nonatomic, assign) BOOL realLocationDisplayEnabled;
@property (nonatomic, strong, nullable) CLLocationManager *displayLocationManager;
@property (nonatomic, strong, nullable) MKPointAnnotation *realLocationAnnotation;

@property (nonatomic, strong, nullable) UISearchController *searchController;
@property (nonatomic, strong, nullable) GPSLabSearchResultsViewController *searchResultsController;

@property (nonatomic, strong, nullable) NSTimer *tickTimer;

@end

@implementation GPSLabOverlayViewController

#pragma mark - Lifecycle

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = UIColor.systemBackgroundColor;
    [self buildMap];
    [self buildHeader];
    [self buildSearchBar];
    [self buildControls];
    [self buildPickBanner];
    [self loadConfigurationIntoUI];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(engineStateDidChange:)
                                                 name:GPSLabEngineStateDidChangeNotification
                                               object:nil];
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

#pragma mark - Map construction

- (void)buildMap {
    MKMapView *mapView = [[MKMapView alloc] initWithFrame:CGRectZero];
    mapView.translatesAutoresizingMaskIntoConstraints = NO;
    mapView.delegate = self;
    mapView.showsUserLocation = NO;
    mapView.pointOfInterestFilter = [MKPointOfInterestFilter filterIncludingAllCategories];
    mapView.scrollEnabled = YES;
    mapView.zoomEnabled = YES;
    mapView.rotateEnabled = YES;
    mapView.pitchEnabled = YES;
    self.mapView = mapView;

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                          action:@selector(mapTapped:)];
    tap.delegate = self;
    [mapView addGestureRecognizer:tap];

    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self
                                                                                            action:@selector(mapLongPressed:)];
    longPress.delegate = self;
    [mapView addGestureRecognizer:longPress];

    self.syntheticAnnotation = [[GPSLabSyntheticAnnotation alloc] init];
    self.syntheticAnnotation.title = @"Synthetic";
    [mapView addAnnotation:self.syntheticAnnotation];

    // The map is a direct subview of the controller root and owns the remaining safe
    // area. It is deliberately NOT embedded in a scrolling content stack.
    [self.view addSubview:self.mapView];
    UILayoutGuide *safeArea = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.mapView.topAnchor constraintEqualToAnchor:safeArea.topAnchor],
        [self.mapView.leadingAnchor constraintEqualToAnchor:safeArea.leadingAnchor],
        [self.mapView.trailingAnchor constraintEqualToAnchor:safeArea.trailingAnchor],
        [self.mapView.bottomAnchor constraintEqualToAnchor:safeArea.bottomAnchor],
    ]];

    [self applyMapStyle:GPSLabMapStyleStandard];
}

#pragma mark - Header construction

- (void)buildHeader {
    UIVisualEffectView *header = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial]];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    header.layer.cornerRadius = 16.0;
    header.layer.masksToBounds = YES;
    [self.view addSubview:header];
    self.headerView = header;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectZero];
    title.text = @"GPSLab";
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle3];
    title.adjustsFontForContentSizeCategory = YES;
    [title setContentCompressionResistancePriority:UILayoutPriorityDefaultHigh forAxis:UILayoutConstraintAxisHorizontal];

    UILabel *enabledLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    enabledLabel.text = @"Enabled";
    enabledLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    enabledLabel.adjustsFontForContentSizeCategory = YES;

    self.enabledSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
    [self.enabledSwitch addTarget:self
                           action:@selector(enabledChanged)
                 forControlEvents:UIControlEventValueChanged];

    UIButton *settingsButton = [self headerButtonWithSymbol:@"gearshape" action:@selector(settingsTapped)];
    UIButton *closeButton = [self headerButtonWithSymbol:@"xmark" action:@selector(closeTapped)];

    UIStackView *topRow = [[UIStackView alloc] initWithArrangedSubviews:@[
        title, [UIView new], enabledLabel, self.enabledSwitch, settingsButton, closeButton,
    ]];
    topRow.axis = UILayoutConstraintAxisHorizontal;
    topRow.alignment = UIStackViewAlignmentCenter;
    topRow.spacing = 8.0;

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    self.statusLabel.adjustsFontForContentSizeCategory = YES;
    self.statusLabel.textColor = UIColor.secondaryLabelColor;
    self.statusLabel.numberOfLines = 2;

    UIStackView *column = [[UIStackView alloc] initWithArrangedSubviews:@[topRow, self.statusLabel]];
    column.axis = UILayoutConstraintAxisVertical;
    column.spacing = 6.0;
    column.translatesAutoresizingMaskIntoConstraints = NO;
    [header.contentView addSubview:column];

    UILayoutGuide *safeArea = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [header.topAnchor constraintEqualToAnchor:safeArea.topAnchor constant:12.0],
        [header.leadingAnchor constraintEqualToAnchor:safeArea.leadingAnchor constant:12.0],
        [header.trailingAnchor constraintEqualToAnchor:safeArea.trailingAnchor constant:-12.0],

        [column.topAnchor constraintEqualToAnchor:header.contentView.topAnchor constant:12.0],
        [column.leadingAnchor constraintEqualToAnchor:header.contentView.leadingAnchor constant:14.0],
        [column.trailingAnchor constraintEqualToAnchor:header.contentView.trailingAnchor constant:-14.0],
        [column.bottomAnchor constraintEqualToAnchor:header.contentView.bottomAnchor constant:-12.0],
    ]];
}

- (UIButton *)headerButtonWithSymbol:(NSString *)symbol action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:16.0 weight:UIImageSymbolWeightSemibold];
    [button setImage:[UIImage systemImageNamed:symbol withConfiguration:configuration]
            forState:UIControlStateNormal];
    button.tintColor = UIColor.labelColor;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [button.widthAnchor constraintEqualToConstant:34.0].active = YES;
    [button.heightAnchor constraintEqualToConstant:34.0].active = YES;
    return button;
}

#pragma mark - Visible search bar

// A real, always-visible UISearchBar (the UISearchController's own bar) rather than a
// magnifier button, wired to MKLocalSearch through the results controller.
- (void)buildSearchBar {
    GPSLabSearchResultsViewController *results = [[GPSLabSearchResultsViewController alloc] init];
    GPSLabOverlayViewController *__weak weakSelf = self;
    results.selectionHandler = ^(MKMapItem *item) {
        [weakSelf applyMapItem:item];
    };
    self.searchResultsController = results;

    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:results];
    search.searchResultsUpdater = results;
    search.delegate = self;
    search.obscuresBackgroundDuringPresentation = NO;
    search.hidesNavigationBarDuringPresentation = NO;
    search.searchBar.delegate = self;
    search.searchBar.placeholder = @"Search address or place";
    search.searchBar.searchBarStyle = UISearchBarStyleMinimal;
    self.searchController = search;

    UIVisualEffectView *container = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial]];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    container.layer.cornerRadius = 14.0;
    container.layer.masksToBounds = YES;
    [self.view addSubview:container];
    self.searchBarContainer = container;

    UISearchBar *bar = search.searchBar;
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    [container.contentView addSubview:bar];

    UILayoutGuide *safeArea = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [container.topAnchor constraintEqualToAnchor:self.headerView.bottomAnchor constant:8.0],
        [container.leadingAnchor constraintEqualToAnchor:safeArea.leadingAnchor constant:12.0],
        [container.trailingAnchor constraintEqualToAnchor:safeArea.trailingAnchor constant:-12.0],

        [bar.topAnchor constraintEqualToAnchor:container.contentView.topAnchor constant:4.0],
        [bar.leadingAnchor constraintEqualToAnchor:container.contentView.leadingAnchor constant:6.0],
        [bar.trailingAnchor constraintEqualToAnchor:container.contentView.trailingAnchor constant:-6.0],
        [bar.bottomAnchor constraintEqualToAnchor:container.contentView.bottomAnchor constant:-4.0],
    ]];
}

#pragma mark - Floating controls

- (void)buildControls {
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self circularButtonWithSymbol:@"location.fill" action:@selector(centerTapped)],
        [self circularButtonWithSymbol:@"star" action:@selector(favoritesTapped)],
        [self circularButtonWithSymbol:@"arrow.triangle.turn.up.right.diamond.fill" action:@selector(routeTapped)],
        [self circularButtonWithSymbol:@"slider.horizontal.3" action:@selector(settingsTapped)],
    ]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12.0;
    [self.view addSubview:stack];
    self.controlsStack = stack;

    UILayoutGuide *safeArea = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [stack.trailingAnchor constraintEqualToAnchor:safeArea.trailingAnchor constant:-16.0],
        [stack.centerYAnchor constraintEqualToAnchor:safeArea.centerYAnchor],
    ]];
}

- (UIButton *)circularButtonWithSymbol:(NSString *)symbol action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:18.0 weight:UIImageSymbolWeightSemibold];
    [button setImage:[UIImage systemImageNamed:symbol withConfiguration:configuration]
            forState:UIControlStateNormal];
    button.tintColor = UIColor.labelColor;
    button.backgroundColor = UIColor.secondarySystemBackgroundColor;
    button.layer.cornerRadius = 24.0;
    button.layer.masksToBounds = YES;
    button.layer.borderWidth = 0.5;
    button.layer.borderColor = UIColor.separatorColor.CGColor;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [button.widthAnchor constraintEqualToConstant:48.0].active = YES;
    [button.heightAnchor constraintEqualToConstant:48.0].active = YES;
    return button;
}

#pragma mark - Pick banner

- (void)buildPickBanner {
    UIVisualEffectView *banner = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial]];
    banner.translatesAutoresizingMaskIntoConstraints = NO;
    banner.layer.cornerRadius = 14.0;
    banner.layer.masksToBounds = YES;
    banner.hidden = YES;
    [self.view addSubview:banner];
    self.pickBanner = banner;

    self.pickBannerLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.pickBannerLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    self.pickBannerLabel.adjustsFontForContentSizeCategory = YES;
    self.pickBannerLabel.numberOfLines = 0;

    UIButton *cancel = [UIButton buttonWithType:UIButtonTypeSystem];
    [cancel setTitle:@"Cancel" forState:UIControlStateNormal];
    cancel.titleLabel.adjustsFontForContentSizeCategory = YES;
    [cancel addTarget:self action:@selector(cancelPicking) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[self.pickBannerLabel, cancel]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 12.0;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [banner.contentView addSubview:row];

    [NSLayoutConstraint activateConstraints:@[
        [banner.topAnchor constraintEqualToAnchor:self.searchBarContainer.bottomAnchor constant:8.0],
        [banner.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [banner.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor
                                                          constant:12.0],
        [banner.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor
                                                         constant:-12.0],
        [row.topAnchor constraintEqualToAnchor:banner.contentView.topAnchor constant:10.0],
        [row.leadingAnchor constraintEqualToAnchor:banner.contentView.leadingAnchor constant:14.0],
        [row.trailingAnchor constraintEqualToAnchor:banner.contentView.trailingAnchor constant:-14.0],
        [row.bottomAnchor constraintEqualToAnchor:banner.contentView.bottomAnchor constant:-10.0],
    ]];
}

- (void)updatePickBanner {
    if (self.pickMode == GPSLabMapPickModeNone) {
        self.pickBanner.hidden = YES;
        return;
    }
    self.pickBannerLabel.text = (self.pickMode == GPSLabMapPickModeRouteStart)
        ? @"Tap the map to set the route start"
        : @"Tap the map to set the route end";
    self.pickBanner.hidden = NO;
}

- (void)beginPickingRouteStart {
    self.pickMode = GPSLabMapPickModeRouteStart;
    [self updatePickBanner];
}

- (void)beginPickingRouteEnd {
    self.pickMode = GPSLabMapPickModeRouteEnd;
    [self updatePickBanner];
}

- (void)endPickMode {
    self.pickMode = GPSLabMapPickModeNone;
    [self updatePickBanner];
}

- (void)cancelPicking {
    self.reopenRouteAfterPick = NO;
    [self endPickMode];
}

#pragma mark - Configuration into UI

- (void)loadConfigurationIntoUI {
    GPSLabConfiguration *configuration = [[GPSLabEngine sharedEngine] configuration];
    self.enabledSwitch.on = configuration.enabled;
    self.mapStyle = GPSLabMapStyleStandard;
    [self applyMapStyle:self.mapStyle];
    [self updateStatusLabel];
    [self updateMapFromState];
}

- (void)applyMapStyle:(NSInteger)style {
    self.mapStyle = style;
    if (@available(iOS 16.0, *)) {
        switch (style) {
            case GPSLabMapStyleHybrid:
                self.mapView.preferredConfiguration = [[MKHybridMapConfiguration alloc] init];
                break;
            case GPSLabMapStyleSatellite:
                self.mapView.preferredConfiguration = [[MKImageryMapConfiguration alloc] init];
                break;
            case GPSLabMapStyleStandard:
            default: {
                MKStandardMapConfiguration *standard = [[MKStandardMapConfiguration alloc] init];
                standard.emphasisStyle = MKStandardMapEmphasisStyleDefault;
                standard.pointOfInterestFilter = [MKPointOfInterestFilter filterIncludingAllCategories];
                self.mapView.preferredConfiguration = standard;
                break;
            }
        }
    }
}

#pragma mark - Actions

- (void)closeTapped {
    [[GPSLabOverlayPresenter sharedPresenter] dismissOverlay];
}

- (void)settingsTapped {
    [self presentOptionsSheet];
}

- (void)enabledChanged {
    [[GPSLabEngine sharedEngine] setEnabledAndNotify:self.enabledSwitch.on];
    [GPSLabStatusLog append:(self.enabledSwitch.on ? @"Engine enabled" : @"Engine disabled")];
    [self updateStatusLabel];
}

- (void)centerTapped {
    CLLocationCoordinate2D coordinate = [[GPSLabEngine sharedEngine] baseCoordinate];
    [self.mapView setRegion:MKCoordinateRegionMakeWithDistance(coordinate, 800.0, 800.0) animated:YES];
}

- (void)favoritesTapped {
    [self presentFavoritesSheet];
}

- (void)routeTapped {
    [self presentRouteSheet];
}

#pragma mark - Search

- (BOOL)searchBarShouldBeginEditing:(UISearchBar *)searchBar {
    (void)searchBar;
    [self.searchController setActive:YES];
    return YES;
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)searchBar {
    (void)searchBar;
    [self.searchResultsController cancelActiveSearch];
    [self.searchController setActive:NO];
}

- (void)didDismissSearchController:(UISearchController *)searchController {
    // A dismissed search must not keep an in-flight request alive or let a late
    // response repopulate the (now hidden) results table.
    (void)searchController;
    [self.searchResultsController cancelActiveSearch];
}

- (void)applyMapItem:(MKMapItem *)item {
    if (item == nil) {
        return;
    }
    [self applyCoordinate:item.placemark.coordinate altitude:[[GPSLabEngine sharedEngine] configuration].altitude];
    [self.searchController setActive:NO];
}

#pragma mark - Sheet presentation

- (void)presentManualEntrySheet {
    GPSLabConfiguration *configuration = [[GPSLabEngine sharedEngine] configuration];
    GPSLabManualEntryViewController *manual = [[GPSLabManualEntryViewController alloc] init];
    manual.initialLatitude = configuration.latitude;
    manual.initialLongitude = configuration.longitude;
    manual.initialAltitude = configuration.altitude;
    manual.initialHeading = configuration.heading;

    GPSLabOverlayViewController *__weak weakSelf = self;
    manual.applyHandler = ^(CLLocationCoordinate2D coordinate, double altitude, double heading) {
        [weakSelf applyCoordinate:coordinate altitude:altitude heading:heading];
    };
    [self presentViewController:GPSLabSheetNavigationController(manual) animated:YES completion:nil];
}

- (void)presentFavoritesSheet {
    GPSLabFavoritesViewController *favorites = [[GPSLabFavoritesViewController alloc] init];
    GPSLabOverlayViewController *__weak weakSelf = self;
    favorites.selectHandler = ^(GPSLabBookmark *bookmark) {
        [weakSelf applyCoordinate:CLLocationCoordinate2DMake(bookmark.latitude, bookmark.longitude)
                         altitude:bookmark.altitude];
    };
    [self presentViewController:GPSLabSheetNavigationController(favorites) animated:YES completion:nil];
}

- (void)presentRecentsSheet {
    GPSLabRecentsViewController *recents = [[GPSLabRecentsViewController alloc] init];
    GPSLabOverlayViewController *__weak weakSelf = self;
    recents.selectHandler = ^(CLLocationCoordinate2D coordinate, double altitude) {
        [weakSelf applyCoordinate:coordinate altitude:altitude];
    };
    [self presentViewController:GPSLabSheetNavigationController(recents) animated:YES completion:nil];
}

- (void)presentFluctuationSheet {
    GPSLabFluctuationViewController *sheet = [[GPSLabFluctuationViewController alloc] init];
    sheet.fluctuationEnabled = [[GPSLabEngine sharedEngine] isDriftEnabled];
    sheet.radiusMeters = [[GPSLabEngine sharedEngine] driftRadiusMeters];

    GPSLabOverlayViewController *__weak weakSelf = self;
    sheet.changeHandler = ^(BOOL enabled, double radiusMeters) {
        [[GPSLabEngine sharedEngine] setDriftEnabled:enabled];
        [[GPSLabEngine sharedEngine] setDriftRadiusMeters:radiusMeters];
        [weakSelf updateStatusLabel];
    };
    [self presentViewController:GPSLabSheetNavigationController(sheet) animated:YES completion:nil];
}

- (void)presentRouteSheet {
    GPSLabRouteViewController *route = [[GPSLabRouteViewController alloc] init];
    route.startItem = self.pendingRouteStartItem;
    route.endItem = self.pendingRouteEndItem;

    GPSLabOverlayViewController *__weak weakSelf = self;
    route.pickStartHandler = ^{
        [weakSelf dismissViewControllerAnimated:YES completion:^{
            weakSelf.reopenRouteAfterPick = YES;
            [weakSelf beginPickingRouteStart];
        }];
    };
    route.pickEndHandler = ^{
        [weakSelf dismissViewControllerAnimated:YES completion:^{
            weakSelf.reopenRouteAfterPick = YES;
            [weakSelf beginPickingRouteEnd];
        }];
    };
    route.routeChangedHandler = ^{
        [weakSelf updateRouteAnnotations];
        [weakSelf updateStatusLabel];
    };
    [self presentViewController:GPSLabSheetNavigationController(route) animated:YES completion:nil];
}

- (void)presentOptionsSheet {
    GPSLabConfiguration *configuration = [[GPSLabEngine sharedEngine] configuration];
    GPSLabOptionsViewController *options = [[GPSLabOptionsViewController alloc] init];
    options.keepLastCoordinate = configuration.keepLastCoordinate;
    options.realLocationEnabled = self.realLocationDisplayEnabled;
    options.mapStyle = self.mapStyle;
    // Active is silent; surface only a meaningful subscription status in settings.
    options.subscriptionStatusText = ([[GPSLabLicenseManager sharedManager] state] == GPSLabEntitlementStateGrace)
        ? @"Subscription active (grace period). Renew soon to avoid interruption."
        : nil;

    GPSLabOverlayViewController *__weak weakSelf = self;
    options.keepLastHandler = ^(BOOL keepLast) {
        [[GPSLabEngine sharedEngine] setKeepLastCoordinate:keepLast];
        [weakSelf updateStatusLabel];
    };
    options.realLocationHandler = ^(BOOL enabled) {
        [weakSelf setRealLocationDisplayEnabled:enabled];
    };
    options.mapStyleHandler = ^(NSInteger style) {
        [weakSelf applyMapStyle:style];
    };
    options.manualEntryHandler = ^{
        [weakSelf dismissViewControllerAnimated:YES completion:^{
            [weakSelf presentManualEntrySheet];
        }];
    };
    options.recentsHandler = ^{
        [weakSelf dismissViewControllerAnimated:YES completion:^{
            [weakSelf presentRecentsSheet];
        }];
    };
    options.fluctuationHandler = ^{
        [weakSelf dismissViewControllerAnimated:YES completion:^{
            [weakSelf presentFluctuationSheet];
        }];
    };
    [self presentViewController:GPSLabSheetNavigationController(options) animated:YES completion:nil];
}

#pragma mark - Coordinate application

- (void)applyCoordinate:(CLLocationCoordinate2D)coordinate altitude:(double)altitude {
    GPSLabConfiguration *configuration = [[GPSLabEngine sharedEngine] configuration];
    [self applyCoordinate:coordinate altitude:altitude heading:configuration.heading];
}

- (void)applyCoordinate:(CLLocationCoordinate2D)coordinate altitude:(double)altitude heading:(double)heading {
    if (!GPSLabIsValidCoordinate(coordinate.latitude, coordinate.longitude)) {
        return;
    }

    GPSLabConfiguration *configuration = [[GPSLabEngine sharedEngine] configuration];
    configuration.latitude = coordinate.latitude;
    configuration.longitude = coordinate.longitude;
    configuration.altitude = GPSLabClampDouble(altitude, -500.0, 100000.0);
    configuration.heading = GPSLabNormalizeHeading(heading);
    [[GPSLabEngine sharedEngine] applyConfiguration:configuration];
    [[GPSLabEngine sharedEngine] persistConfiguration];

    [[GPSLabStore sharedStore] addRecentCoordinate:coordinate altitude:configuration.altitude];

    [self updateStatusLabel];
    [self updateMapFromState];
}

- (void)updateMapFromState {
    CLLocationCoordinate2D anchor = [[GPSLabEngine sharedEngine] baseCoordinate];
    self.syntheticAnnotation.coordinate = anchor;
}

#pragma mark - Map gestures

- (void)mapTapped:(UITapGestureRecognizer *)recognizer {
    CGPoint point = [recognizer locationInView:self.mapView];
    CLLocationCoordinate2D coordinate = [self.mapView convertPoint:point toCoordinateFromView:self.mapView];

    if (self.pickMode != GPSLabMapPickModeNone) {
        [self handlePickAtCoordinate:coordinate];
        return;
    }
    [self applyCoordinate:coordinate altitude:[[GPSLabEngine sharedEngine] configuration].altitude];
}

- (void)mapLongPressed:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateBegan) {
        return;
    }
    CGPoint point = [recognizer locationInView:self.mapView];
    CLLocationCoordinate2D coordinate = [self.mapView convertPoint:point toCoordinateFromView:self.mapView];
    if (self.pickMode != GPSLabMapPickModeNone) {
        [self handlePickAtCoordinate:coordinate];
        return;
    }
    [self applyCoordinate:coordinate altitude:[[GPSLabEngine sharedEngine] configuration].altitude];
}

- (void)handlePickAtCoordinate:(CLLocationCoordinate2D)coordinate {
    BOOL pickingStart = (self.pickMode == GPSLabMapPickModeRouteStart);
    MKMapItem *item = [self mapItemForCoordinate:coordinate name:(pickingStart ? @"Start" : @"End")];
    if (pickingStart) {
        self.pendingRouteStartItem = item;
    } else {
        self.pendingRouteEndItem = item;
    }
    [self updateRouteAnnotations];

    BOOL reopen = self.reopenRouteAfterPick;
    self.reopenRouteAfterPick = NO;
    [self endPickMode];

    if (reopen) {
        [self presentRouteSheet];
    }
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

#pragma mark - UIGestureRecognizerDelegate

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
        shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    // Our tap/long-press must never block MapKit pan, zoom, rotate or pitch.
    return YES;
}

#pragma mark - Route annotations and polyline

- (MKMapItem *)mapItemForCoordinate:(CLLocationCoordinate2D)coordinate name:(NSString *)name {
    MKPlacemark *placemark = [[MKPlacemark alloc] initWithCoordinate:coordinate];
    MKMapItem *item = [[MKMapItem alloc] initWithPlacemark:placemark];
    item.name = name;
    return item;
}

- (void)updateRouteAnnotations {
    if (self.pendingRouteStartItem != nil) {
        if (self.routeStartPin == nil) {
            self.routeStartPin = [[MKPointAnnotation alloc] init];
            self.routeStartPin.title = @"Start";
            [self.mapView addAnnotation:self.routeStartPin];
        }
        self.routeStartPin.coordinate = self.pendingRouteStartItem.placemark.coordinate;
    }
    if (self.pendingRouteEndItem != nil) {
        if (self.routeEndPin == nil) {
            self.routeEndPin = [[MKPointAnnotation alloc] init];
            self.routeEndPin.title = @"End";
            [self.mapView addAnnotation:self.routeEndPin];
        }
        self.routeEndPin.coordinate = self.pendingRouteEndItem.placemark.coordinate;
    }
    [self rebuildRoutePolylineIfPossible];
}

- (void)rebuildRoutePolylineIfPossible {
    if (self.routeOverlay != nil) {
        [self.mapView removeOverlay:self.routeOverlay];
        self.routeOverlay = nil;
    }
    // The route geometry is owned by the simulator; the canvas draws the traversed
    // segment (start -> current position) as a visual aid while a route is active.
    GPSLabRouteSimulator *simulator = [[GPSLabEngine sharedEngine] routeSimulator];
    CLLocationCoordinate2D start = CLLocationCoordinate2DMake(0.0, 0.0);
    CLLocationCoordinate2D current = start;
    double course = 0.0; // Positions only; a real out-param keeps the nullability contract.
    if ([simulator routeStartCoordinate:&start] &&
        [simulator currentCoordinate:&current course:&course]) {
        CLLocationCoordinate2D coordinates[2] = { start, current };
        self.routeOverlay = [MKPolyline polylineWithCoordinates:coordinates count:2];
        [self.mapView addOverlay:self.routeOverlay];
    }
}

#pragma mark - MKMapViewDelegate

- (MKAnnotationView *)mapView:(MKMapView *)mapView viewForAnnotation:(id<MKAnnotation>)annotation {
    if ([annotation isKindOfClass:[MKUserLocation class]]) {
        return nil;
    }

    // The real-location annotation is display-only: distinct pin, never draggable.
    if (annotation == self.realLocationAnnotation) {
        static NSString *realIdentifier = @"gpslabRealPin";
        MKMarkerAnnotationView *marker =
            (MKMarkerAnnotationView *)[mapView dequeueReusableAnnotationViewWithIdentifier:realIdentifier];
        if (marker == nil) {
            marker = [[MKMarkerAnnotationView alloc] initWithAnnotation:annotation
                                                        reuseIdentifier:realIdentifier];
            marker.draggable = NO;
            marker.canShowCallout = YES;
            marker.markerTintColor = UIColor.systemGreenColor;
            marker.glyphImage = [UIImage systemImageNamed:@"location.fill"];
        }
        marker.annotation = annotation;
        return marker;
    }

    if (annotation == self.routeStartPin || annotation == self.routeEndPin) {
        BOOL isStart = (annotation == self.routeStartPin);
        static NSString *startIdentifier = @"gpslabRouteStartPin";
        static NSString *endIdentifier = @"gpslabRouteEndPin";
        NSString *identifier = isStart ? startIdentifier : endIdentifier;
        MKMarkerAnnotationView *marker =
            (MKMarkerAnnotationView *)[mapView dequeueReusableAnnotationViewWithIdentifier:identifier];
        if (marker == nil) {
            marker = [[MKMarkerAnnotationView alloc] initWithAnnotation:annotation
                                                        reuseIdentifier:identifier];
            marker.draggable = NO;
            marker.canShowCallout = YES;
            marker.markerTintColor = isStart ? UIColor.systemOrangeColor : UIColor.systemRedColor;
            marker.glyphImage = [UIImage systemImageNamed:@"flag.fill"];
        }
        marker.annotation = annotation;
        return marker;
    }

    static NSString *identifier = @"gpslabPin";
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

#pragma mark - Real location display

// The display manager is BYPASSED in the hook layer, so it always talks to real
// CoreLocation and never receives synthetic fixes. Its coordinate is drawn on a
// dedicated annotation and is never persisted or logged. `MKMapView.showsUserLocation`
// is intentionally NOT used, because that uses an internal manager subject to the hooks.
- (void)setRealLocationDisplayEnabled:(BOOL)enabled {
    _realLocationDisplayEnabled = enabled;
    if (enabled) {
        if (self.displayLocationManager == nil) {
            self.displayLocationManager = [[CLLocationManager alloc] init];
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

- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations {
    if (!self.realLocationDisplayEnabled) {
        return;
    }
    CLLocation *location = locations.lastObject;
    if (location == nil) {
        return;
    }
    [self updateRealLocationAnnotationWithCoordinate:location.coordinate];
}

- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager {
    if (!self.realLocationDisplayEnabled) {
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
    _realLocationDisplayEnabled = NO;
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

#pragma mark - Periodic refresh

- (void)startTickTimer {
    if (self.tickTimer != nil) {
        return;
    }
    GPSLabOverlayViewController *__weak weakSelf = self;
    self.tickTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                     repeats:YES
                                                       block:^(NSTimer *timer) {
        (void)timer;
        [weakSelf rebuildRoutePolylineIfPossible];
        [weakSelf updateStatusLabel];
    }];
}

- (void)stopTickTimer {
    if (self.tickTimer != nil) {
        [self.tickTimer invalidate];
        self.tickTimer = nil;
    }
}

#pragma mark - Status

- (void)updateStatusLabel {
    GPSLabConfiguration *configuration = [[GPSLabEngine sharedEngine] configuration];
    NSString *state = configuration.enabled ? @"Enabled" : @"Disabled";
    self.statusLabel.text = [NSString stringWithFormat:@"%@ | %.5f, %.5f | %.0f m",
                             state,
                             configuration.latitude,
                             configuration.longitude,
                             configuration.altitude];
}

- (void)engineStateDidChange:(NSNotification *)notification {
    self.enabledSwitch.on = [[GPSLabEngine sharedEngine] isEnabled];
    [self updateStatusLabel];
    [self updateMapFromState];
}

@end
