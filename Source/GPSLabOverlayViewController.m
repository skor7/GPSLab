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
#import "GPSLabLocalization.h"
#import "GPSLabManualEntryViewController.h"
#import "GPSLabModalCoordinator.h"
#import "GPSLabOptionsViewController.h"
#import "GPSLabOverlayPresenter.h"
#import "GPSLabRecentsViewController.h"
#import "GPSLabRouteViewController.h"
#import "GPSLabSearchLayoutCore.h"
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
                                            UISearchBarDelegate, UIGestureRecognizerDelegate> {
    // Pure C search-session lifecycle (see GPSLabSearchLayoutCore.h).
    GPSLabSearchSession _searchSession;
}

@property (nonatomic, strong) MKMapView *mapView;

@property (nonatomic, strong) UIVisualEffectView *headerView;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *enabledLabel;
@property (nonatomic, strong) UISwitch *enabledSwitch;
@property (nonatomic, strong) UIButton *headerSettingsButton;
@property (nonatomic, strong) UIButton *headerCloseButton;
@property (nonatomic, strong) NSArray<UIButton *> *controlButtons;
@property (nonatomic, strong) UIVisualEffectView *searchBarContainer;
@property (nonatomic, strong) UIStackView *controlsStack;
@property (nonatomic, strong, nullable) UITapGestureRecognizer *outsideTapRecognizer;

@property (nonatomic, strong) UIVisualEffectView *pickBanner;
@property (nonatomic, strong) UILabel *pickBannerLabel;
@property (nonatomic, strong) UIButton *pickCancelButton;

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

@property (nonatomic, strong, nullable) UISearchBar *searchBar;
@property (nonatomic, strong, nullable) GPSLabSearchResultsViewController *searchResultsController;
@property (nonatomic, strong, nullable) NSLayoutConstraint *resultHeightConstraint;

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
    [self installOutsideTapRecognizer];
    [self loadConfigurationIntoUI];
    [self applyLocalization];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(engineStateDidChange:)
                                                 name:GPSLabEngineStateDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(languageDidChange:)
                                                 name:GPSLabLanguageDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillChangeFrame:)
                                                 name:UIKeyboardWillChangeFrameNotification
                                               object:nil];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // Keep the bounded results panel sized to the measured available area. The
    // update only writes the constraint when the value actually changed, so the
    // layout pass converges after a single extra pass.
    [self updateSearchResultsLayout];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self applyLocalization];
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
    self.syntheticAnnotation.title = GPSLabLocalized(@"overlay.annotation.synthetic");
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
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle3];
    title.adjustsFontForContentSizeCategory = YES;
    [title setContentCompressionResistancePriority:UILayoutPriorityDefaultHigh forAxis:UILayoutConstraintAxisHorizontal];
    self.titleLabel = title;

    UILabel *enabledLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    enabledLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    enabledLabel.adjustsFontForContentSizeCategory = YES;
    self.enabledLabel = enabledLabel;

    self.enabledSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
    self.enabledSwitch.accessibilityLabel = GPSLabLocalized(@"overlay.enabled");
    [self.enabledSwitch addTarget:self
                           action:@selector(enabledChanged)
                 forControlEvents:UIControlEventValueChanged];

    UIButton *settingsButton = [self headerButtonWithSymbol:@"gearshape" action:@selector(settingsTapped)];
    UIButton *closeButton = [self headerButtonWithSymbol:@"xmark" action:@selector(closeTapped)];
    self.headerSettingsButton = settingsButton;
    self.headerCloseButton = closeButton;

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

