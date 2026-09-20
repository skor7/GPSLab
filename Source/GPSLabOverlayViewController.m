//
//  GPSLabOverlayViewController.m
//  GPSLab
//
//  Reference rebuild: ONE compact floating panel over a lightweight map snapshot
//  background. Inside the panel: a pinned header, a pinned standalone search bar
//  (fixed height) with a bounded GPSLab-owned results child, and a scrolling body
//  that starts with a real, interactive 278pt MKMapView card, followed by the
//  control card, profiles, simulation/test modules, actions and the compact
//  subscription footer.
//
//  The synthetic engine, hook layer, drift model, route simulator, modal policy,
//  search-bar policy, presenter/key-lease and license gate are unchanged; this
//  controller only drives them through their existing public APIs.
//

#import "GPSLabOverlayViewController.h"

#import <CoreLocation/CoreLocation.h>
#import <MapKit/MapKit.h>

// UIButton.contentEdgeInsets is deprecated under UIButtonConfiguration (iOS 15)
// but remains the supported API for the plain, configuration-less buttons used
// here. The deprecation is suppressed narrowly for this file.
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

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
#import "GPSLabProfile.h"
#import "GPSLabProfileApplicationCoordinator.h"
#import "GPSLabProfileFormViewController.h"
#import "GPSLabProfileStore.h"
#import "GPSLabProfilesPanelView.h"
#import "GPSLabRecentsViewController.h"
#import "GPSLabScheduler.h"
#import "GPSLabScheduleViewController.h"
#import "GPSLabSearchLayoutCore.h"
#import "GPSLabSearchResultsViewController.h"
#import "GPSLabSecureStore.h"
#import "GPSLabSheetViewController.h"
#import "GPSLabSimulationSettingsViewController.h"
#import "GPSLabStatusLog.h"
#import "GPSLabStore.h"
#import "GPSLabTheme.h"
#import "GPSLabTypes.h"

#pragma mark - Annotation

@interface GPSLabSyntheticAnnotation : NSObject <MKAnnotation>
@property (nonatomic, assign) CLLocationCoordinate2D coordinate;
@property (nonatomic, copy, nullable) NSString *title;
@end

@implementation GPSLabSyntheticAnnotation
@end

#pragma mark - Heading view

@interface GPSLabHeadingView : UIView
@property (nonatomic, assign) double heading;
@end

@implementation GPSLabHeadingView {
    UIView *_line;
    UIView *_knob;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _line = [[UIView alloc] initWithFrame:CGRectZero];
        _line.backgroundColor = GPSLabThemeBorderColor();
        [self addSubview:_line];
        _knob = [[UIView alloc] initWithFrame:CGRectZero];
        _knob.backgroundColor = UIColor.whiteColor;
        _knob.layer.cornerRadius = 14.0;
        [self addSubview:_knob];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat midY = CGRectGetMidY(self.bounds);
    _line.frame = CGRectMake(0.0, midY - 1.0, CGRectGetWidth(self.bounds), 2.0);
    double normalized = fmod(self.heading < 0.0 ? 0.0 : self.heading, 360.0) / 360.0;
    CGFloat x = (CGFloat)normalized * CGRectGetWidth(self.bounds);
    _knob.frame = CGRectMake(x - 14.0, midY - 14.0, 28.0, 28.0);
}

- (void)setHeading:(double)heading {
    _heading = heading;
    [self setNeedsLayout];
}

@end

#pragma mark - Overlay controller

typedef NS_ENUM(NSInteger, GPSLabMapPickMode) {
    GPSLabMapPickModeNone = 0,
    GPSLabMapPickModeRouteStart,
    GPSLabMapPickModeRouteEnd,
};

@interface GPSLabOverlayViewController () <MKMapViewDelegate, CLLocationManagerDelegate,
                                            UISearchBarDelegate, UIGestureRecognizerDelegate> {
    GPSLabSearchSession _searchSession;
}

// Panel chrome
@property (nonatomic, strong) UIImageView *backgroundImageView;
@property (nonatomic, strong) UIView *panelView;
@property (nonatomic, strong) UIView *headerView;
@property (nonatomic, strong) UIButton *languageButton;
@property (nonatomic, strong) UIButton *infoButton;
@property (nonatomic, strong) UILabel *headerTitleLabel;
@property (nonatomic, strong) UILabel *headerSubtitleLabel;
@property (nonatomic, strong) UIButton *masterButton;
@property (nonatomic, strong) UIView *masterDot;
@property (nonatomic, strong) UIButton *closeButton;

// Search
@property (nonatomic, strong) UIView *searchBarContainer;
@property (nonatomic, strong, nullable) UISearchBar *searchBar;
@property (nonatomic, strong, nullable) GPSLabSearchResultsViewController *searchResultsController;
@property (nonatomic, strong, nullable) NSLayoutConstraint *resultHeightConstraint;
@property (nonatomic, strong) UIScrollView *bodyScrollView;
@property (nonatomic, strong) UIStackView *bodyStack;
@property (nonatomic, strong, nullable) UITapGestureRecognizer *outsideTapRecognizer;
@property (nonatomic, strong, nullable) NSLayoutConstraint *panelLeadingConstraint;
@property (nonatomic, strong, nullable) NSLayoutConstraint *panelTrailingConstraint;

// Map card
@property (nonatomic, strong) UIView *mapCard;
@property (nonatomic, strong) MKMapView *mapView;
@property (nonatomic, strong) UIButton *bookmarkButton;
@property (nonatomic, strong) UIButton *centerButton;
@property (nonatomic, strong) UILabel *pickBannerLabel;

// Map / favorites tab
@property (nonatomic, strong) UISegmentedControl *mapFavoritesSegment;
@property (nonatomic, strong) UIStackView *favoritesList;
@property (nonatomic, strong) UIView *favoritesCard;

// Control card
@property (nonatomic, strong) UIView *controlCard;
@property (nonatomic, strong) UISegmentedControl *staticRouteSegment;
@property (nonatomic, strong) UILabel *coordsTitleLabel;
@property (nonatomic, strong) UILabel *coordsBigLabel;
@property (nonatomic, strong) NSArray<UILabel *> *coordValueLabels;
@property (nonatomic, strong) GPSLabHeadingView *headingView;
@property (nonatomic, strong) UILabel *headingValueLabel;
@property (nonatomic, strong) UISwitch *driftSwitch;
@property (nonatomic, strong) UISwitch *keepLastSwitch;
@property (nonatomic, strong) UISwitch *realLocationSwitch;
@property (nonatomic, strong) UIButton *scheduleButton;

// Route section
@property (nonatomic, strong) UIStackView *routeSection;
@property (nonatomic, strong) UILabel *routeStartLabel;
@property (nonatomic, strong) UILabel *routeEndLabel;
@property (nonatomic, strong) UISegmentedControl *routeModeSegment;
@property (nonatomic, strong) UISlider *routeSpeedSlider;
@property (nonatomic, strong) UILabel *routeSpeedValueLabel;
@property (nonatomic, strong) UIButton *routePlayButton;
@property (nonatomic, strong) UIButton *routeStopButton;
@property (nonatomic, strong) UISegmentedControl *routeStopBehaviorSegment;

// Profiles + modules + actions + subscription
@property (nonatomic, strong) GPSLabProfilesPanelView *profilesPanel;
@property (nonatomic, strong) UIButton *cancelButton;
@property (nonatomic, strong) UIButton *applyButton;
@property (nonatomic, strong) UIView *subscriptionCard;
@property (nonatomic, strong) UILabel *subscriptionTitleLabel;
@property (nonatomic, strong) UILabel *subscriptionStatusLabel;
@property (nonatomic, strong) UILabel *subscriptionPlanCaption;
@property (nonatomic, strong) UILabel *subscriptionPlanValue;
@property (nonatomic, strong) UILabel *subscriptionExpiryCaption;
@property (nonatomic, strong) UILabel *subscriptionExpiryValue;
@property (nonatomic, strong) UILabel *installationLabel;

// State
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

@property (nonatomic, strong, nullable) NSTimer *tickTimer;
@property (nonatomic, strong, nullable) NSTimer *snapshotTimer;

@property (nonatomic, copy) NSArray<GPSLabProfile *> *profiles;
@property (nonatomic, copy, nullable) NSString *selectedProfileIdentifier;
@property (nonatomic, copy, nullable) NSString *appliedProfileIdentifier;

@end

@implementation GPSLabOverlayViewController

#pragma mark - Lifecycle

- (instancetype)init {
    return [super initWithNibName:nil bundle:nil];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = GPSLabThemePanelColor();
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.mapStyle = GPSLabMapStyleStandard;

    [self buildBackground];
    [self buildPanel];
    [self buildHeader];
    [self buildSearchBar];
    [self buildBody];
    [self installOutsideTapRecognizer];
    [self loadConfigurationIntoUI];
    [self reloadProfiles];
    [self applyLocalization];

    [[GPSLabScheduler sharedScheduler] startObserving];

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(engineStateDidChange:) name:GPSLabEngineStateDidChangeNotification object:nil];
    [center addObserver:self selector:@selector(languageDidChange:) name:GPSLabLanguageDidChangeNotification object:nil];
    [center addObserver:self selector:@selector(licenseStateDidChange:) name:GPSLabLicenseStateDidChangeNotification object:nil];
    [center addObserver:self selector:@selector(keyboardWillChangeFrame:) name:UIKeyboardWillChangeFrameNotification object:nil];
    [center addObserver:self selector:@selector(applicationDidBecomeActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self updateSearchResultsLayout];
    [self updatePanelInsets];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self applyLocalization];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self startTickTimer];
    [self scheduleBackgroundSnapshot];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self stopTickTimer];
    [self stopRealLocationDisplay];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self stopTickTimer];
    [self.snapshotTimer invalidate];
    [self stopRealLocationDisplay];
}

- (BOOL)isSearchActive {
    return GPSLabSearchSessionIsActive(&_searchSession);
}

- (BOOL)isSearchSessionActive {
    return GPSLabSearchSessionIsActive(&_searchSession);
}

#pragma mark - Panel chrome