// A standalone UISearchBar permanently owned by the fixed GPSLab container.
// There is deliberately no controller-owned bar here: a hosted search
// controller reparents its bar into its own presentation container on
// activation (the overlay window has no navigation bar to host it), which
// clipped the fixed field and produced a full-window blank panel. The bar below
// is never reparented; the results controller is mounted once as a GPSLab
// child.
- (void)buildSearchBar {
    GPSLabSearchResultsViewController *results = [[GPSLabSearchResultsViewController alloc] init];
    GPSLabOverlayViewController *__weak weakSelf = self;
    results.selectionHandler = ^(MKMapItem *item) {
        [weakSelf applyMapItem:item];
    };
    results.doneHandler = ^{
        [weakSelf endActiveSearch];
    };
    results.contentChangeHandler = ^{
        [weakSelf updateSearchResultsLayout];
    };
    self.searchResultsController = results;

    UIVisualEffectView *container = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial]];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    container.layer.cornerRadius = 14.0;
    container.layer.masksToBounds = YES;
    [self.view addSubview:container];
    self.searchBarContainer = container;

    UISearchBar *bar = [[UISearchBar alloc] initWithFrame:CGRectZero];
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    bar.delegate = self;
    bar.searchBarStyle = UISearchBarStyleMinimal;
    // Native system colors keep typed text, placeholder and the insertion point
    // legible in both light and dark appearance. Writing direction is left to
    // the GPSLab scope (Arabic RTL / English LTR) so the bar inherits it rather
    // than forcing a direction of its own.
    if (@available(iOS 13.0, *)) {
        bar.searchTextField.textColor = UIColor.labelColor;
        bar.searchTextField.tintColor = self.view.tintColor;
    }
    self.searchBar = bar;
    [container.contentView addSubview:bar];

    // FIXED bar height. A required equality is what stops the results panel's
    // keyboard constraint from stretching the low-hugging bar/container (the
    // v3 giant blank panel). The height is measured once from the native bar's
    // intrinsic size and is identical in every phase (inactive/active/Cancel).
    CGFloat intrinsicHeight = bar.intrinsicContentSize.height;
    if (!(intrinsicHeight > 0.0)) {
        intrinsicHeight = 56.0; // pre-layout fallback; never shrinks the bar
    }
    CGFloat barHeight = GPSLabSearchBarHeight(intrinsicHeight, 44.0);

    UILayoutGuide *safeArea = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [container.topAnchor constraintEqualToAnchor:self.headerView.bottomAnchor constant:8.0],
        [container.leadingAnchor constraintEqualToAnchor:safeArea.leadingAnchor constant:12.0],
        [container.trailingAnchor constraintEqualToAnchor:safeArea.trailingAnchor constant:-12.0],

        [bar.topAnchor constraintEqualToAnchor:container.contentView.topAnchor constant:4.0],
        [bar.leadingAnchor constraintEqualToAnchor:container.contentView.leadingAnchor constant:6.0],
        [bar.trailingAnchor constraintEqualToAnchor:container.contentView.trailingAnchor constant:-6.0],
        [bar.bottomAnchor constraintEqualToAnchor:container.contentView.bottomAnchor constant:-4.0],
        [bar.heightAnchor constraintEqualToConstant:barHeight],
    ]];

    [self mountSearchResultsChild];
}

// Mounts the results controller ONCE as a GPSLab-owned child (never presented by
// UIKit for search). Its panel sits below the fixed search container, bounded to
// the available area above the keyboard layout guide, so the map stays visible.
- (void)mountSearchResultsChild {
    GPSLabSearchResultsViewController *results = self.searchResultsController;
    if (results == nil) {
        return;
    }
    [self addChildViewController:results];
    UIView *resultsView = results.view;
    resultsView.translatesAutoresizingMaskIntoConstraints = NO;
    resultsView.layer.cornerRadius = 14.0;
    resultsView.layer.masksToBounds = YES;
    resultsView.hidden = YES;
    // Below the fixed container in z-order so the panel can never cover the
    // header or the search field.
    [self.view insertSubview:resultsView belowSubview:self.searchBarContainer];
    [results didMoveToParentViewController:self];

    UILayoutGuide *safeArea = self.view.safeAreaLayoutGuide;
    // The panel height is an explicit required equality to the clamped desired
    // value (0 when inactive), so the solver never maximizes it and the fixed
    // bar/container can never be stretched.
    NSLayoutConstraint *height = [resultsView.heightAnchor constraintEqualToConstant:0.0];
    self.resultHeightConstraint = height;

    // Keyboard avoidance is a NON-required upper bound only. It never pushes the
    // panel (or anything above it) and is silently broken when no space exists.
    NSLayoutConstraint *bottomLimit = [resultsView.bottomAnchor
        constraintLessThanOrEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor
                                 constant:-8.0];
    bottomLimit.priority = 999.0;

    [NSLayoutConstraint activateConstraints:@[
        // Only the field's bottom constant; no feedback into the bar/container.
        [resultsView.topAnchor constraintEqualToAnchor:self.searchBarContainer.bottomAnchor constant:8.0],
        [resultsView.leadingAnchor constraintEqualToAnchor:safeArea.leadingAnchor constant:12.0],
        [resultsView.trailingAnchor constraintEqualToAnchor:safeArea.trailingAnchor constant:-12.0],
        height,
        bottomLimit,
    ]];
}

#pragma mark - Results panel layout

- (void)setSearchResultsVisible:(BOOL)visible {
    GPSLabSearchResultsViewController *results = self.searchResultsController;
    if (results == nil || !results.isViewLoaded) {
        return;
    }
    results.view.hidden = !visible;
    if (visible) {
        [self updateSearchResultsLayout];
    } else if (self.resultHeightConstraint.constant != 0.0) {
        self.resultHeightConstraint.constant = 0.0;
    }
}

// Sizes the bounded results panel from the measured keyboard layout guide. The
// required height equality is the only thing this writes (never the bar or the
// container), and only when the value actually changed, so the layout pass
// converges after at most one extra pass (no recursive height churn).
- (void)updateSearchResultsLayout {
    if (self.resultHeightConstraint == nil ||
        self.searchResultsController == nil ||
        !self.searchResultsController.isViewLoaded) {
        return;
    }
    if (self.searchResultsController.view.hidden) {
        if (self.resultHeightConstraint.constant != 0.0) {
            self.resultHeightConstraint.constant = 0.0;
        }
        return;
    }

    // Measure in the canvas' coordinate system; the guide never extends past
    // the viewport and clamps to a non-negative available height.
    CGFloat viewport = CGRectGetHeight(self.view.bounds);
    CGFloat topOffset = CGRectGetMaxY(self.searchBarContainer.frame) + 8.0;
    CGRect guide = self.view.keyboardLayoutGuide.layoutFrame;
    // The bottom bound keeps an 8pt gap: pass guide.top - 8 so the computed
    // desired height satisfies results.bottom <= guide.top - 8 exactly.
    CGFloat available = GPSLabSearchAvailableHeight(viewport, topOffset, CGRectGetMinY(guide) - 8.0);

    UIFontMetrics *metrics = [UIFontMetrics metricsForTextStyle:UIFontTextStyleBody];
    GPSLabSearchLayoutMetrics layout;
    layout.min_height = 0.0;
    layout.compact_height = MAX(80.0, [metrics scaledValueForValue:96.0]);
    layout.max_height = 320.0;
    layout.max_viewport_fraction = 0.45;

    CGFloat content = self.searchResultsController.estimatedContentHeight;
    BOOL hasResults = self.searchResultsController.hasResults;
    CGFloat desired = GPSLabSearchResultsHeight(available, viewport, content, hasResults ? 1 : 0, layout);

    if (fabs(desired - self.resultHeightConstraint.constant) > 0.5) {
        self.resultHeightConstraint.constant = desired;
    }
}

- (void)keyboardWillChangeFrame:(NSNotification *)notification {
    (void)notification;
    if (self.searchResultsController == nil || self.searchResultsController.view.hidden) {
        return;
    }
    // Refresh the guide, then recompute the required panel height so it tracks
    // the keyboard. The optional bottom bound is a safety net only.
    [self.view layoutIfNeeded];
    [self updateSearchResultsLayout];
}

#pragma mark - Floating controls

- (void)buildControls {
    UIButton *center = [self circularButtonWithSymbol:@"location.fill" action:@selector(centerTapped)];
    UIButton *favorites = [self circularButtonWithSymbol:@"star" action:@selector(favoritesTapped)];
    UIButton *route = [self circularButtonWithSymbol:@"arrow.triangle.turn.up.right.diamond.fill"
                                              action:@selector(routeTapped)];
    UIButton *options = [self circularButtonWithSymbol:@"slider.horizontal.3" action:@selector(settingsTapped)];
    self.controlButtons = @[center, favorites, route, options];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[center, favorites, route, options]];
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
    cancel.titleLabel.adjustsFontForContentSizeCategory = YES;
    [cancel addTarget:self action:@selector(cancelPicking) forControlEvents:UIControlEventTouchUpInside];
    self.pickCancelButton = cancel;

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
        ? GPSLabLocalized(@"overlay.pick.start")
        : GPSLabLocalized(@"overlay.pick.end");
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

#pragma mark - Localization

- (BOOL)isSearchActive {
    return GPSLabSearchSessionIsActive(&_searchSession);
}