- (void)buildBackground {
    self.backgroundImageView = [[UIImageView alloc] initWithFrame:CGRectZero];
    self.backgroundImageView.translatesAutoresizingMaskIntoConstraints = NO;
    self.backgroundImageView.contentMode = UIViewContentModeScaleAspectFill;
    self.backgroundImageView.clipsToBounds = YES;
    self.backgroundImageView.backgroundColor = GPSLabColorFromHex(0x3B474F);
    [self.view addSubview:self.backgroundImageView];
    UIView *dim = [[UIView alloc] initWithFrame:CGRectZero];
    dim.translatesAutoresizingMaskIntoConstraints = NO;
    dim.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.42];
    [self.view addSubview:dim];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.backgroundImageView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.backgroundImageView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.backgroundImageView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.backgroundImageView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [dim.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [dim.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
        [dim.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [dim.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
    ]];
}

- (void)buildPanel {
    self.panelView = [[UIView alloc] initWithFrame:CGRectZero];
    self.panelView.translatesAutoresizingMaskIntoConstraints = NO;
    self.panelView.backgroundColor = GPSLabThemePanelColor();
    self.panelView.layer.cornerRadius = 28.0;
    self.panelView.layer.masksToBounds = YES;
    self.panelView.layer.borderWidth = 1.0;
    self.panelView.layer.borderColor = [GPSLabThemeAccentColor() colorWithAlphaComponent:0.22].CGColor;
    [self.view addSubview:self.panelView];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    self.panelLeadingConstraint = [self.panelView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20.0];
    self.panelTrailingConstraint = [self.panelView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20.0];
    [NSLayoutConstraint activateConstraints:@[
        [self.panelView.topAnchor constraintEqualToAnchor:safe.topAnchor constant:6.0],
        self.panelLeadingConstraint,
        self.panelTrailingConstraint,
        [self.panelView.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-22.0],
    ]];
}

- (void)updatePanelInsets {
    CGFloat width = CGRectGetWidth(self.view.bounds);
    CGFloat inset = width < 460.0 ? 8.0 : 20.0;
    self.panelLeadingConstraint.constant = inset;
    self.panelTrailingConstraint.constant = -inset;
}

- (void)buildHeader {
    self.headerView = [[UIView alloc] initWithFrame:CGRectZero];
    self.headerView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.panelView addSubview:self.headerView];

    self.languageButton = [self chromeButtonWithTitle:@"EN" action:@selector(languageTapped)];
    self.languageButton.titleLabel.font = GPSLabThemeFont(15.0, UIFontWeightBold);
    self.languageButton.layer.cornerRadius = 14.0;
    self.languageButton.layer.borderWidth = 1.0;
    self.languageButton.layer.borderColor = GPSLabThemeBorderColor().CGColor;
    self.languageButton.backgroundColor = GPSLabColorFromHex(0x1A1A20);
    self.languageButton.contentEdgeInsets = UIEdgeInsetsMake(10.0, 13.0, 10.0, 13.0);

    self.infoButton = [self chromeButtonWithTitle:@"ⓘ" action:@selector(infoTapped)];
    self.infoButton.titleLabel.font = GPSLabThemeFont(20.0, UIFontWeightBold);
    self.infoButton.layer.cornerRadius = 14.0;
    self.infoButton.layer.borderWidth = 1.0;
    self.infoButton.layer.borderColor = GPSLabThemeBorderColor().CGColor;
    self.infoButton.backgroundColor = GPSLabColorFromHex(0x1A1A20);

    self.headerTitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.headerTitleLabel.font = GPSLabThemeFont(34.0, UIFontWeightHeavy);
    self.headerTitleLabel.textColor = GPSLabThemeTextColor();
    self.headerTitleLabel.textAlignment = NSTextAlignmentCenter;
    // Nominal reference size stays 34pt; shrink-to-fit keeps "GPSLab" on one line
    // on narrow iPhones (360/375) without moving the header row.
    self.headerTitleLabel.adjustsFontSizeToFitWidth = YES;
    self.headerTitleLabel.minimumScaleFactor = 0.6;
    self.headerTitleLabel.numberOfLines = 1;
    self.headerTitleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.headerSubtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.headerSubtitleLabel.font = GPSLabThemeFont(15.0, UIFontWeightRegular);
    self.headerSubtitleLabel.textColor = GPSLabColorFromHex(0xB9A1D2);
    self.headerSubtitleLabel.textAlignment = NSTextAlignmentCenter;
    self.headerSubtitleLabel.adjustsFontSizeToFitWidth = YES;
    self.headerSubtitleLabel.minimumScaleFactor = 0.7;
    self.headerSubtitleLabel.numberOfLines = 1;
    self.headerSubtitleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    UIStackView *titleColumn = [[UIStackView alloc] initWithArrangedSubviews:@[ self.headerTitleLabel, self.headerSubtitleLabel ]];
    titleColumn.axis = UILayoutConstraintAxisVertical;
    titleColumn.spacing = 8.0;
    titleColumn.alignment = UIStackViewAlignmentCenter;

    self.masterButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.masterButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.masterDot = [[UIView alloc] initWithFrame:CGRectZero];
    self.masterDot.translatesAutoresizingMaskIntoConstraints = NO;
    self.masterDot.layer.cornerRadius = 7.0;
    self.masterDot.userInteractionEnabled = NO;
    [self.masterButton addSubview:self.masterDot];
    [self.masterButton addTarget:self action:@selector(masterTapped) forControlEvents:UIControlEventTouchUpInside];
    [NSLayoutConstraint activateConstraints:@[
        [self.masterButton.widthAnchor constraintEqualToConstant:44.0],
        [self.masterButton.heightAnchor constraintEqualToConstant:44.0],
        [self.masterDot.centerXAnchor constraintEqualToAnchor:self.masterButton.centerXAnchor],
        [self.masterDot.centerYAnchor constraintEqualToAnchor:self.masterButton.centerYAnchor],
        [self.masterDot.widthAnchor constraintEqualToConstant:14.0],
        [self.masterDot.heightAnchor constraintEqualToConstant:14.0],
    ]];

    self.closeButton = [self chromeButtonWithTitle:@"✕" action:@selector(closeTapped)];
    self.closeButton.titleLabel.font = GPSLabThemeFont(22.0, UIFontWeightSemibold);
    self.closeButton.layer.cornerRadius = 14.0;
    self.closeButton.layer.borderWidth = 1.0;
    self.closeButton.layer.borderColor = GPSLabThemeBorderColor().CGColor;
    self.closeButton.backgroundColor = GPSLabColorFromHex(0x1A1A20);

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.languageButton, self.infoButton, titleColumn, self.masterButton, self.closeButton,
    ]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 10.0;
    row.semanticContentAttribute = UISemanticContentAttributeForceLeftToRight;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [self.headerView addSubview:row];

    [NSLayoutConstraint activateConstraints:@[
        [self.headerView.topAnchor constraintEqualToAnchor:self.panelView.topAnchor constant:14.0],
        [self.headerView.leadingAnchor constraintEqualToAnchor:self.panelView.leadingAnchor],
        [self.headerView.trailingAnchor constraintEqualToAnchor:self.panelView.trailingAnchor],
        [row.topAnchor constraintEqualToAnchor:self.headerView.topAnchor],
        [row.leadingAnchor constraintEqualToAnchor:self.headerView.leadingAnchor constant:18.0],
        [row.trailingAnchor constraintEqualToAnchor:self.headerView.trailingAnchor constant:-18.0],
        [row.bottomAnchor constraintEqualToAnchor:self.headerView.bottomAnchor],
        [self.infoButton.widthAnchor constraintEqualToConstant:44.0],
        [self.infoButton.heightAnchor constraintEqualToConstant:44.0],
        [self.closeButton.widthAnchor constraintEqualToConstant:46.0],
        [self.closeButton.heightAnchor constraintEqualToConstant:46.0],
        [self.languageButton.heightAnchor constraintEqualToConstant:44.0],
    ]];
    [self.languageButton setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
}

- (UIButton *)chromeButtonWithTitle:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

#pragma mark - Search

- (void)buildSearchBar {
    GPSLabSearchResultsViewController *results = [[GPSLabSearchResultsViewController alloc] init];
    GPSLabOverlayViewController *__weak weakSelf = self;
    results.selectionHandler = ^(MKMapItem *item) { [weakSelf applyMapItem:item]; };
    results.doneHandler = ^{ [weakSelf endActiveSearch]; };
    results.contentChangeHandler = ^{ [weakSelf updateSearchResultsLayout]; };
    self.searchResultsController = results;

    self.searchBarContainer = [[UIView alloc] initWithFrame:CGRectZero];
    self.searchBarContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.searchBarContainer.backgroundColor = GPSLabThemeFieldColor();
    self.searchBarContainer.layer.cornerRadius = 20.0;
    self.searchBarContainer.layer.masksToBounds = YES;
    self.searchBarContainer.layer.borderWidth = 1.0;
    self.searchBarContainer.layer.borderColor = [GPSLabThemeAccentColor() colorWithAlphaComponent:0.34].CGColor;
    [self.panelView addSubview:self.searchBarContainer];

    UISearchBar *bar = [[UISearchBar alloc] initWithFrame:CGRectZero];
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    bar.delegate = self;
    bar.searchBarStyle = UISearchBarStyleMinimal;
    bar.backgroundImage = [UIImage new];
    if (@available(iOS 13.0, *)) {
        bar.searchTextField.textColor = UIColor.whiteColor;
        bar.searchTextField.tintColor = GPSLabThemeAccentColor();
        bar.searchTextField.backgroundColor = UIColor.clearColor;
    }
    self.searchBar = bar;
    [self.searchBarContainer addSubview:bar];

    // FIXED bar height from the pure C helper; the reference search row is 62pt.
    CGFloat intrinsicHeight = bar.intrinsicContentSize.height;
    if (!(intrinsicHeight > 0.0)) {
        intrinsicHeight = 56.0;
    }
    CGFloat barHeight = GPSLabSearchBarHeight(intrinsicHeight, 62.0);

    [NSLayoutConstraint activateConstraints:@[
        [self.searchBarContainer.topAnchor constraintEqualToAnchor:self.headerView.bottomAnchor constant:10.0],
        [self.searchBarContainer.leadingAnchor constraintEqualToAnchor:self.panelView.leadingAnchor constant:20.0],
        [self.searchBarContainer.trailingAnchor constraintEqualToAnchor:self.panelView.trailingAnchor constant:-20.0],
        [self.searchBarContainer.heightAnchor constraintEqualToConstant:barHeight],
        [bar.topAnchor constraintEqualToAnchor:self.searchBarContainer.topAnchor],
        [bar.bottomAnchor constraintEqualToAnchor:self.searchBarContainer.bottomAnchor],
        [bar.leadingAnchor constraintEqualToAnchor:self.searchBarContainer.leadingAnchor constant:6.0],
        [bar.trailingAnchor constraintEqualToAnchor:self.searchBarContainer.trailingAnchor constant:-6.0],
        [bar.heightAnchor constraintEqualToConstant:barHeight],
    ]];

    [self mountSearchResultsChild];
}

- (void)mountSearchResultsChild {
    GPSLabSearchResultsViewController *results = self.searchResultsController;
    if (results == nil) {
        return;
    }
    [self addChildViewController:results];
    UIView *resultsView = results.view;
    resultsView.translatesAutoresizingMaskIntoConstraints = NO;
    resultsView.layer.cornerRadius = 16.0;
    resultsView.layer.masksToBounds = YES;
    resultsView.hidden = YES;
    [self.panelView insertSubview:resultsView belowSubview:self.searchBarContainer];
    [results didMoveToParentViewController:self];

    NSLayoutConstraint *height = [resultsView.heightAnchor constraintEqualToConstant:0.0];
    self.resultHeightConstraint = height;
    NSLayoutConstraint *bottomLimit = [resultsView.bottomAnchor
        constraintLessThanOrEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor
                                 constant:-8.0];
    bottomLimit.priority = 999.0;

    [NSLayoutConstraint activateConstraints:@[
        [resultsView.topAnchor constraintEqualToAnchor:self.searchBarContainer.bottomAnchor constant:8.0],
        [resultsView.leadingAnchor constraintEqualToAnchor:self.panelView.leadingAnchor constant:20.0],
        [resultsView.trailingAnchor constraintEqualToAnchor:self.panelView.trailingAnchor constant:-20.0],
        height,
        bottomLimit,
    ]];
}

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

- (void)updateSearchResultsLayout {
    if (self.resultHeightConstraint == nil || self.searchResultsController == nil ||
        !self.searchResultsController.isViewLoaded) {
        return;
    }
    if (self.searchResultsController.view.hidden) {
        if (self.resultHeightConstraint.constant != 0.0) {
            self.resultHeightConstraint.constant = 0.0;
        }
        return;
    }
    CGFloat viewport = CGRectGetHeight(self.view.bounds);
    CGRect containerFrame = [self.searchBarContainer convertRect:self.searchBarContainer.bounds toView:self.view];
    CGFloat topOffset = CGRectGetMaxY(containerFrame) + 8.0;
    CGRect guide = self.view.keyboardLayoutGuide.layoutFrame;
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
    [self.view layoutIfNeeded];
    [self updateSearchResultsLayout];
}

- (void)endActiveSearch {
    BOOL wasActive = GPSLabSearchSessionIsActive(&_searchSession);
    [self.searchBar resignFirstResponder];
    [self setSearchResultsVisible:NO];
    [self.searchResultsController cancelActiveSearch];
    [self.searchResultsController endSearchSession];
    GPSLabSearchSessionEnd(&_searchSession);
    self.searchBar.text = @"";
    self.searchBar.showsCancelButton = NO;
    if (wasActive) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[GPSLabModalCoordinator sharedCoordinator] resolvePendingPresentation];
        });
    }
}

#pragma mark - Body

- (void)buildBody {
    self.bodyScrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
    self.bodyScrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.bodyScrollView.alwaysBounceVertical = YES;
    self.bodyScrollView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    self.bodyScrollView.showsVerticalScrollIndicator = NO;
    [self.panelView addSubview:self.bodyScrollView];

    self.bodyStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    self.bodyStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.bodyStack.axis = UILayoutConstraintAxisVertical;
    self.bodyStack.spacing = 18.0;
    [self.bodyScrollView addSubview:self.bodyStack];

    UIView *resultsView = self.searchResultsController.view;
    [NSLayoutConstraint activateConstraints:@[
        [self.bodyScrollView.topAnchor constraintEqualToAnchor:resultsView.bottomAnchor constant:12.0],
        [self.bodyScrollView.leadingAnchor constraintEqualToAnchor:self.panelView.leadingAnchor],
        [self.bodyScrollView.trailingAnchor constraintEqualToAnchor:self.panelView.trailingAnchor],
        [self.bodyScrollView.bottomAnchor constraintEqualToAnchor:self.panelView.bottomAnchor],
        [self.bodyStack.topAnchor constraintEqualToAnchor:self.bodyScrollView.contentLayoutGuide.topAnchor constant:2.0],
        [self.bodyStack.bottomAnchor constraintEqualToAnchor:self.bodyScrollView.contentLayoutGuide.bottomAnchor constant:-24.0],
        [self.bodyStack.leadingAnchor constraintEqualToAnchor:self.bodyScrollView.contentLayoutGuide.leadingAnchor constant:20.0],
        [self.bodyStack.trailingAnchor constraintEqualToAnchor:self.bodyScrollView.contentLayoutGuide.trailingAnchor constant:-20.0],
        [self.bodyStack.widthAnchor constraintEqualToAnchor:self.bodyScrollView.frameLayoutGuide.widthAnchor constant:-40.0],
    ]];

    [self.bodyStack addArrangedSubview:[self mapAreaContainer]];
    [self.bodyStack addArrangedSubview:[self controlCardView]];
    self.profilesPanel = [[GPSLabProfilesPanelView alloc] initWithFrame:CGRectZero];
    GPSLabOverlayViewController *__weak weakSelf = self;
    self.profilesPanel.addHandler = ^{
        GPSLabOverlayViewController *strongSelf = weakSelf;
        if (strongSelf != nil) {
            [strongSelf presentProfileFormForProfile:nil];
        }
    };
    self.profilesPanel.selectHandler = ^(GPSLabProfile *profile) { [weakSelf selectProfile:profile]; };
    self.profilesPanel.editHandler = ^(GPSLabProfile *profile) {
        [weakSelf presentProfileFormForProfile:profile];
    };
    self.profilesPanel.applyHandler = ^(GPSLabProfile *profile) { [weakSelf applyProfile:profile]; };
    [self.bodyStack addArrangedSubview:self.profilesPanel];
    [self.bodyStack addArrangedSubview:[self simulationGroupView]];
    [self.bodyStack addArrangedSubview:[self actionsView]];
    [self.bodyStack addArrangedSubview:[self subscriptionCardView]];
}

- (UIView *)mapAreaContainer {
    UIView *container = [[UIView alloc] initWithFrame:CGRectZero];

    self.mapCard = [[UIView alloc] initWithFrame:CGRectZero];
    self.mapCard.translatesAutoresizingMaskIntoConstraints = NO;
    self.mapCard.backgroundColor = GPSLabColorFromHex(0xE8E7DF);
    self.mapCard.layer.cornerRadius = 24.0;
    self.mapCard.layer.masksToBounds = YES;
    self.mapCard.layer.borderWidth = 1.0;
    self.mapCard.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.08].CGColor;

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
    [self.mapCard addSubview:mapView];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(mapTapped:)];
    tap.delegate = self;
    [mapView addGestureRecognizer:tap];
    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(mapLongPressed:)];
    longPress.delegate = self;
    [mapView addGestureRecognizer:longPress];

    self.syntheticAnnotation = [[GPSLabSyntheticAnnotation alloc] init];
    self.syntheticAnnotation.title = GPSLabLocalized(@"overlay.annotation.synthetic");
    [mapView addAnnotation:self.syntheticAnnotation];

    // The parent scroll view must yield to MapKit while a drag starts on the map.
    UIPanGestureRecognizer *shield = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(mapPanShield:)];
    shield.delegate = self;
    shield.cancelsTouchesInView = NO;
    [self.mapCard addGestureRecognizer:shield];

    self.bookmarkButton = [self mapOverlayButtonWithSymbol:@"heart" action:@selector(bookmarkTapped)];
    self.centerButton = [self mapOverlayButtonWithSymbol:@"location.fill" action:@selector(centerTapped)];
    [self.mapCard addSubview:self.bookmarkButton];
    [self.mapCard addSubview:self.centerButton];

    self.pickBannerLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.pickBannerLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.pickBannerLabel.font = GPSLabThemeFont(13.0, UIFontWeightSemibold);
    self.pickBannerLabel.textColor = UIColor.whiteColor;
    self.pickBannerLabel.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.86];
    self.pickBannerLabel.layer.cornerRadius = 10.0;
    self.pickBannerLabel.layer.masksToBounds = YES;
    self.pickBannerLabel.layer.masksToBounds = YES;
    self.pickBannerLabel.textAlignment = NSTextAlignmentCenter;
    self.pickBannerLabel.hidden = YES;
    [self.mapCard addSubview:self.pickBannerLabel];

    [NSLayoutConstraint activateConstraints:@[
        [mapView.topAnchor constraintEqualToAnchor:self.mapCard.topAnchor],
        [mapView.bottomAnchor constraintEqualToAnchor:self.mapCard.bottomAnchor],
        [mapView.leadingAnchor constraintEqualToAnchor:self.mapCard.leadingAnchor],
        [mapView.trailingAnchor constraintEqualToAnchor:self.mapCard.trailingAnchor],
        [self.bookmarkButton.topAnchor constraintEqualToAnchor:self.mapCard.topAnchor constant:16.0],
        [self.bookmarkButton.leadingAnchor constraintEqualToAnchor:self.mapCard.leadingAnchor constant:16.0],
        [self.centerButton.topAnchor constraintEqualToAnchor:self.mapCard.topAnchor constant:16.0],
        [self.centerButton.trailingAnchor constraintEqualToAnchor:self.mapCard.trailingAnchor constant:-16.0],
        [self.pickBannerLabel.centerXAnchor constraintEqualToAnchor:self.mapCard.centerXAnchor],
        [self.pickBannerLabel.bottomAnchor constraintEqualToAnchor:self.mapCard.bottomAnchor constant:-12.0],
        [self.pickBannerLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.mapCard.leadingAnchor constant:12.0],
        [self.pickBannerLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.mapCard.trailingAnchor constant:-12.0],
    ]];

    self.favoritesCard = [[UIView alloc] initWithFrame:CGRectZero];
    self.favoritesCard.translatesAutoresizingMaskIntoConstraints = NO;
    self.favoritesCard.backgroundColor = GPSLabThemeCardColor();
    self.favoritesCard.layer.cornerRadius = 24.0;
    self.favoritesCard.layer.masksToBounds = YES;
    self.favoritesCard.layer.borderWidth = 0.5;
    self.favoritesCard.layer.borderColor = GPSLabThemeBorderColor().CGColor;
    self.favoritesCard.hidden = YES;

    UIScrollView *favoritesScroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    favoritesScroll.translatesAutoresizingMaskIntoConstraints = NO;
    self.favoritesList = [[UIStackView alloc] initWithFrame:CGRectZero];
    self.favoritesList.translatesAutoresizingMaskIntoConstraints = NO;
    self.favoritesList.axis = UILayoutConstraintAxisVertical;
    self.favoritesList.spacing = 8.0;
    [favoritesScroll addSubview:self.favoritesList];
    [self.favoritesCard addSubview:favoritesScroll];

    [container addSubview:self.mapCard];
    [container addSubview:self.favoritesCard];
    self.mapCard.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [self.mapCard.topAnchor constraintEqualToAnchor:container.topAnchor],
        [self.mapCard.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [self.mapCard.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [self.mapCard.heightAnchor constraintEqualToConstant:278.0],
        [self.favoritesCard.topAnchor constraintEqualToAnchor:container.topAnchor],
        [self.favoritesCard.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [self.favoritesCard.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [self.favoritesCard.heightAnchor constraintEqualToConstant:278.0],
        [self.favoritesCard.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
        [favoritesScroll.topAnchor constraintEqualToAnchor:self.favoritesCard.topAnchor constant:12.0],
        [favoritesScroll.bottomAnchor constraintEqualToAnchor:self.favoritesCard.bottomAnchor constant:-12.0],
        [favoritesScroll.leadingAnchor constraintEqualToAnchor:self.favoritesCard.leadingAnchor constant:12.0],
        [favoritesScroll.trailingAnchor constraintEqualToAnchor:self.favoritesCard.trailingAnchor constant:-12.0],
        [self.favoritesList.topAnchor constraintEqualToAnchor:favoritesScroll.contentLayoutGuide.topAnchor],
        [self.favoritesList.bottomAnchor constraintEqualToAnchor:favoritesScroll.contentLayoutGuide.bottomAnchor],
        [self.favoritesList.leadingAnchor constraintEqualToAnchor:favoritesScroll.contentLayoutGuide.leadingAnchor],
        [self.favoritesList.trailingAnchor constraintEqualToAnchor:favoritesScroll.contentLayoutGuide.trailingAnchor],
        [self.favoritesList.widthAnchor constraintEqualToAnchor:favoritesScroll.frameLayoutGuide.widthAnchor],
    ]];
    return container;
}

- (UIButton *)mapOverlayButtonWithSymbol:(NSString *)symbol action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:20.0 weight:UIImageSymbolWeightSemibold];
    [button setImage:[UIImage systemImageNamed:symbol withConfiguration:configuration] forState:UIControlStateNormal];
    button.tintColor = UIColor.whiteColor;
    button.backgroundColor = GPSLabColorFromHex(0x26262C);
    button.layer.cornerRadius = 14.0;
    button.layer.masksToBounds = YES;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [NSLayoutConstraint activateConstraints:@[
        [button.widthAnchor constraintEqualToConstant:46.0],
        [button.heightAnchor constraintEqualToConstant:46.0],
    ]];
    return button;
}

#pragma mark - Control card