- (BOOL)isSearchSessionActive {
    // The child results controller is not a UIKit modal, so there is no
    // dismissing phase: the session is active until it is explicitly ended.
    return GPSLabSearchSessionIsActive(&_searchSession);
}

- (void)endActiveSearch {
    BOOL wasActive = GPSLabSearchSessionIsActive(&_searchSession);

    // Reset session state and hide the child BEFORE resuming any deferred
    // presentation, so the coordinator sees an inactive canvas.
    [self.searchBar resignFirstResponder];
    [self setSearchResultsVisible:NO];
    [self.searchResultsController cancelActiveSearch];
    [self.searchResultsController endSearchSession];
    GPSLabSearchSessionEnd(&_searchSession);
    self.searchBar.text = @"";
    self.searchBar.showsCancelButton = NO;

    if (wasActive) {
        [self scheduleResolvePendingPresentation];
    }
}

// The coordinator's drain is non-reentrant. The child results controller has no
// UIKit modal transition, so the resume runs on the next main-queue turn: this
// can never nest inside the coordinator's current defer branch and lose the
// bounded pending presentation.
- (void)scheduleResolvePendingPresentation {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[GPSLabModalCoordinator sharedCoordinator] resolvePendingPresentation];
    });
}

- (void)languageDidChange:(NSNotification *)notification {
    (void)notification;
    [self applyLocalization];
}

- (void)applyLocalization {
    UIView *scope = self.view.window ?: self.view;
    [GPSLabLocalization applyLanguageAttributesToView:scope];
    // Geography and numeric content stay LTR; the map is never physically mirrored.
    [GPSLabLocalization forceLeftToRight:self.mapView];
    [GPSLabLocalization forceLeftToRight:self.statusLabel];

    self.titleLabel.text = GPSLabLocalized(@"overlay.title");
    self.enabledLabel.text = GPSLabLocalized(@"overlay.enabled");
    self.enabledSwitch.accessibilityLabel = GPSLabLocalized(@"overlay.enabled");
    self.searchBar.placeholder = GPSLabLocalized(@"overlay.search.placeholder");
    self.searchBar.accessibilityLabel = GPSLabLocalized(@"overlay.search.placeholder");
    [self.pickCancelButton setTitle:GPSLabLocalized(@"common.cancel") forState:UIControlStateNormal];

    self.headerSettingsButton.accessibilityLabel = GPSLabLocalized(@"overlay.accessibility.settings");
    self.headerCloseButton.accessibilityLabel = GPSLabLocalized(@"common.close");
    NSArray<NSString *> *controlKeys = @[
        @"overlay.accessibility.center",
        @"overlay.accessibility.favorites",
        @"overlay.accessibility.route",
        @"overlay.accessibility.settings",
    ];
    NSUInteger controlCount = MIN(self.controlButtons.count, controlKeys.count);
    for (NSUInteger index = 0; index < controlCount; index++) {
        self.controlButtons[index].accessibilityLabel = GPSLabLocalized(controlKeys[index]);
    }

    self.syntheticAnnotation.title = GPSLabLocalized(@"overlay.annotation.synthetic");
    if (self.realLocationAnnotation != nil) {
        self.realLocationAnnotation.title = GPSLabLocalized(@"overlay.annotation.real");
    }
    if (self.routeStartPin != nil) {
        self.routeStartPin.title = GPSLabLocalized(@"route.annotation.start");
    }
    if (self.routeEndPin != nil) {
        self.routeEndPin.title = GPSLabLocalized(@"route.annotation.end");
    }

    [self updateStatusLabel];
    [self updatePickBanner];
}

#pragma mark - Outside tap (hide keyboard only)

- (void)installOutsideTapRecognizer {
    if (self.outsideTapRecognizer != nil) {
        return;
    }
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                          action:@selector(outsideTapped:)];
    tap.delegate = self;
    // Observe without consuming: map taps/pan/zoom and controls keep working.
    tap.cancelsTouchesInView = NO;
    tap.delaysTouchesBegan = NO;
    tap.delaysTouchesEnded = NO;
    [self.view addGestureRecognizer:tap];
    self.outsideTapRecognizer = tap;
}