- (UIView *)controlCardView {
    self.controlCard = [[UIView alloc] initWithFrame:CGRectZero];
    self.controlCard.backgroundColor = GPSLabThemeCardColor();
    GPSLabThemeApplyCardStyle(self.controlCard, 24.0);

    self.mapFavoritesSegment = [[UISegmentedControl alloc] initWithItems:@[@"", @""]];
    self.mapFavoritesSegment.selectedSegmentIndex = 0;
    self.mapFavoritesSegment.selectedSegmentTintColor = GPSLabThemeAccentColor();
    [self.mapFavoritesSegment addTarget:self action:@selector(mapFavoritesChanged) forControlEvents:UIControlEventValueChanged];

    self.staticRouteSegment = [[UISegmentedControl alloc] initWithItems:@[@"", @""]];
    self.staticRouteSegment.selectedSegmentIndex = 0;
    self.staticRouteSegment.selectedSegmentTintColor = GPSLabThemeAccentColor();
    [self.staticRouteSegment addTarget:self action:@selector(staticRouteChanged) forControlEvents:UIControlEventValueChanged];

    self.coordsTitleLabel = [self themedLabel:13.0 weight:UIFontWeightRegular color:GPSLabThemeMutedColor()];
    self.coordsBigLabel = [self themedLabel:24.0 weight:UIFontWeightSemibold color:GPSLabThemeTextColor()];
    self.coordsBigLabel.numberOfLines = 2;
    [GPSLabLocalization forceLeftToRight:self.coordsBigLabel];

    NSArray<NSString *> *coordKeys = @[@"panel.coord.latitude", @"panel.coord.longitude", @"panel.coord.altitude"];
    NSMutableArray<UILabel *> *coordValues = [NSMutableArray array];
    NSMutableArray<UIView *> *coordBoxes = [NSMutableArray array];
    for (NSString *key in coordKeys) {
        UIView *box = [[UIView alloc] initWithFrame:CGRectZero];
        box.backgroundColor = GPSLabColorFromHex(0x0F0F12);
        box.layer.cornerRadius = 13.0;
        UILabel *caption = [self themedLabel:12.0 weight:UIFontWeightRegular color:GPSLabThemeMutedColor()];
        caption.textAlignment = NSTextAlignmentCenter;
        caption.accessibilityIdentifier = key;
        UILabel *value = [self themedLabel:18.0 weight:UIFontWeightSemibold color:GPSLabThemeTextColor()];
        value.textAlignment = NSTextAlignmentCenter;
        value.adjustsFontSizeToFitWidth = YES;
        value.minimumScaleFactor = 0.6;
        [GPSLabLocalization forceLeftToRight:value];
        [coordValues addObject:value];
        UIStackView *cell = [[UIStackView alloc] initWithArrangedSubviews:@[ caption, value ]];
        cell.axis = UILayoutConstraintAxisVertical;
        cell.spacing = 6.0;
        cell.translatesAutoresizingMaskIntoConstraints = NO;
        [box addSubview:cell];
        [NSLayoutConstraint activateConstraints:@[
            [cell.topAnchor constraintEqualToAnchor:box.topAnchor constant:10.0],
            [cell.bottomAnchor constraintEqualToAnchor:box.bottomAnchor constant:-10.0],
            [cell.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:8.0],
            [cell.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-8.0],
        ]];
        [coordBoxes addObject:box];
    }
    self.coordValueLabels = coordValues;
    UIStackView *coordGrid = [[UIStackView alloc] initWithArrangedSubviews:coordBoxes];
    coordGrid.axis = UILayoutConstraintAxisHorizontal;
    coordGrid.distribution = UIStackViewDistributionFillEqually;
    coordGrid.spacing = 8.0;

    self.headingView = [[GPSLabHeadingView alloc] initWithFrame:CGRectZero];
    self.headingView.translatesAutoresizingMaskIntoConstraints = NO;
    self.headingView.heading = 0.0;
    self.headingValueLabel = [self themedLabel:15.0 weight:UIFontWeightRegular color:GPSLabThemeMutedColor()];
    [GPSLabLocalization forceLeftToRight:self.headingValueLabel];
    [self.headingView.heightAnchor constraintEqualToConstant:28.0].active = YES;
    UIStackView *headingRow = [[UIStackView alloc] initWithArrangedSubviews:@[ self.headingView, self.headingValueLabel ]];
    headingRow.axis = UILayoutConstraintAxisHorizontal;
    headingRow.alignment = UIStackViewAlignmentCenter;
    headingRow.spacing = 12.0;
    [self.headingValueLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    // Toggles
    self.driftSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
    [self.driftSwitch addTarget:self action:@selector(driftChanged) forControlEvents:UIControlEventValueChanged];
    self.keepLastSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
    [self.keepLastSwitch addTarget:self action:@selector(keepLastChanged) forControlEvents:UIControlEventValueChanged];
    self.realLocationSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
    [self.realLocationSwitch addTarget:self action:@selector(realLocationChanged) forControlEvents:UIControlEventValueChanged];

    self.scheduleButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.scheduleButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.scheduleButton.titleLabel.font = GPSLabThemeFont(13.0, UIFontWeightMedium);
    [self.scheduleButton setTitleColor:GPSLabThemeAccentSoftColor() forState:UIControlStateNormal];
    self.scheduleButton.backgroundColor = GPSLabColorFromHex(0x2B2B30);
    self.scheduleButton.layer.cornerRadius = 14.0;
    self.scheduleButton.layer.masksToBounds = YES;
    self.scheduleButton.contentEdgeInsets = UIEdgeInsetsMake(10.0, 14.0, 10.0, 14.0);
    [self.scheduleButton addTarget:self action:@selector(scheduleTapped) forControlEvents:UIControlEventTouchUpInside];

    self.routeSection = [self routeSectionView];

    UIStackView *column = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.mapFavoritesSegment, self.staticRouteSegment,
        self.coordsTitleLabel, self.coordsBigLabel, coordGrid, headingRow,
        [self toggleRowWithKey:@"panel.toggle.drift" control:self.driftSwitch],
        [self toggleRowWithKey:@"panel.toggle.keepLast" control:self.keepLastSwitch],
        [self toggleRowWithKey:@"panel.toggle.realLocation" control:self.realLocationSwitch],
        [self scheduleRowView],
        self.routeSection,
    ]];
    column.axis = UILayoutConstraintAxisVertical;
    column.spacing = 12.0;
    column.translatesAutoresizingMaskIntoConstraints = NO;
    [self.controlCard addSubview:column];
    [NSLayoutConstraint activateConstraints:@[
        [column.topAnchor constraintEqualToAnchor:self.controlCard.topAnchor constant:16.0],
        [column.bottomAnchor constraintEqualToAnchor:self.controlCard.bottomAnchor constant:-16.0],
        [column.leadingAnchor constraintEqualToAnchor:self.controlCard.leadingAnchor constant:16.0],
        [column.trailingAnchor constraintEqualToAnchor:self.controlCard.trailingAnchor constant:-16.0],
    ]];
    return self.controlCard;
}

- (UIStackView *)toggleRowWithKey:(NSString *)key control:(UIView *)control {
    UILabel *label = [self themedLabel:16.0 weight:UIFontWeightRegular color:GPSLabThemeTextColor()];
    label.accessibilityIdentifier = key;
    label.text = GPSLabLocalized(key);
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[ label, [UIView new], control ]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 12.0;
    row.backgroundColor = UIColor.clearColor;
    return row;
}

- (UIView *)scheduleRowView {
    UILabel *label = [self themedLabel:16.0 weight:UIFontWeightSemibold color:GPSLabThemeTextColor()];
    label.accessibilityIdentifier = @"panel.schedule";
    label.text = GPSLabLocalized(@"panel.schedule");
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[ label, [UIView new], self.scheduleButton ]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 16.0;
    return row;
}

- (UIStackView *)routeSectionView {
    self.routeStartLabel = [self themedLabel:14.0 weight:UIFontWeightRegular color:GPSLabThemeMutedColor()];
    self.routeEndLabel = [self themedLabel:14.0 weight:UIFontWeightRegular color:GPSLabThemeMutedColor()];
    UIButton *pickStart = [self pillButtonWithKey:@"route.setStart" action:@selector(pickRouteStart)];
    UIButton *pickEnd = [self pillButtonWithKey:@"route.setEnd" action:@selector(pickRouteEnd)];
    self.routeModeSegment = [[UISegmentedControl alloc] initWithItems:@[@"", @"", @"", @""]];
    self.routeModeSegment.selectedSegmentTintColor = GPSLabThemeAccentColor();
    [self.routeModeSegment addTarget:self action:@selector(routeModeChanged) forControlEvents:UIControlEventValueChanged];
    self.routeSpeedSlider = [[UISlider alloc] initWithFrame:CGRectZero];
    self.routeSpeedSlider.minimumValue = 1.0;
    self.routeSpeedSlider.maximumValue = 300.0;
    self.routeSpeedSlider.value = 50.0;
    [self.routeSpeedSlider addTarget:self action:@selector(routeSpeedChanged) forControlEvents:UIControlEventValueChanged];
    self.routeSpeedValueLabel = [self themedLabel:14.0 weight:UIFontWeightMedium color:GPSLabThemeMutedColor()];
    [GPSLabLocalization forceLeftToRight:self.routeSpeedValueLabel];
    self.routePlayButton = [self pillButtonWithKey:@"route.start" action:@selector(routePlayTapped)];
    self.routeStopButton = [self pillButtonWithKey:@"route.stop" action:@selector(routeStopTapped)];
    UIStackView *playback = [[UIStackView alloc] initWithArrangedSubviews:@[ self.routePlayButton, self.routeStopButton ]];
    playback.axis = UILayoutConstraintAxisHorizontal;
    playback.distribution = UIStackViewDistributionFillEqually;
    playback.spacing = 8.0;
    self.routeStopBehaviorSegment = [[UISegmentedControl alloc] initWithItems:@[@"", @""]];
    self.routeStopBehaviorSegment.selectedSegmentTintColor = GPSLabThemeAccentColor();
    [self.routeStopBehaviorSegment addTarget:self action:@selector(routeStopBehaviorChanged) forControlEvents:UIControlEventValueChanged];

    UIStackView *section = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.routeStartLabel, pickStart, self.routeEndLabel, pickEnd,
        self.routeModeSegment,
        [self sliderRowWithSlider:self.routeSpeedSlider valueLabel:self.routeSpeedValueLabel],
        playback, self.routeStopBehaviorSegment,
    ]];
    section.axis = UILayoutConstraintAxisVertical;
    section.spacing = 10.0;
    section.hidden = YES;
    return section;
}

- (UIStackView *)sliderRowWithSlider:(UISlider *)slider valueLabel:(UILabel *)valueLabel {
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[ slider, valueLabel ]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 10.0;
    [valueLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    return row;
}

- (UIButton *)pillButtonWithKey:(NSString *)key action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setTitle:GPSLabLocalized(key) forState:UIControlStateNormal];
    [button setTitleColor:GPSLabThemeAccentSoftColor() forState:UIControlStateNormal];
    button.titleLabel.font = GPSLabThemeFont(14.0, UIFontWeightSemibold);
    button.accessibilityIdentifier = key;
    button.backgroundColor = GPSLabColorFromHex(0x17171D);
    button.layer.cornerRadius = 12.0;
    button.layer.borderWidth = 0.5;
    button.layer.borderColor = [GPSLabThemeAccentColor() colorWithAlphaComponent:0.35].CGColor;
    button.contentEdgeInsets = UIEdgeInsetsMake(10.0, 10.0, 10.0, 10.0);
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (UILabel *)themedLabel:(CGFloat)size weight:(UIFontWeight)weight color:(UIColor *)color {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.font = GPSLabThemeFont(size, weight);
    label.textColor = color;
    return label;
}

#pragma mark - Modules / actions / subscription

- (UIView *)simulationGroupView {
    UIStackView *group = [[UIStackView alloc] initWithFrame:CGRectZero];
    group.axis = UILayoutConstraintAxisVertical;
    group.spacing = 8.0;
    UILabel *title = [self themedLabel:13.0 weight:UIFontWeightRegular color:GPSLabThemeMutedColor()];
    title.accessibilityIdentifier = @"sim.title";
    title.text = GPSLabLocalized(@"sim.title");
    [group addArrangedSubview:title];
    [group addArrangedSubview:[self simulationRowWithIcon:@"⌁" titleKey:@"sim.wifi.title"
                                                subtitleKey:@"sim.wifi.subtitle" action:@selector(wifiSettingsTapped)]];
    [group addArrangedSubview:[self simulationRowWithIcon:@"ᛒ" titleKey:@"sim.ble.title"
                                                subtitleKey:@"sim.ble.subtitle" action:@selector(bleSettingsTapped)]];
    return group;
}

- (UIView *)simulationRowWithIcon:(NSString *)icon titleKey:(NSString *)titleKey
                      subtitleKey:(NSString *)subtitleKey action:(SEL)action {
    UIView *row = [[UIView alloc] initWithFrame:CGRectZero];
    UILabel *iconLabel = [self themedLabel:18.0 weight:UIFontWeightRegular color:GPSLabThemeTextColor()];
    iconLabel.text = icon;
    iconLabel.textAlignment = NSTextAlignmentCenter;
    iconLabel.translatesAutoresizingMaskIntoConstraints = NO;
    iconLabel.backgroundColor = GPSLabColorFromHex(0x101014);
    iconLabel.layer.cornerRadius = 12.0;
    iconLabel.layer.masksToBounds = YES;
    iconLabel.layer.borderWidth = 0.5;
    iconLabel.layer.borderColor = GPSLabThemeBorderColor().CGColor;
    UILabel *title = [self themedLabel:16.0 weight:UIFontWeightSemibold color:GPSLabThemeTextColor()];
    title.accessibilityIdentifier = titleKey;
    title.text = GPSLabLocalized(titleKey);
    UILabel *subtitle = [self themedLabel:12.0 weight:UIFontWeightRegular color:GPSLabThemeMutedColor()];
    subtitle.accessibilityIdentifier = subtitleKey;
    subtitle.text = GPSLabLocalized(subtitleKey);
    UIStackView *texts = [[UIStackView alloc] initWithArrangedSubviews:@[ title, subtitle ]];
    texts.axis = UILayoutConstraintAxisVertical;
    texts.spacing = 3.0;
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:GPSLabLocalized(@"sim.configure") forState:UIControlStateNormal];
    button.titleLabel.font = GPSLabThemeFont(13.0, UIFontWeightSemibold);
    button.accessibilityIdentifier = @"sim.configure";
    [button setTitleColor:GPSLabThemeAccentSoftColor() forState:UIControlStateNormal];
    button.backgroundColor = GPSLabColorFromHex(0x17171D);
    button.layer.cornerRadius = 11.0;
    button.layer.borderWidth = 0.5;
    button.layer.borderColor = [GPSLabThemeAccentColor() colorWithAlphaComponent:0.35].CGColor;
    button.contentEdgeInsets = UIEdgeInsetsMake(8.0, 10.0, 8.0, 10.0);
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [texts setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];

    [row addSubview:iconLabel];
    [row addSubview:texts];
    [row addSubview:button];
    iconLabel.translatesAutoresizingMaskIntoConstraints = NO;
    texts.translatesAutoresizingMaskIntoConstraints = NO;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [iconLabel.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [iconLabel.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [iconLabel.widthAnchor constraintEqualToConstant:38.0],
        [iconLabel.heightAnchor constraintEqualToConstant:38.0],
        [texts.leadingAnchor constraintEqualToAnchor:iconLabel.trailingAnchor constant:10.0],
        [texts.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [button.leadingAnchor constraintGreaterThanOrEqualToAnchor:texts.trailingAnchor constant:10.0],
        [button.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [button.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [row.topAnchor constraintEqualToAnchor:iconLabel.topAnchor constant:-10.0],
        [row.bottomAnchor constraintEqualToAnchor:iconLabel.bottomAnchor constant:10.0],
    ]];
    return row;
}

- (UIView *)actionsView {
    self.cancelButton = [self actionButtonWithKey:@"common.cancel" gradient:NO action:@selector(cancelTapped)];
    self.applyButton = [self actionButtonWithKey:@"panel.actions.apply" gradient:YES action:@selector(applyTapped)];
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[ self.cancelButton, self.applyButton ]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.distribution = UIStackViewDistributionFillEqually;
    row.spacing = 12.0;
    return row;
}

- (UIButton *)actionButtonWithKey:(NSString *)key gradient:(BOOL)gradient action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:GPSLabLocalized(key) forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.titleLabel.font = GPSLabThemeFont(17.0, UIFontWeightBold);
    button.layer.cornerRadius = 16.0;
    button.layer.masksToBounds = YES;
    if (gradient) {
        CAGradientLayer *layer = GPSLabThemeAccentGradient();
        layer.frame = CGRectMake(0.0, 0.0, 220.0, 52.0);
        [button.layer insertSublayer:layer atIndex:0];
    } else {
        button.backgroundColor = GPSLabColorFromHex(0x2B2B30);
    }
    button.contentEdgeInsets = UIEdgeInsetsMake(15.0, 15.0, 15.0, 15.0);
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (UIView *)subscriptionCardView {
    self.subscriptionCard = [[UIView alloc] initWithFrame:CGRectZero];
    self.subscriptionCard.backgroundColor = UIColor.clearColor;
    self.subscriptionTitleLabel = [self themedLabel:17.0 weight:UIFontWeightSemibold color:GPSLabThemeTextColor()];
    self.subscriptionStatusLabel = [self themedLabel:12.0 weight:UIFontWeightBold color:GPSLabThemeGreenColor()];
    self.subscriptionStatusLabel.textAlignment = NSTextAlignmentCenter;
    self.subscriptionStatusLabel.layer.cornerRadius = 999.0;
    self.subscriptionStatusLabel.layer.masksToBounds = YES;    UIStackView *head = [[UIStackView alloc] initWithArrangedSubviews:@[ self.subscriptionTitleLabel, [UIView new], self.subscriptionStatusLabel ]];
    head.axis = UILayoutConstraintAxisHorizontal;
    head.alignment = UIStackViewAlignmentCenter;
    head.spacing = 12.0;

    self.subscriptionPlanCaption = [self themedLabel:12.0 weight:UIFontWeightRegular color:GPSLabThemeMutedColor()];
    self.subscriptionPlanValue = [self themedLabel:15.0 weight:UIFontWeightSemibold color:GPSLabThemeTextColor()];
    self.subscriptionExpiryCaption = [self themedLabel:12.0 weight:UIFontWeightRegular color:GPSLabThemeMutedColor()];
    self.subscriptionExpiryValue = [self themedLabel:15.0 weight:UIFontWeightSemibold color:GPSLabThemeTextColor()];
    UIStackView *plan = [self subscriptionCellWithCaption:self.subscriptionPlanCaption value:self.subscriptionPlanValue];
    UIStackView *expiry = [self subscriptionCellWithCaption:self.subscriptionExpiryCaption value:self.subscriptionExpiryValue];
    UIStackView *grid = [[UIStackView alloc] initWithArrangedSubviews:@[ plan, expiry ]];
    grid.axis = UILayoutConstraintAxisHorizontal;
    grid.distribution = UIStackViewDistributionFillEqually;
    grid.spacing = 8.0;

    self.installationLabel = [self themedLabel:11.0 weight:UIFontWeightRegular color:GPSLabThemeMutedColor()];
    self.installationLabel.numberOfLines = 2;
    self.installationLabel.textAlignment = NSTextAlignmentCenter;
    [GPSLabLocalization forceLeftToRight:self.installationLabel];

    UIStackView *column = [[UIStackView alloc] initWithArrangedSubviews:@[ head, grid, self.installationLabel ]];
    column.axis = UILayoutConstraintAxisVertical;
    column.spacing = 10.0;
    column.translatesAutoresizingMaskIntoConstraints = NO;
    [self.subscriptionCard addSubview:column];
    [NSLayoutConstraint activateConstraints:@[
        [column.topAnchor constraintEqualToAnchor:self.subscriptionCard.topAnchor constant:14.0],
        [column.bottomAnchor constraintEqualToAnchor:self.subscriptionCard.bottomAnchor constant:-4.0],
        [column.leadingAnchor constraintEqualToAnchor:self.subscriptionCard.leadingAnchor],
        [column.trailingAnchor constraintEqualToAnchor:self.subscriptionCard.trailingAnchor],
    ]];
    return self.subscriptionCard;
}

- (UIStackView *)subscriptionCellWithCaption:(UILabel *)caption value:(UILabel *)value {
    UIView *box = [[UIView alloc] initWithFrame:CGRectZero];
    box.backgroundColor = GPSLabColorFromHex(0x0F0F12);
    box.layer.cornerRadius = 12.0;
    UIStackView *cell = [[UIStackView alloc] initWithArrangedSubviews:@[ caption, value ]];
    cell.axis = UILayoutConstraintAxisVertical;
    cell.spacing = 4.0;
    cell.translatesAutoresizingMaskIntoConstraints = NO;
    [box addSubview:cell];
    [NSLayoutConstraint activateConstraints:@[
        [cell.topAnchor constraintEqualToAnchor:box.topAnchor constant:10.0],
        [cell.bottomAnchor constraintEqualToAnchor:box.bottomAnchor constant:-10.0],
        [cell.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:10.0],
        [cell.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-10.0],
    ]];
    UIStackView *wrapper = [[UIStackView alloc] initWithArrangedSubviews:@[ box ]];
    wrapper.axis = UILayoutConstraintAxisVertical;
    return wrapper;
}

#pragma mark - Configuration into UI

- (void)loadConfigurationIntoUI {
    GPSLabConfiguration *configuration = [[GPSLabEngine sharedEngine] configuration];
    self.driftSwitch.on = configuration.driftEnabled;
    self.keepLastSwitch.on = configuration.keepLastCoordinate;
    self.routeSpeedSlider.value = configuration.routeCustomSpeedKmh > 0.0 ? configuration.routeCustomSpeedKmh : 50.0;
    self.routeModeSegment.selectedSegmentIndex = (NSInteger)configuration.routeMode;
    self.routeStopBehaviorSegment.selectedSegmentIndex = (NSInteger)configuration.stopBehavior;
    [self applyMapStyle:self.mapStyle];
    [self updateStatusLabel];
    [self updateMapFromState];
    [self updateMasterAppearance];
    [self updateRouteControls];
    [self updateSubscriptionCard];
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

- (void)languageDidChange:(NSNotification *)notification {
    (void)notification;
    [self applyLocalization];
}

- (void)applyLocalization {
    UIView *scope = self.view.window ?: self.view;
    [GPSLabLocalization applyLanguageAttributesToView:scope];
    [GPSLabLocalization forceLeftToRight:self.mapView];
    [GPSLabLocalization forceLeftToRight:self.coordsBigLabel];
    [GPSLabLocalization forceLeftToRight:self.headingValueLabel];
    for (UILabel *label in self.coordValueLabels) {
        [GPSLabLocalization forceLeftToRight:label];
    }

    self.languageButton.accessibilityLabel = GPSLabLocalized(@"overlay.accessibility.language");
    [self.languageButton setTitle:([GPSLabLocalization currentLanguage] == GPSLabLanguageEnglish) ? @"AR" : @"EN"
                         forState:UIControlStateNormal];
    self.infoButton.accessibilityLabel = GPSLabLocalized(@"overlay.info");
    self.headerTitleLabel.text = GPSLabLocalized(@"overlay.title");
    self.headerSubtitleLabel.text = GPSLabLocalized(@"overlay.subtitle");
    self.closeButton.accessibilityLabel = GPSLabLocalized(@"common.close");
    [self updateMasterAppearance];

    self.searchBar.placeholder = GPSLabLocalized(@"overlay.search.placeholder");
    self.searchBar.accessibilityLabel = GPSLabLocalized(@"overlay.search.placeholder");

    [self.mapFavoritesSegment setTitle:GPSLabLocalized(@"panel.tab.map") forSegmentAtIndex:0];
    [self.mapFavoritesSegment setTitle:GPSLabLocalized(@"panel.tab.favorites") forSegmentAtIndex:1];
    [self.staticRouteSegment setTitle:GPSLabLocalized(@"panel.tab.static") forSegmentAtIndex:0];
    [self.staticRouteSegment setTitle:GPSLabLocalized(@"panel.tab.route") forSegmentAtIndex:1];
    self.coordsTitleLabel.text = GPSLabLocalized(@"panel.coords.title");

    for (UIView *view in self.bodyStack.arrangedSubviews) {
        [self localizeSubtree:view];
    }
    [self.routeModeSegment setTitle:GPSLabLocalized(@"route.mode.driving") forSegmentAtIndex:0];
    [self.routeModeSegment setTitle:GPSLabLocalized(@"route.mode.walking") forSegmentAtIndex:1];
    [self.routeModeSegment setTitle:GPSLabLocalized(@"route.mode.cycling") forSegmentAtIndex:2];
    [self.routeModeSegment setTitle:GPSLabLocalized(@"route.mode.custom") forSegmentAtIndex:3];
    [self.routeStopBehaviorSegment setTitle:GPSLabLocalized(@"route.stop.stay") forSegmentAtIndex:0];
    [self.routeStopBehaviorSegment setTitle:GPSLabLocalized(@"route.stop.return") forSegmentAtIndex:1];
    [self.routePlayButton setTitle:GPSLabLocalized(@"route.start") forState:UIControlStateNormal];
    [self.routeStopButton setTitle:GPSLabLocalized(@"route.stop") forState:UIControlStateNormal];
    [self.cancelButton setTitle:GPSLabLocalized(@"common.cancel") forState:UIControlStateNormal];
    [self.applyButton setTitle:GPSLabLocalized(@"panel.actions.apply") forState:UIControlStateNormal];

    self.subscriptionTitleLabel.text = GPSLabLocalized(@"subscription.compact.title");
    self.subscriptionPlanCaption.text = GPSLabLocalized(@"subscription.compact.plan");
    self.subscriptionExpiryCaption.text = GPSLabLocalized(@"subscription.compact.expiry");
    self.installationLabel.text = [NSString stringWithFormat:@"%@\n%@",
                                   GPSLabLocalized(@"subscription.compact.installation"),
                                   [self installationIdentifierDisplay]];
    [self updateSubscriptionCard];
    [self.profilesPanel applyLocalization];
    [self updateScheduleDisplay:[self selectedProfile].schedule];
    [self updateFavoritesList];
}

- (void)localizeSubtree:(UIView *)view {
    if (view.accessibilityIdentifier.length > 0) {
        NSString *key = view.accessibilityIdentifier;
        if ([view isKindOfClass:[UILabel class]]) {
            ((UILabel *)view).text = GPSLabLocalized(key);
        } else if ([view isKindOfClass:[UIButton class]]) {
            [(UIButton *)view setTitle:GPSLabLocalized(key) forState:UIControlStateNormal];
        }
    }
    for (UIView *sub in view.subviews) {
        [self localizeSubtree:sub];
    }
}

#pragma mark - Master / actions

- (void)updateMasterAppearance {
    BOOL enabled = [GPSLabEngine sharedEngine].isEnabled;
    self.masterDot.backgroundColor = enabled ? GPSLabThemeGreenColor() : GPSLabThemeRedColor();
    self.masterDot.layer.shadowColor = (enabled ? GPSLabThemeGreenColor() : GPSLabThemeRedColor()).CGColor;
    self.masterDot.layer.shadowOpacity = 0.75;
    self.masterDot.layer.shadowRadius = 6.0;
    self.masterDot.layer.shadowOffset = CGSizeZero;
    self.masterButton.accessibilityLabel = enabled ? GPSLabLocalized(@"overlay.accessibility.master.enabled")
                                                  : GPSLabLocalized(@"overlay.accessibility.master.disabled");
    self.masterButton.accessibilityHint = GPSLabLocalized(@"overlay.enabled");
    [self updateStatusLabel];
}

- (void)masterTapped {
    BOOL next = ![GPSLabEngine sharedEngine].isEnabled;
    if (!next) {
        [[GPSLabScheduler sharedScheduler] noteManualEngineDisable];
    }
    [[GPSLabEngine sharedEngine] setEnabledAndNotify:next];
    [GPSLabStatusLog append:(next ? GPSLabLocalized(@"overlay.engine.enabled")
                                  : GPSLabLocalized(@"overlay.engine.disabled"))];
    [self updateMasterAppearance];
}

- (void)infoTapped {
    [self presentOptionsSheet];
}

- (void)languageTapped {
    GPSLabLanguageCode next = ([GPSLabLocalization currentLanguage] == GPSLabLanguageEnglish)
        ? GPSLabLanguageArabic : GPSLabLanguageEnglish;
    [GPSLabLocalization setLanguage:next];
}

- (void)closeTapped {
    [[GPSLabScheduler sharedScheduler] cancelPending];
    [[GPSLabProfileApplicationCoordinator sharedCoordinator] cancelPendingApplication];
    [[GPSLabOverlayPresenter sharedPresenter] dismissOverlay];
}

- (void)centerTapped {
    CLLocationCoordinate2D coordinate = [[GPSLabEngine sharedEngine] baseCoordinate];
    [self.mapView setRegion:MKCoordinateRegionMakeWithDistance(coordinate, 800.0, 800.0) animated:YES];
}

- (void)bookmarkTapped {
    GPSLabConfiguration *configuration = [[GPSLabEngine sharedEngine] configuration];
    GPSLabBookmark *bookmark = [GPSLabBookmark bookmarkWithName:GPSLabLocalized(@"favorites.defaultName")
                                                      coordinate:configuration.coordinate
                                                        altitude:configuration.altitude];
    [[GPSLabStore sharedStore] addBookmark:bookmark];
    [GPSLabStatusLog append:GPSLabLocalized(@"profiles.ready")];
    [self updateFavoritesList];
}

- (void)mapFavoritesChanged {
    [self updateTabVisibility];
}

- (void)staticRouteChanged {
    [self updateTabVisibility];
}

- (void)updateTabVisibility {
    BOOL favorites = self.mapFavoritesSegment.selectedSegmentIndex == 1;
    self.mapCard.hidden = favorites;
    self.favoritesCard.hidden = !favorites;
    self.routeSection.hidden = self.staticRouteSegment.selectedSegmentIndex != 1;
    if (favorites) {
        [self updateFavoritesList];
    }
}

- (void)driftChanged {
    [[GPSLabEngine sharedEngine] setDriftEnabled:self.driftSwitch.on];
    [[GPSLabEngine sharedEngine] setDriftRadiusMeters:[[GPSLabEngine sharedEngine] driftRadiusMeters]];
    [self updateStatusLabel];
}

- (void)keepLastChanged {
    [[GPSLabEngine sharedEngine] setKeepLastCoordinate:self.keepLastSwitch.on];
}

- (void)realLocationChanged {
    [self setRealLocationDisplayEnabled:self.realLocationSwitch.on];
}

- (void)scheduleTapped {
    GPSLabProfile *selected = [self selectedProfile];
    GPSLabScheduleViewController *sheet = [[GPSLabScheduleViewController alloc] init];
    sheet.schedule = selected.schedule;
    GPSLabOverlayViewController *__weak weakSelf = self;
    sheet.saveHandler = ^BOOL(GPSLabProfileSchedule * _Nullable schedule) {
        GPSLabOverlayViewController *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return NO;
        }
        return [strongSelf attachSchedule:schedule];
    };
    [[GPSLabModalCoordinator sharedCoordinator] presentSheetRoot:sheet completion:nil];
}

- (BOOL)attachSchedule:(nullable GPSLabProfileSchedule *)schedule {
    GPSLabProfile *selected = [self selectedProfile];
    if (selected == nil) {
        // No profile selected: reflect the change on the live candidate only.
        [self updateScheduleDisplay:schedule];
        return YES;
    }
    GPSLabProfile *updated = [selected profileWithWiFi:selected.wifi bluetooth:selected.bluetooth schedule:schedule];
    NSError *error = nil;
    if (![[GPSLabProfileStore sharedStore] updateProfile:updated error:&error]) {
        [self presentErrorKey:@"profiles.error.save"];
        return NO;
    }
    self.selectedProfileIdentifier = updated.identifier;
    [self reloadProfiles];
    [self rearmAppliedProfileIfNeeded:updated];
    return YES;
}

- (void)updateScheduleDisplay:(nullable GPSLabProfileSchedule *)schedule {
    if (schedule == nil) {
        [self.scheduleButton setTitle:GPSLabLocalized(@"panel.schedule.none") forState:UIControlStateNormal];
        return;
    }
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateStyle = NSDateFormatterShortStyle;
    formatter.timeStyle = NSDateFormatterShortStyle;
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)schedule.startEpoch];
    [self.scheduleButton setTitle:[formatter stringFromDate:date] forState:UIControlStateNormal];
}