- (void)outsideTapped:(UITapGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateEnded) {
        return;
    }
    [self endActiveSearch];
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
    [GPSLabStatusLog append:(self.enabledSwitch.on ? GPSLabLocalized(@"overlay.engine.enabled")
                                                   : GPSLabLocalized(@"overlay.engine.disabled"))];
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
    // Acquire the key-window lease BEFORE the field becomes first responder so
    // the keyboard session is owned by the GPSLab window, not the host.
    [[GPSLabOverlayPresenter sharedPresenter] acquireKeyLease];
    return YES;
}

- (void)searchBarTextDidBeginEditing:(UISearchBar *)searchBar {
    // The bar is a standalone GPSLab view; activation only starts the session
    // and reveals the bounded child results panel below it. The bar and the
    // first responder are never re-added or replaced.
    if (!GPSLabSearchSessionIsActive(&_searchSession)) {
        GPSLabSearchSessionBegin(&_searchSession);
    }
    searchBar.showsCancelButton = YES;
    [self setSearchResultsVisible:YES];
    [self.searchResultsController updateSearchResultsForQuery:searchBar.text ?: @""];
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    (void)searchBar;
    // Only a live session may drive results: a late callback after Cancel must
    // not resurrect the search phase.
    if (!GPSLabSearchSessionIsActive(&_searchSession)) {
        return;
    }
    [self.searchResultsController updateSearchResultsForQuery:searchText ?: @""];
}

- (void)searchBarTextDidEndEditing:(UISearchBar *)searchBar {
    // Keep Cancel visible for the whole session: resigning the keyboard (e.g.
    // the Search key) must not remove the only escape while results are shown.
    searchBar.showsCancelButton = GPSLabSearchSessionIsActive(&_searchSession) ? YES : NO;
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    // Explicit Search key: commit the session (only while editing), refresh the
    // query, then resign the keyboard. The bar, Cancel and results stay on
    // screen.
    if (GPSLabSearchSessionCanCommit(&_searchSession)) {
        GPSLabSearchSessionCommit(&_searchSession);
    }
    if (GPSLabSearchSessionIsActive(&_searchSession)) {
        [self.searchResultsController updateSearchResultsForQuery:searchBar.text ?: @""];
    }
    [searchBar resignFirstResponder];
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)searchBar {
    (void)searchBar;
    [self endActiveSearch];
}

- (void)applyMapItem:(MKMapItem *)item {
    if (item == nil) {
        return;
    }
    [self applyCoordinate:item.placemark.coordinate altitude:[[GPSLabEngine sharedEngine] configuration].altitude];
    [self endActiveSearch];
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
    [[GPSLabModalCoordinator sharedCoordinator] presentSheetRoot:manual completion:nil];
}

- (void)presentFavoritesSheet {
    GPSLabFavoritesViewController *favorites = [[GPSLabFavoritesViewController alloc] init];
    GPSLabOverlayViewController *__weak weakSelf = self;
    favorites.selectHandler = ^(GPSLabBookmark *bookmark) {
        [weakSelf applyCoordinate:CLLocationCoordinate2DMake(bookmark.latitude, bookmark.longitude)
                         altitude:bookmark.altitude];
    };
    [[GPSLabModalCoordinator sharedCoordinator] presentSheetRoot:favorites completion:nil];
}

- (void)presentRecentsSheet {
    GPSLabRecentsViewController *recents = [[GPSLabRecentsViewController alloc] init];
    GPSLabOverlayViewController *__weak weakSelf = self;
    recents.selectHandler = ^(CLLocationCoordinate2D coordinate, double altitude) {
        [weakSelf applyCoordinate:coordinate altitude:altitude];
    };
    [[GPSLabModalCoordinator sharedCoordinator] presentSheetRoot:recents completion:nil];
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
    [[GPSLabModalCoordinator sharedCoordinator] presentSheetRoot:sheet completion:nil];
}

- (void)presentRouteSheet {
    GPSLabRouteViewController *route = [[GPSLabRouteViewController alloc] init];
    route.startItem = self.pendingRouteStartItem;
    route.endItem = self.pendingRouteEndItem;

    GPSLabOverlayViewController *__weak weakSelf = self;
    route.pickStartHandler = ^{
        [[GPSLabModalCoordinator sharedCoordinator] dismissTopmostAnimated:YES completion:^{
            GPSLabOverlayViewController *strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }
            strongSelf.reopenRouteAfterPick = YES;
            [strongSelf beginPickingRouteStart];
        }];
    };
    route.pickEndHandler = ^{
        [[GPSLabModalCoordinator sharedCoordinator] dismissTopmostAnimated:YES completion:^{
            GPSLabOverlayViewController *strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }
            strongSelf.reopenRouteAfterPick = YES;
            [strongSelf beginPickingRouteEnd];
        }];
    };
    route.routeChangedHandler = ^{
        [weakSelf updateRouteAnnotations];
        [weakSelf updateStatusLabel];
    };
    [[GPSLabModalCoordinator sharedCoordinator] presentSheetRoot:route completion:nil];
}