- (void)applyTapped {
    if (self.staticRouteSegment.selectedSegmentIndex == 1) {
        [self startRouteFromPending];
        return;
    }
    GPSLabConfiguration *configuration = [[GPSLabEngine sharedEngine] configuration];
    [self applyCoordinate:configuration.coordinate altitude:configuration.altitude heading:configuration.heading];
    [self endActiveSearch];
}

- (void)cancelTapped {
    [self endActiveSearch];
    [self loadConfigurationIntoUI];
    [self updateTabVisibility];
}

#pragma mark - Profiles

- (void)reloadProfiles {
    GPSLabProfileStore *store = [GPSLabProfileStore sharedStore];
    self.profiles = [store loadProfiles];
    NSString *selected = [store selectedProfileIdentifier];
    if (selected == nil && self.profiles.count > 0) {
        selected = self.selectedProfileIdentifier ?: self.profiles.firstObject.identifier;
    }
    if (selected.length > 0 && ![self profileWithIdentifier:selected]) {
        selected = self.profiles.firstObject.identifier;
    }
    self.selectedProfileIdentifier = selected;
    [self.profilesPanel setProfiles:self.profiles selectedIdentifier:selected];
    [self updateScheduleDisplay:[self selectedProfile].schedule];
}

- (GPSLabProfile *)profileWithIdentifier:(NSString *)identifier {
    for (GPSLabProfile *profile in self.profiles) {
        if ([profile.identifier isEqualToString:identifier]) {
            return profile;
        }
    }
    return nil;
}

- (GPSLabProfile *)selectedProfile {
    if (self.selectedProfileIdentifier.length > 0) {
        return [self profileWithIdentifier:self.selectedProfileIdentifier];
    }
    return self.profiles.firstObject;
}

- (GPSLabProfile *)candidateProfileFromCurrentState {
    GPSLabConfiguration *configuration = [[GPSLabEngine sharedEngine] configuration];
    GPSLabProfileRoute *route = nil;
    if (self.pendingRouteStartItem != nil && self.pendingRouteEndItem != nil) {
        route = [[GPSLabProfileRoute alloc] initWithStartLatitude:self.pendingRouteStartItem.placemark.coordinate.latitude
                                                  startLongitude:self.pendingRouteStartItem.placemark.coordinate.longitude
                                                    endLatitude:self.pendingRouteEndItem.placemark.coordinate.latitude
                                                  endLongitude:self.pendingRouteEndItem.placemark.coordinate.longitude
                                                        altitude:configuration.altitude
                                                         heading:configuration.heading
                                                            mode:(GPSLabRouteMode)self.routeModeSegment.selectedSegmentIndex
                                                  customSpeedKmh:self.routeSpeedSlider.value];
    }
    return [[GPSLabProfile alloc] initWithIdentifier:[[NSUUID UUID] UUIDString]
                                                name:@""
                                        locationMode:(route != nil ? GPSLabProfileLocationRoute
                                                                   : GPSLabProfileLocationStatic)
                                           latitude:configuration.latitude
                                          longitude:configuration.longitude
                                           altitude:configuration.altitude
                                            heading:configuration.heading
                                       driftEnabled:configuration.driftEnabled
                                  driftRadiusMeters:configuration.driftRadiusMeters
                                              route:route
                                               wifi:nil
                                          bluetooth:nil
                                           schedule:[self selectedProfile].schedule];
}

- (void)presentProfileFormForProfile:(nullable GPSLabProfile *)profile {
    GPSLabProfileFormViewController *form = [[GPSLabProfileFormViewController alloc] init];
    form.existingProfile = profile;
    form.candidateProfile = profile ?: [self candidateProfileFromCurrentState];
    GPSLabOverlayViewController *__weak weakSelf = self;
    form.saveHandler = ^BOOL(GPSLabProfile *saved) {
        GPSLabOverlayViewController *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return NO;
        }
        return [strongSelf saveProfileFromForm:saved editing:(profile != nil)];
    };
    form.deleteHandler = ^{
        [weakSelf deleteProfile:profile];
    };
    [[GPSLabModalCoordinator sharedCoordinator] presentSheetRoot:form completion:nil];
}

- (BOOL)saveProfileFromForm:(GPSLabProfile *)profile editing:(BOOL)editing {
    GPSLabProfileStore *store = [GPSLabProfileStore sharedStore];
    NSError *error = nil;
    BOOL success = editing ? [store updateProfile:profile error:&error]
                           : [store addProfile:profile error:&error];
    if (!success) {
        [self presentErrorKey:(error.code == GPSLabProfileStoreErrorCapacity
                              ? @"profiles.error.capacity" : @"profiles.error.save")];
        return NO;
    }
    self.selectedProfileIdentifier = profile.identifier;
    [store setSelectedProfileIdentifier:profile.identifier error:NULL];
    [self reloadProfiles];
    [self rearmAppliedProfileIfNeeded:profile];
    return YES;
}

- (void)deleteProfile:(nullable GPSLabProfile *)profile {
    if (profile == nil) {
        return;
    }
    GPSLabProfileStore *store = [GPSLabProfileStore sharedStore];
    NSError *error = nil;
    if (![store deleteProfileWithIdentifier:profile.identifier error:&error]) {
        [self presentErrorKey:@"profiles.error.notFound"];
        return;
    }
    if ([self.appliedProfileIdentifier isEqualToString:profile.identifier]) {
        self.appliedProfileIdentifier = nil;
        [[GPSLabScheduler sharedScheduler] cancelPending];
        [[GPSLabProfileApplicationCoordinator sharedCoordinator] invalidateAppliedProfile];
    }
    self.selectedProfileIdentifier = nil;
    [self reloadProfiles];
}

- (void)selectProfile:(GPSLabProfile *)profile {
    // Browsing a chip is not an application: it must not disturb a running route
    // or a pending schedule.
    self.selectedProfileIdentifier = profile.identifier;
    [[GPSLabProfileStore sharedStore] setSelectedProfileIdentifier:profile.identifier error:NULL];
    [self.profilesPanel setProfiles:self.profiles selectedIdentifier:profile.identifier];
    [self updateScheduleDisplay:profile.schedule];
}

- (void)applyProfile:(GPSLabProfile *)profile {
    GPSLabProfileApplicationCoordinator *coordinator = [GPSLabProfileApplicationCoordinator sharedCoordinator];
    __weak GPSLabOverlayViewController *weakSelf = self;
    [coordinator applyProfile:profile completion:^(GPSLabProfileApplicationResult *result) {
        GPSLabOverlayViewController *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        if (!result.applied) {
            [strongSelf presentErrorKey:result.messageKey ?: @"profiles.error.invalid"];
            return;
        }
        strongSelf.appliedProfileIdentifier = profile.identifier;
        [[GPSLabScheduler sharedScheduler] armWithProfile:profile];
        [strongSelf loadConfigurationIntoUI];
        [strongSelf updateMapFromState];
        [strongSelf scheduleBackgroundSnapshot];
    }];
}

/** Re-arms the scheduler ONLY when the edited profile is the applied one. */
- (void)rearmAppliedProfileIfNeeded:(GPSLabProfile *)profile {
    if (profile == nil) {
        return;
    }
    if ([profile.identifier isEqualToString:self.appliedProfileIdentifier ?: @""]) {
        [[GPSLabScheduler sharedScheduler] cancelPending];
        [[GPSLabScheduler sharedScheduler] armWithProfile:profile];
    }
}

- (void)presentErrorKey:(NSString *)key {
    NSString *message = GPSLabLocalized(key);
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:GPSLabLocalized(@"profiles.title")
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:GPSLabLocalized(@"common.ok")
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [[GPSLabModalCoordinator sharedCoordinator] presentAlert:alert completion:nil];
}

- (void)updateFavoritesList {
    for (UIView *view in self.favoritesList.arrangedSubviews) {
        [view removeFromSuperview];
    }
    NSArray<GPSLabBookmark *> *bookmarks = [[GPSLabStore sharedStore] loadBookmarks];
    if (bookmarks.count == 0) {
        UILabel *empty = [self themedLabel:14.0 weight:UIFontWeightRegular color:GPSLabThemeMutedColor()];
        empty.text = GPSLabLocalized(@"favorites.empty");
        empty.numberOfLines = 0;
        [self.favoritesList addArrangedSubview:empty];
        return;
    }
    for (NSUInteger index = 0; index < bookmarks.count; index++) {
        GPSLabBookmark *bookmark = bookmarks[index];
        UIButton *row = [UIButton buttonWithType:UIButtonTypeSystem];
        [row setTitle:[NSString stringWithFormat:@"%@  %@", bookmark.name,
                       [GPSLabLocalization coordinateStringWithLatitude:bookmark.latitude
                                                               longitude:bookmark.longitude]]
             forState:UIControlStateNormal];
        // Locale-aware: leading resolves to the right edge in Arabic RTL.
        row.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
        row.titleLabel.font = GPSLabThemeFont(14.0, UIFontWeightMedium);
        [row setTitleColor:GPSLabThemeTextColor() forState:UIControlStateNormal];
        row.tag = (NSInteger)index;
        [row addTarget:self action:@selector(favoriteTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.favoritesList addArrangedSubview:row];
    }
}

- (void)favoriteTapped:(UIButton *)sender {
    NSArray<GPSLabBookmark *> *bookmarks = [[GPSLabStore sharedStore] loadBookmarks];
    if (sender.tag < 0 || (NSUInteger)sender.tag >= bookmarks.count) {
        return;
    }
    GPSLabBookmark *bookmark = bookmarks[(NSUInteger)sender.tag];
    [self applyCoordinate:CLLocationCoordinate2DMake(bookmark.latitude, bookmark.longitude)
                 altitude:bookmark.altitude];
    [self updateFavoritesList];
}

#pragma mark - Modules

- (void)wifiSettingsTapped {
    GPSLabProfile *selected = [self selectedProfile];
    GPSLabSimulationSettingsViewController *sheet = [[GPSLabSimulationSettingsViewController alloc] init];
    sheet.kind = GPSLabSimulationKindWiFi;
    sheet.wifiConfig = selected.wifi;
    GPSLabOverlayViewController *__weak weakSelf = self;
    sheet.saveWiFiHandler = ^BOOL(GPSLabProfileWiFiConfig *config) {
        GPSLabOverlayViewController *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return NO;
        }
        return [strongSelf attachWiFi:config bluetooth:nil];
    };
    [[GPSLabModalCoordinator sharedCoordinator] presentSheetRoot:sheet completion:nil];
}

- (void)bleSettingsTapped {
    GPSLabProfile *selected = [self selectedProfile];
    GPSLabSimulationSettingsViewController *sheet = [[GPSLabSimulationSettingsViewController alloc] init];
    sheet.kind = GPSLabSimulationKindBluetooth;
    sheet.bluetoothConfig = selected.bluetooth;
    GPSLabOverlayViewController *__weak weakSelf = self;
    sheet.saveBluetoothHandler = ^BOOL(GPSLabProfileBluetoothConfig *config) {
        GPSLabOverlayViewController *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return NO;
        }
        return [strongSelf attachWiFi:nil bluetooth:config];
    };
    [[GPSLabModalCoordinator sharedCoordinator] presentSheetRoot:sheet completion:nil];
}

- (BOOL)attachWiFi:(nullable GPSLabProfileWiFiConfig *)wifi
         bluetooth:(nullable GPSLabProfileBluetoothConfig *)bluetooth {
    GPSLabProfile *selected = [self selectedProfile];
    if (selected == nil) {
        return NO;
    }
    GPSLabProfile *updated = [selected profileWithWiFi:wifi ?: selected.wifi
                                             bluetooth:bluetooth ?: selected.bluetooth
                                              schedule:selected.schedule];
    NSError *error = nil;
    if (![[GPSLabProfileStore sharedStore] updateProfile:updated error:&error]) {
        [self presentErrorKey:@"profiles.error.save"];
        return NO;
    }
    self.selectedProfileIdentifier = updated.identifier;
    [self reloadProfiles];
    [self rearmAppliedProfileIfNeeded:updated];
    return YES;
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
        weakSelf.driftSwitch.on = enabled;
        [weakSelf updateStatusLabel];
    };
    [[GPSLabModalCoordinator sharedCoordinator] presentSheetRoot:sheet completion:nil];
}

- (void)presentOptionsSheet {
    GPSLabConfiguration *configuration = [[GPSLabEngine sharedEngine] configuration];
    GPSLabOptionsViewController *options = [[GPSLabOptionsViewController alloc] init];
    options.keepLastCoordinate = configuration.keepLastCoordinate;
    options.realLocationEnabled = self.realLocationDisplayEnabled;
    options.mapStyle = self.mapStyle;
    options.engineEnabled = [GPSLabEngine sharedEngine].isEnabled;
    options.subscriptionStatusText = ([[GPSLabLicenseManager sharedManager] state] == GPSLabEntitlementStateGrace)
        ? GPSLabLocalized(@"subscription.grace") : nil;
    GPSLabOverlayViewController *__weak weakSelf = self;
    options.keepLastHandler = ^(BOOL keepLast) {
        [[GPSLabEngine sharedEngine] setKeepLastCoordinate:keepLast];
        weakSelf.keepLastSwitch.on = keepLast;
    };
    options.realLocationHandler = ^(BOOL enabled) {
        weakSelf.realLocationSwitch.on = enabled;
        [weakSelf setRealLocationDisplayEnabled:enabled];
    };
    options.mapStyleHandler = ^(NSInteger style) { [weakSelf applyMapStyle:style]; };
    options.engineEnabledHandler = ^(BOOL enabled) {
        weakSelf.masterButton.enabled = YES;
        if (!enabled) {
            [[GPSLabScheduler sharedScheduler] noteManualEngineDisable];
        }
        [[GPSLabEngine sharedEngine] setEnabledAndNotify:enabled];
        [weakSelf updateMasterAppearance];
    };
    options.manualEntryHandler = ^{
        GPSLabOverlayViewController *strongSelf = weakSelf;
        if (strongSelf == nil) { return; }
        [[GPSLabModalCoordinator sharedCoordinator] dismissTopmostAnimated:YES completion:^{
            [strongSelf presentManualEntrySheet];
        }];
    };
    options.recentsHandler = ^{
        GPSLabOverlayViewController *strongSelf = weakSelf;
        if (strongSelf == nil) { return; }
        [[GPSLabModalCoordinator sharedCoordinator] dismissTopmostAnimated:YES completion:^{
            [strongSelf presentRecentsSheet];
        }];
    };
    options.fluctuationHandler = ^{
        GPSLabOverlayViewController *strongSelf = weakSelf;
        if (strongSelf == nil) { return; }
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
    // A manual anchor change invalidates any scheduled ownership.
    [[GPSLabProfileApplicationCoordinator sharedCoordinator] invalidateAppliedProfile];
    [self updateStatusLabel];
    [self updateMapFromState];
    [self scheduleBackgroundSnapshot];
}

- (void)updateMapFromState {
    CLLocationCoordinate2D anchor = [[GPSLabEngine sharedEngine] baseCoordinate];
    self.syntheticAnnotation.coordinate = anchor;
}

#pragma mark - Route

- (void)pickRouteStart {
    self.reopenRouteAfterPick = NO;
    self.pickMode = GPSLabMapPickModeRouteStart;
    [self updatePickBanner];
}

- (void)pickRouteEnd {
    self.reopenRouteAfterPick = NO;
    self.pickMode = GPSLabMapPickModeRouteEnd;
    [self updatePickBanner];
}

- (void)updatePickBanner {
    if (self.pickMode == GPSLabMapPickModeNone) {
        self.pickBannerLabel.hidden = YES;
        return;
    }
    self.pickBannerLabel.text = (self.pickMode == GPSLabMapPickModeRouteStart)
        ? GPSLabLocalized(@"overlay.pick.start") : GPSLabLocalized(@"overlay.pick.end");
    self.pickBannerLabel.hidden = NO;
}

- (void)updateRouteControls {
    self.routeStartLabel.text = (self.pendingRouteStartItem != nil)
        ? [NSString stringWithFormat:GPSLabLocalized(@"route.startLabel.format"), self.pendingRouteStartItem.name]
        : GPSLabLocalized(@"route.startLabel");
    self.routeEndLabel.text = (self.pendingRouteEndItem != nil)
        ? [NSString stringWithFormat:GPSLabLocalized(@"route.endLabel.format"), self.pendingRouteEndItem.name]
        : GPSLabLocalized(@"route.endLabel");
    GPSLabRouteState state = [[[GPSLabEngine sharedEngine] routeSimulator] state];
    [self.routePlayButton setTitle:(state == GPSLabRouteStatePaused ? GPSLabLocalized(@"route.pauseResume")
                                                                   : GPSLabLocalized(@"route.start"))
                          forState:UIControlStateNormal];
    self.routeSpeedValueLabel.text = [NSString stringWithFormat:@"%.0f km/h", self.routeSpeedSlider.value];
}

- (void)routeModeChanged {
    GPSLabConfiguration *configuration = [[GPSLabEngine sharedEngine] configuration];
    configuration.routeMode = (GPSLabRouteMode)self.routeModeSegment.selectedSegmentIndex;
    [[GPSLabEngine sharedEngine] applyConfiguration:configuration];
}

- (void)routeSpeedChanged {
    self.routeSpeedValueLabel.text = [NSString stringWithFormat:@"%.0f km/h", self.routeSpeedSlider.value];
}

- (void)routeStopBehaviorChanged {
    GPSLabConfiguration *configuration = [[GPSLabEngine sharedEngine] configuration];
    configuration.stopBehavior = (self.routeStopBehaviorSegment.selectedSegmentIndex == 1)
        ? GPSLabStopBehaviorReturnToStart : GPSLabStopBehaviorStayAtCurrent;
    [[GPSLabEngine sharedEngine] applyConfiguration:configuration];
}

- (void)routePlayTapped {
    GPSLabRouteSimulator *simulator = [[GPSLabEngine sharedEngine] routeSimulator];
    GPSLabRouteState state = [simulator state];
    if (state == GPSLabRouteStatePaused) {
        [[GPSLabEngine sharedEngine] resumeRoute];
        [self updateRouteControls];
        return;
    }
    if (state == GPSLabRouteStatePlaying) {
        [[GPSLabEngine sharedEngine] pauseRoute];
        [self updateRouteControls];
        return;
    }
    [self startRouteFromPending];
}

- (void)routeStopTapped {
    [[GPSLabProfileApplicationCoordinator sharedCoordinator] invalidateAppliedProfile];
    [[GPSLabEngine sharedEngine] stopRoute];
    [self updateRouteControls];
    [self updateStatusLabel];
}

- (void)startRouteFromPending {
    if (self.pendingRouteStartItem == nil || self.pendingRouteEndItem == nil) {
        [self presentErrorKey:@"route.incomplete.message"];
        return;
    }
    GPSLabConfiguration *configuration = [[GPSLabEngine sharedEngine] configuration];
    configuration.routeMode = (GPSLabRouteMode)self.routeModeSegment.selectedSegmentIndex;
    configuration.routeCustomSpeedKmh = self.routeSpeedSlider.value;
    configuration.stopBehavior = (self.routeStopBehaviorSegment.selectedSegmentIndex == 1)
        ? GPSLabStopBehaviorReturnToStart : GPSLabStopBehaviorStayAtCurrent;
    [[GPSLabEngine sharedEngine] applyConfiguration:configuration];
    // A manual route change invalidates any scheduled ownership.
    [[GPSLabProfileApplicationCoordinator sharedCoordinator] invalidateAppliedProfile];

    GPSLabOverlayViewController *__weak weakSelf = self;
    [[GPSLabEngine sharedEngine] startRouteFrom:self.pendingRouteStartItem.placemark.coordinate
                                             to:self.pendingRouteEndItem.placemark.coordinate
                                           mode:configuration.routeMode
                                 customSpeedKmh:configuration.routeCustomSpeedKmh
                                     completion:^(NSError * _Nullable error) {
        GPSLabOverlayViewController *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        if (error != nil) {
            [strongSelf presentErrorKey:@"route.failed.title"];
        }
        [strongSelf updateRouteControls];
    }];
    [self updateRouteControls];
}

#pragma mark - Map gestures

- (void)mapPanShield:(UIPanGestureRecognizer *)recognizer {
    if (recognizer.state == UIGestureRecognizerStateBegan) {
        self.bodyScrollView.scrollEnabled = NO;
    } else if (recognizer.state == UIGestureRecognizerStateEnded ||
               recognizer.state == UIGestureRecognizerStateCancelled ||
               recognizer.state == UIGestureRecognizerStateFailed) {
        self.bodyScrollView.scrollEnabled = YES;
    }
}

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
    [self updateRouteControls];
    BOOL reopen = self.reopenRouteAfterPick;
    self.reopenRouteAfterPick = NO;
    self.pickMode = GPSLabMapPickModeNone;
    [self updatePickBanner];
    if (reopen) {
        // Route tab owns the controls now; nothing to re-present.
    }
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
        shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    (void)gestureRecognizer;
    (void)other;
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    if (gestureRecognizer != self.outsideTapRecognizer) {
        return YES;
    }
    if (!self.isSearchSessionActive) {
        return NO;
    }
    UIView *touchView = touch.view;
    if (touchView == nil) {
        return NO;
    }
    GPSLabSearchResultsViewController *results = self.searchResultsController;
    if (results != nil && results.isViewLoaded && [touchView isDescendantOfView:results.view]) {
        return NO;
    }
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

- (void)installOutsideTapRecognizer {
    if (self.outsideTapRecognizer != nil) {
        return;
    }
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(outsideTapped:)];
    tap.delegate = self;
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

#pragma mark - Search delegate

- (BOOL)searchBarShouldBeginEditing:(UISearchBar *)searchBar {
    (void)searchBar;
    [[GPSLabOverlayPresenter sharedPresenter] acquireKeyLease];
    return YES;
}

- (void)searchBarTextDidBeginEditing:(UISearchBar *)searchBar {
    if (!GPSLabSearchSessionIsActive(&_searchSession)) {
        GPSLabSearchSessionBegin(&_searchSession);
    }
    searchBar.showsCancelButton = YES;
    [self setSearchResultsVisible:YES];
    [self.searchResultsController updateSearchResultsForQuery:searchBar.text ?: @""];
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    (void)searchBar;
    if (!GPSLabSearchSessionIsActive(&_searchSession)) {
        return;
    }
    [self.searchResultsController updateSearchResultsForQuery:searchText ?: @""];
}

- (void)searchBarTextDidEndEditing:(UISearchBar *)searchBar {
    searchBar.showsCancelButton = GPSLabSearchSessionIsActive(&_searchSession) ? YES : NO;
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
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

#pragma mark - Route annotations

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
    GPSLabRouteSimulator *simulator = [[GPSLabEngine sharedEngine] routeSimulator];
    CLLocationCoordinate2D start = CLLocationCoordinate2DMake(0.0, 0.0);
    CLLocationCoordinate2D current = start;
    double course = 0.0;
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
    if (annotation == self.realLocationAnnotation) {
        static NSString *realIdentifier = @"gpslabRealPin";
        MKMarkerAnnotationView *marker =
            (MKMarkerAnnotationView *)[mapView dequeueReusableAnnotationViewWithIdentifier:realIdentifier];
        if (marker == nil) {
            marker = [[MKMarkerAnnotationView alloc] initWithAnnotation:annotation reuseIdentifier:realIdentifier];
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
        NSString *identifier = isStart ? @"gpslabRouteStartPin" : @"gpslabRouteEndPin";
        MKMarkerAnnotationView *marker =
            (MKMarkerAnnotationView *)[mapView dequeueReusableAnnotationViewWithIdentifier:identifier];
        if (marker == nil) {
            marker = [[MKMarkerAnnotationView alloc] initWithAnnotation:annotation reuseIdentifier:identifier];
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
        MKMarkerAnnotationView *marker = [[MKMarkerAnnotationView alloc] initWithAnnotation:annotation reuseIdentifier:identifier];
        marker.draggable = YES;
        marker.canShowCallout = YES;
        marker.markerTintColor = UIColor.systemBlueColor;
        view = marker;
    }
    view.annotation = annotation;
    if ([annotation isKindOfClass:[GPSLabSyntheticAnnotation class]] && view.gestureRecognizers.count == 0) {
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(annotationDragged:)];
        [view addGestureRecognizer:pan];
    }
    return view;
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
    self.tickTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
        (void)timer;
        [weakSelf rebuildRoutePolylineIfPossible];
        [weakSelf updateStatusLabel];
        [weakSelf updateRouteControls];
    }];
}