- (void)presentOptionsSheet {
    GPSLabConfiguration *configuration = [[GPSLabEngine sharedEngine] configuration];
    GPSLabOptionsViewController *options = [[GPSLabOptionsViewController alloc] init];
    options.keepLastCoordinate = configuration.keepLastCoordinate;
    options.realLocationEnabled = self.realLocationDisplayEnabled;
    options.mapStyle = self.mapStyle;
    // Active is silent; surface only a meaningful subscription status in settings.
    options.subscriptionStatusText = ([[GPSLabLicenseManager sharedManager] state] == GPSLabEntitlementStateGrace)
        ? GPSLabLocalized(@"subscription.grace")
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
        GPSLabOverlayViewController *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        [[GPSLabModalCoordinator sharedCoordinator] dismissTopmostAnimated:YES completion:^{
            [strongSelf presentManualEntrySheet];
        }];
    };
    options.recentsHandler = ^{
        GPSLabOverlayViewController *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        [[GPSLabModalCoordinator sharedCoordinator] dismissTopmostAnimated:YES completion:^{
            [strongSelf presentRecentsSheet];
        }];
    };
    options.fluctuationHandler = ^{
        GPSLabOverlayViewController *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        [[GPSLabModalCoordinator sharedCoordinator] dismissTopmostAnimated:YES completion:^{
            [strongSelf presentFluctuationSheet];
        }];
    };
    [[GPSLabModalCoordinator sharedCoordinator] presentSheetRoot:options completion:nil];
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
    NSString *name = pickingStart ? GPSLabLocalized(@"route.annotation.start")
                                  : GPSLabLocalized(@"route.annotation.end");
    MKMapItem *item = [self mapItemForCoordinate:coordinate name:name];
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

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
       shouldReceiveTouch:(UITouch *)touch {
    if (gestureRecognizer != self.outsideTapRecognizer) {
        // Map tap/long-press observe touches exactly as before.
        return YES;
    }
    if (!self.isSearchSessionActive) {
        return NO;
    }
    UIView *touchView = touch.view;
    if (touchView == nil) {
        return NO;
    }
    // The child results panel owns its table cells and Done button: a tap there
    // must reach the table (selection / Done), never end the search first.
    GPSLabSearchResultsViewController *results = self.searchResultsController;
    if (results != nil && results.isViewLoaded &&
        [touchView isDescendantOfView:results.view]) {
        return NO;
    }
    // Never treat controls, text input, search or sheet content as "outside":
    // those own their own actions and must not also dismiss the keyboard.
    for (UIView *view = touchView; view != nil; view = view.superview) {
        if ([view isKindOfClass:[UIControl class]] ||
            [view isKindOfClass:[UITextField class]] ||
            [view isKindOfClass:[UITextView class]] ||
            [view isKindOfClass:[UISearchBar class]]) {
            return NO;
        }
    }
    UIViewController *presented = self.presentedViewController;
    if (presented != nil && presented.view != nil && [touchView isDescendantOfView:presented.view]) {
        return NO;
    }
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
            self.routeStartPin.title = GPSLabLocalized(@"route.annotation.start");
            [self.mapView addAnnotation:self.routeStartPin];
        }
        self.routeStartPin.coordinate = self.pendingRouteStartItem.placemark.coordinate;
    }
    if (self.pendingRouteEndItem != nil) {
        if (self.routeEndPin == nil) {
            self.routeEndPin = [[MKPointAnnotation alloc] init];
            self.routeEndPin.title = GPSLabLocalized(@"route.annotation.end");
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
        self.realLocationAnnotation.title = GPSLabLocalized(@"overlay.annotation.real");
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
    NSString *state = configuration.enabled ? GPSLabLocalized(@"overlay.enabled")
                                            : GPSLabLocalized(@"overlay.disabled");
    NSString *format = GPSLabLocalized(@"overlay.status.format");
    self.statusLabel.text = [NSString stringWithFormat:format,
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