- (void)stopTickTimer {
    if (self.tickTimer != nil) {
        [self.tickTimer invalidate];
        self.tickTimer = nil;
    }
}

- (void)scheduleBackgroundSnapshot {
    [self.snapshotTimer invalidate];
    self.snapshotTimer = [NSTimer scheduledTimerWithTimeInterval:0.8
                                                         repeats:NO
                                                           block:^(NSTimer *timer) {
        (void)timer;
        [self refreshBackgroundSnapshot];
    }];
}

- (void)refreshBackgroundSnapshot {
    if (self.view.window == nil) {
        return;
    }
    CLLocationCoordinate2D anchor = [[GPSLabEngine sharedEngine] baseCoordinate];
    MKCoordinateRegion region = MKCoordinateRegionMakeWithDistance(anchor, 3000.0, 3000.0);
    MKMapSnapshotOptions *options = [[MKMapSnapshotOptions alloc] init];
    options.region = region;
    options.mapType = MKMapTypeStandard;
    options.size = CGSizeMake(600.0, 600.0);
    options.scale = 1.0;
    MKMapSnapshotter *snapshotter = [[MKMapSnapshotter alloc] initWithOptions:options];
    GPSLabOverlayViewController *__weak weakSelf = self;
    [snapshotter startWithCompletionHandler:^(MKMapSnapshot * _Nullable snapshot, NSError * _Nullable error) {
        if (error != nil || snapshot == nil) {
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.backgroundImageView.image = snapshot.image;
        });
    }];
}

#pragma mark - Status

- (void)updateStatusLabel {
    GPSLabConfiguration *configuration = [[GPSLabEngine sharedEngine] configuration];
    [GPSLabLocalization forceLeftToRight:self.coordsBigLabel];
    self.coordsBigLabel.text = [NSString stringWithFormat:@"%@ %.6f\n%@ %.6f",
                                GPSLabLocalized(@"panel.coord.latitude"),
                                configuration.latitude,
                                GPSLabLocalized(@"panel.coord.longitude"),
                                configuration.longitude];
    if (self.coordValueLabels.count >= 3) {
        self.coordValueLabels[0].text = [GPSLabLocalization decimalString:configuration.latitude fractionDigits:5];
        self.coordValueLabels[1].text = [GPSLabLocalization decimalString:configuration.longitude fractionDigits:5];
        self.coordValueLabels[2].text = [GPSLabLocalization decimalString:configuration.altitude fractionDigits:0];
    }
    self.headingView.heading = configuration.heading;
    self.headingValueLabel.text = [NSString stringWithFormat:GPSLabLocalized(@"panel.heading.format"),
                                   [NSString stringWithFormat:@"°%03.0f", configuration.heading < 0.0 ? 0.0 : configuration.heading]];
    self.driftSwitch.on = configuration.driftEnabled;
    self.keepLastSwitch.on = configuration.keepLastCoordinate;
    self.driftSwitch.accessibilityLabel = GPSLabLocalized(@"panel.toggle.drift");
    self.keepLastSwitch.accessibilityLabel = GPSLabLocalized(@"panel.toggle.keepLast");
    self.realLocationSwitch.accessibilityLabel = GPSLabLocalized(@"panel.toggle.realLocation");
}

- (void)updateSubscriptionCard {
    GPSLabEntitlement *entitlement = [[GPSLabLicenseManager sharedManager] currentEntitlement];
    GPSLabLicenseManager *manager = [GPSLabLicenseManager sharedManager];
    GPSLabEntitlementState state = [manager state];
    NSString *statusKey = @"subscription.status.unknown";
    UIColor *color = GPSLabThemeMutedColor();
    switch (state) {
        case GPSLabEntitlementStateActive:  statusKey = @"subscription.status.active"; color = GPSLabThemeGreenColor(); break;
        case GPSLabEntitlementStateGrace:   statusKey = @"subscription.status.grace"; color = GPSLabThemeGreenColor(); break;
        case GPSLabEntitlementStateChecking: statusKey = @"subscription.status.checking"; break;
        case GPSLabEntitlementStateExpired: statusKey = @"subscription.status.expired"; color = GPSLabThemeRedColor(); break;
        case GPSLabEntitlementStateInvalid: statusKey = @"subscription.status.invalid"; color = GPSLabThemeRedColor(); break;
        case GPSLabEntitlementStateOffline: statusKey = @"subscription.status.offline"; break;
        default: break;
    }
    self.subscriptionStatusLabel.text = [NSString stringWithFormat:@"  %@  ", GPSLabLocalized(statusKey)];
    self.subscriptionStatusLabel.textColor = color;
    self.subscriptionStatusLabel.backgroundColor = [color colorWithAlphaComponent:0.14];
    self.subscriptionStatusLabel.layer.borderWidth = 1.0;
    self.subscriptionStatusLabel.layer.borderColor = [color colorWithAlphaComponent:0.28].CGColor;
    NSString *plan = entitlement.plan;
    self.subscriptionPlanValue.text = (plan.length > 0) ? plan : GPSLabLocalized(@"subscription.compact.planNone");
    if (entitlement.expiresAt > 0) {
        NSDate *date = [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)entitlement.expiresAt];
        self.subscriptionExpiryValue.text = [NSDateFormatter localizedStringFromDate:date
                                                                         dateStyle:NSDateFormatterMediumStyle
                                                                         timeStyle:NSDateFormatterNoStyle];
    } else {
        self.subscriptionExpiryValue.text = GPSLabLocalized(@"subscription.compact.planNone");
    }
}

- (NSString *)installationIdentifierDisplay {
    NSString *uuid = [[GPSLabSecureStore sharedStore] installationUUID];
    return uuid.length > 0 ? uuid.uppercaseString : @"—";
}

#pragma mark - Notifications

- (void)engineStateDidChange:(NSNotification *)notification {
    (void)notification;
    [self updateMasterAppearance];
    [self updateMapFromState];
}

- (void)licenseStateDidChange:(NSNotification *)notification {
    (void)notification;
    [self updateSubscriptionCard];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    (void)notification;
    [self updateSubscriptionCard];
    [self scheduleBackgroundSnapshot];
}

@end
