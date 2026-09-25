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

#include <math.h>

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
#import "GPSLabAltitudeViewController.h"
#import "GPSLabManualEntryViewController.h"
#import "GPSLabMapLinkCore.h"
#import "GPSLabMapLinkResolver.h"
#import "GPSLabMasterIntentGuard.h"
#import "GPSLabModalCoordinator.h"
#import "GPSLabOptionsViewController.h"
#import "GPSLabOverlayPresenter.h"
#import "GPSLabPortalViewController.h"
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
#import "GPSLabSelectionPolicyCore.h"
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

// Service (master engine switch) row
@property (nonatomic, strong) UIView *serviceRowView;
@property (nonatomic, strong) UILabel *serviceTitleLabel;
@property (nonatomic, strong) UILabel *serviceHintLabel;
@property (nonatomic, strong) UILabel *serviceStateLabel;
@property (nonatomic, strong) UISwitch *serviceSwitch;

// Search
@property (nonatomic, strong) UIView *searchBarContainer;
@property (nonatomic, strong, nullable) UISearchBar *searchBar;
@property (nonatomic, strong, nullable) GPSLabSearchResultsViewController *searchResultsController;
@property (nonatomic, strong, nullable) NSLayoutConstraint *resultHeightConstraint;
@property (nonatomic, strong) UIView *searchSourceView;
@property (nonatomic, strong) UILabel *searchSourceTextLabel;
@property (nonatomic, strong) UILabel *searchSourceKindLabel;
@property (nonatomic, strong, nullable) NSLayoutConstraint *searchSourceHeightConstraint;
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
@property (nonatomic, strong) UILabel *driftRangeCaptionLabel;
@property (nonatomic, strong) UILabel *driftRangeValueLabel;
@property (nonatomic, strong) UILabel *driftRangeChevronLabel;
@property (nonatomic, strong) UIButton *driftRangeButton;
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

// Pending (preview) selection: shown on the map/coords but NOT written to the
// engine until the user taps Apply.
@property (nonatomic, assign) BOOL hasPendingSelection;
@property (nonatomic, assign) CLLocationCoordinate2D pendingCoordinate;
@property (nonatomic, assign) double pendingAltitude;
@property (nonatomic, assign) double pendingHeading;
@property (nonatomic, strong, nullable) NSString *pendingSourceKindKey;

// Drift draft, owned by the overlay like the coordinate preview. The switch, the
// compact range row and the fluctuation sheet only edit these; the engine is
// written exclusively by a validated Apply (bundled into the same configuration
// as the coordinate/route), never by an edit.
@property (nonatomic, assign) BOOL pendingDriftEnabled;
@property (nonatomic, assign) double pendingDriftRadius;

@property (nonatomic, strong, nullable) NSTimer *tickTimer;
@property (nonatomic, strong, nullable) NSTimer *snapshotTimer;

@property (nonatomic, copy) NSArray<GPSLabProfile *> *profiles;
@property (nonatomic, copy, nullable) NSString *selectedProfileIdentifier;
@property (nonatomic, copy, nullable) NSString *appliedProfileIdentifier;

// Owns master-switch intents so a superseded/cancelled profile apply can never
// roll back or mutate a newer switch change. The same object is unit-tested.
@property (nonatomic, strong) GPSLabMasterIntentGuard *masterIntentGuard;

/** Opens the account/support portal sheet (available while unlocked). */
- (void)presentPortalSheet;

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
    // Foreground map style is a persisted UI preference (missing/invalid => Satellite).
    self.mapStyle = [[GPSLabStore sharedStore] loadMapStyle];
    self.masterIntentGuard = [[GPSLabMasterIntentGuard alloc] init];

    [self buildBackground];
    [self buildPanel];
    [self buildHeader];
    [self buildServiceRow];
    [self buildSearchBar];
    [self buildBody];
    [self installOutsideTapRecognizer];
    [self loadConfigurationIntoUI];
    // Restore a persisted preview draft once, after the committed state is loaded.
    // UI-only: the engine is never written by a restore.
    [self restorePendingSelection];
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
    [[GPSLabMapLinkResolver sharedResolver] cancel];
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
    self.languageButton.titleLabel.font = GPSLabThemeFont(13.0, UIFontWeightBold);
    self.languageButton.layer.cornerRadius = 12.0;
    self.languageButton.layer.borderWidth = 1.0;
    self.languageButton.layer.borderColor = GPSLabThemeBorderColor().CGColor;
    self.languageButton.backgroundColor = GPSLabColorFromHex(0x1A1A20);
    self.languageButton.contentEdgeInsets = UIEdgeInsetsMake(8.0, 10.0, 8.0, 10.0);

    self.infoButton = [self chromeButtonWithTitle:@"ⓘ" action:@selector(infoTapped)];
    self.infoButton.titleLabel.font = GPSLabThemeFont(19.0, UIFontWeightBold);
    self.infoButton.layer.cornerRadius = 12.0;
    self.infoButton.layer.borderWidth = 1.0;
    self.infoButton.layer.borderColor = GPSLabThemeBorderColor().CGColor;
    self.infoButton.backgroundColor = GPSLabColorFromHex(0x1A1A20);

    self.headerTitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.headerTitleLabel.font = GPSLabThemeFont(29.0, UIFontWeightHeavy);
    self.headerTitleLabel.textColor = GPSLabThemeTextColor();
    self.headerTitleLabel.textAlignment = NSTextAlignmentCenter;
    // Nominal reference size stays 29pt; shrink-to-fit keeps "موقع" on one line
    // on narrow iPhones (360/375) without moving the header row.
    self.headerTitleLabel.adjustsFontSizeToFitWidth = YES;
    self.headerTitleLabel.minimumScaleFactor = 0.6;
    self.headerTitleLabel.numberOfLines = 1;
    self.headerTitleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.headerSubtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.headerSubtitleLabel.font = GPSLabThemeFont(13.0, UIFontWeightRegular);
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
    self.closeButton.titleLabel.font = GPSLabThemeFont(27.0, UIFontWeightSemibold);
    self.closeButton.layer.cornerRadius = 13.0;
    self.closeButton.layer.borderWidth = 1.0;
    self.closeButton.layer.borderColor = GPSLabThemeBorderColor().CGColor;
    self.closeButton.backgroundColor = GPSLabColorFromHex(0x1A1A20);

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.languageButton, self.infoButton, titleColumn, self.masterButton, self.closeButton,
    ]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 8.0;
    row.semanticContentAttribute = UISemanticContentAttributeForceLeftToRight;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [self.headerView addSubview:row];

    [NSLayoutConstraint activateConstraints:@[
        [self.headerView.topAnchor constraintEqualToAnchor:self.panelView.topAnchor constant:14.0],
        [self.headerView.leadingAnchor constraintEqualToAnchor:self.panelView.leadingAnchor],
        [self.headerView.trailingAnchor constraintEqualToAnchor:self.panelView.trailingAnchor],
        [row.topAnchor constraintEqualToAnchor:self.headerView.topAnchor],
        [row.leadingAnchor constraintEqualToAnchor:self.headerView.leadingAnchor constant:16.0],
        [row.trailingAnchor constraintEqualToAnchor:self.headerView.trailingAnchor constant:-16.0],
        [row.bottomAnchor constraintEqualToAnchor:self.headerView.bottomAnchor],
        [self.infoButton.widthAnchor constraintEqualToConstant:39.0],
        [self.infoButton.heightAnchor constraintEqualToConstant:39.0],
        [self.closeButton.widthAnchor constraintEqualToConstant:41.0],
        [self.closeButton.heightAnchor constraintEqualToConstant:41.0],
        [self.languageButton.heightAnchor constraintEqualToConstant:41.0],
    ]];
    [self.languageButton setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
}

- (void)buildServiceRow {
    self.serviceRowView = [[UIView alloc] initWithFrame:CGRectZero];
    self.serviceRowView.translatesAutoresizingMaskIntoConstraints = NO;
    self.serviceRowView.backgroundColor = GPSLabColorFromHex(0x141419);
    self.serviceRowView.layer.cornerRadius = 15.0;
    self.serviceRowView.layer.masksToBounds = YES;
    self.serviceRowView.layer.borderWidth = 0.5;
    self.serviceRowView.layer.borderColor = GPSLabColorFromHex(0x2D2D35).CGColor;
    [self.panelView addSubview:self.serviceRowView];

    self.serviceTitleLabel = [self themedLabel:14.0 weight:UIFontWeightSemibold color:GPSLabThemeTextColor()];
    self.serviceTitleLabel.text = GPSLabLocalized(@"service.title");
    self.serviceHintLabel = [self themedLabel:10.5 weight:UIFontWeightRegular color:GPSLabColorFromHex(0x8E8E96)];
    self.serviceHintLabel.text = GPSLabLocalized(@"service.hint.enabled");
    UIStackView *serviceCopy = [[UIStackView alloc] initWithArrangedSubviews:@[ self.serviceTitleLabel, self.serviceHintLabel ]];
    serviceCopy.axis = UILayoutConstraintAxisVertical;
    serviceCopy.spacing = 3.0;
    serviceCopy.translatesAutoresizingMaskIntoConstraints = NO;

    self.serviceStateLabel = [self themedLabel:11.0 weight:UIFontWeightBold color:GPSLabThemeGreenColor()];
    self.serviceStateLabel.text = GPSLabLocalized(@"service.state.enabled");

    // The single master engine switch, reusing the existing setEnabledAndNotify:
    // path. OFF is passthrough only; it never stops the host manager/app and never
    // erases configuration, profiles, history or licensing.
    self.serviceSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
    self.serviceSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    self.serviceSwitch.onTintColor = GPSLabThemeGreenColor();
    self.serviceSwitch.accessibilityLabel = GPSLabLocalized(@"service.accessibility");
    [self.serviceSwitch addTarget:self action:@selector(masterTapped) forControlEvents:UIControlEventValueChanged];

    UIStackView *right = [[UIStackView alloc] initWithArrangedSubviews:@[ self.serviceStateLabel, self.serviceSwitch ]];
    right.axis = UILayoutConstraintAxisHorizontal;
    right.alignment = UIStackViewAlignmentCenter;
    right.spacing = 10.0;
    right.translatesAutoresizingMaskIntoConstraints = NO;

    [self.serviceRowView addSubview:serviceCopy];
    [self.serviceRowView addSubview:right];
    [NSLayoutConstraint activateConstraints:@[
        [self.serviceRowView.topAnchor constraintEqualToAnchor:self.headerView.bottomAnchor constant:7.0],
        [self.serviceRowView.leadingAnchor constraintEqualToAnchor:self.panelView.leadingAnchor constant:20.0],
        [self.serviceRowView.trailingAnchor constraintEqualToAnchor:self.panelView.trailingAnchor constant:-20.0],
        [serviceCopy.topAnchor constraintEqualToAnchor:self.serviceRowView.topAnchor constant:10.0],
        [serviceCopy.bottomAnchor constraintEqualToAnchor:self.serviceRowView.bottomAnchor constant:-10.0],
        [serviceCopy.leadingAnchor constraintEqualToAnchor:self.serviceRowView.leadingAnchor constant:12.0],
        [right.leadingAnchor constraintGreaterThanOrEqualToAnchor:serviceCopy.trailingAnchor constant:8.0],
        [right.trailingAnchor constraintEqualToAnchor:self.serviceRowView.trailingAnchor constant:-12.0],
        [right.centerYAnchor constraintEqualToAnchor:self.serviceRowView.centerYAnchor],
    ]];
    [serviceCopy setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
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

    // FIXED bar height from the pure C helper; the reference search row is 54pt.
    CGFloat intrinsicHeight = bar.intrinsicContentSize.height;
    if (!(intrinsicHeight > 0.0)) {
        intrinsicHeight = 56.0;
    }
    CGFloat barHeight = GPSLabSearchBarHeight(intrinsicHeight, 54.0);

    // Light Google/Apple Maps banner, hidden until a maps link is recognised.
    self.searchSourceView = [[UIView alloc] initWithFrame:CGRectZero];
    self.searchSourceView.translatesAutoresizingMaskIntoConstraints = NO;
    self.searchSourceView.backgroundColor = GPSLabColorFromHex(0x101014);
    self.searchSourceView.layer.cornerRadius = 12.0;
    self.searchSourceView.layer.masksToBounds = YES;
    self.searchSourceView.layer.borderWidth = 0.5;
    self.searchSourceView.layer.borderColor = GPSLabColorFromHex(0x292930).CGColor;
    self.searchSourceView.hidden = YES;
    [self.panelView addSubview:self.searchSourceView];

    self.searchSourceTextLabel = [self themedLabel:11.0 weight:UIFontWeightRegular color:GPSLabColorFromHex(0xA8A8B0)];
    self.searchSourceTextLabel.numberOfLines = 1;
    self.searchSourceKindLabel = [self themedLabel:11.0 weight:UIFontWeightSemibold color:GPSLabThemeAccentSoftColor()];
    self.searchSourceKindLabel.textAlignment = NSTextAlignmentRight;
    [self.searchSourceKindLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *sourceRow = [[UIStackView alloc] initWithArrangedSubviews:@[ self.searchSourceTextLabel, self.searchSourceKindLabel ]];
    sourceRow.axis = UILayoutConstraintAxisHorizontal;
    sourceRow.alignment = UIStackViewAlignmentCenter;
    sourceRow.spacing = 10.0;
    sourceRow.translatesAutoresizingMaskIntoConstraints = NO;
    [self.searchSourceView addSubview:sourceRow];

    NSLayoutConstraint *searchSourceHeight = [self.searchSourceView.heightAnchor constraintEqualToConstant:0.0];
    self.searchSourceHeightConstraint = searchSourceHeight;
    // The banner's content constraints are non-required so the collapse-to-zero
    // height never produces a required-constraint conflict while hidden.
    NSLayoutConstraint *sourceTop = [sourceRow.topAnchor constraintEqualToAnchor:self.searchSourceView.topAnchor constant:7.0];
    NSLayoutConstraint *sourceBottom = [sourceRow.bottomAnchor constraintEqualToAnchor:self.searchSourceView.bottomAnchor constant:-7.0];
    sourceTop.priority = 999.0;
    sourceBottom.priority = 999.0;

    [NSLayoutConstraint activateConstraints:@[
        [self.searchBarContainer.topAnchor constraintEqualToAnchor:self.serviceRowView.bottomAnchor constant:10.0],
        [self.searchBarContainer.leadingAnchor constraintEqualToAnchor:self.panelView.leadingAnchor constant:20.0],
        [self.searchBarContainer.trailingAnchor constraintEqualToAnchor:self.panelView.trailingAnchor constant:-20.0],
        [self.searchBarContainer.heightAnchor constraintEqualToConstant:barHeight],
        [bar.topAnchor constraintEqualToAnchor:self.searchBarContainer.topAnchor],
        [bar.bottomAnchor constraintEqualToAnchor:self.searchBarContainer.bottomAnchor],
        [bar.leadingAnchor constraintEqualToAnchor:self.searchBarContainer.leadingAnchor constant:6.0],
        [bar.trailingAnchor constraintEqualToAnchor:self.searchBarContainer.trailingAnchor constant:-6.0],
        [bar.heightAnchor constraintEqualToConstant:barHeight],
        [self.searchSourceView.topAnchor constraintEqualToAnchor:self.searchBarContainer.bottomAnchor constant:6.0],
        [self.searchSourceView.leadingAnchor constraintEqualToAnchor:self.panelView.leadingAnchor constant:20.0],
        [self.searchSourceView.trailingAnchor constraintEqualToAnchor:self.panelView.trailingAnchor constant:-20.0],
        searchSourceHeight,
        sourceTop,
        sourceBottom,
        [sourceRow.leadingAnchor constraintEqualToAnchor:self.searchSourceView.leadingAnchor constant:10.0],
        [sourceRow.trailingAnchor constraintEqualToAnchor:self.searchSourceView.trailingAnchor constant:-10.0],
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
        [resultsView.topAnchor constraintEqualToAnchor:self.searchSourceView.bottomAnchor constant:8.0],
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
    [[GPSLabMapLinkResolver sharedResolver] cancel];
    [self hideSearchSource];
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
    self.mapCard.layer.cornerRadius = 22.0;
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
    self.favoritesCard.layer.cornerRadius = 22.0;
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
        [self.mapCard.heightAnchor constraintEqualToConstant:246.0],
        [self.favoritesCard.topAnchor constraintEqualToAnchor:container.topAnchor],
        [self.favoritesCard.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [self.favoritesCard.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [self.favoritesCard.heightAnchor constraintEqualToConstant:246.0],
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
    button.layer.cornerRadius = 12.0;
    button.layer.masksToBounds = YES;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [NSLayoutConstraint activateConstraints:@[
        [button.widthAnchor constraintEqualToConstant:42.0],
        [button.heightAnchor constraintEqualToConstant:42.0],
    ]];
    return button;
}

#pragma mark - Control card

- (UIView *)controlCardView {
    self.controlCard = [[UIView alloc] initWithFrame:CGRectZero];
    self.controlCard.backgroundColor = GPSLabThemeCardColor();
    GPSLabThemeApplyCardStyle(self.controlCard, 22.0);

    self.mapFavoritesSegment = [[UISegmentedControl alloc] initWithItems:@[@"", @""]];
    self.mapFavoritesSegment.selectedSegmentIndex = 0;
    self.mapFavoritesSegment.selectedSegmentTintColor = GPSLabThemeAccentColor();
    [self.mapFavoritesSegment addTarget:self action:@selector(mapFavoritesChanged) forControlEvents:UIControlEventValueChanged];

    self.staticRouteSegment = [[UISegmentedControl alloc] initWithItems:@[@"", @""]];
    self.staticRouteSegment.selectedSegmentIndex = 0;
    self.staticRouteSegment.selectedSegmentTintColor = GPSLabThemeAccentColor();
    [self.staticRouteSegment addTarget:self action:@selector(staticRouteChanged) forControlEvents:UIControlEventValueChanged];

    self.coordsTitleLabel = [self themedLabel:12.0 weight:UIFontWeightRegular color:GPSLabThemeMutedColor()];
    self.coordsBigLabel = [self themedLabel:20.0 weight:UIFontWeightSemibold color:GPSLabThemeTextColor()];
    self.coordsBigLabel.numberOfLines = 2;
    [GPSLabLocalization forceLeftToRight:self.coordsBigLabel];

    NSArray<NSString *> *coordKeys = @[@"panel.coord.latitude", @"panel.coord.longitude", @"panel.coord.altitude"];
    NSMutableArray<UILabel *> *coordValues = [NSMutableArray array];
    NSMutableArray<UIView *> *coordBoxes = [NSMutableArray array];
    for (NSUInteger index = 0; index < coordKeys.count; index++) {
        NSString *key = coordKeys[index];
        BOOL isAltitude = (index == coordKeys.count - 1);
        UIView *box;
        if (isAltitude) {
            // Reference altitude box: tappable, opens the altitude editor. Editing
            // only updates the preview; the engine is written on Apply.
            UIButton *altitudeButton = [UIButton buttonWithType:UIButtonTypeCustom];
            [altitudeButton addTarget:self action:@selector(altitudeTapped) forControlEvents:UIControlEventTouchUpInside];
            box = altitudeButton;
        } else {
            box = [[UIView alloc] initWithFrame:CGRectZero];
        }
        box.backgroundColor = GPSLabColorFromHex(0x0F0F12);
        box.layer.cornerRadius = 13.0;
        UILabel *caption = [self themedLabel:11.0 weight:UIFontWeightRegular color:GPSLabThemeMutedColor()];
        caption.textAlignment = NSTextAlignmentCenter;
        caption.accessibilityIdentifier = key;
        UILabel *value = [self themedLabel:17.0 weight:UIFontWeightSemibold color:GPSLabThemeTextColor()];
        value.textAlignment = NSTextAlignmentCenter;
        value.adjustsFontSizeToFitWidth = YES;
        value.minimumScaleFactor = 0.6;
        [GPSLabLocalization forceLeftToRight:value];
        [coordValues addObject:value];
        NSMutableArray<UIView *> *cellViews = [@[ caption, value ] mutableCopy];
        if (isAltitude) {
            UILabel *edit = [self themedLabel:9.5 weight:UIFontWeightSemibold color:GPSLabColorFromHex(0xA98CFF)];
            edit.accessibilityIdentifier = @"altitude.edit";
            edit.text = GPSLabLocalized(@"altitude.edit");
            edit.textAlignment = NSTextAlignmentCenter;
            [cellViews addObject:edit];
        }
        UIStackView *cell = [[UIStackView alloc] initWithArrangedSubviews:cellViews];
        cell.axis = UILayoutConstraintAxisVertical;
        cell.spacing = 4.0;
        cell.translatesAutoresizingMaskIntoConstraints = NO;
        cell.userInteractionEnabled = NO; // let the altitude button receive taps
        [box addSubview:cell];
        [NSLayoutConstraint activateConstraints:@[
            [cell.topAnchor constraintEqualToAnchor:box.topAnchor constant:9.0],
            [cell.bottomAnchor constraintEqualToAnchor:box.bottomAnchor constant:-9.0],
            [cell.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:7.0],
            [cell.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-7.0],
            [box.heightAnchor constraintGreaterThanOrEqualToConstant:70.0],
        ]];
        [coordBoxes addObject:box];
    }
    self.coordValueLabels = coordValues;
    UIStackView *coordGrid = [[UIStackView alloc] initWithArrangedSubviews:coordBoxes];
    coordGrid.axis = UILayoutConstraintAxisHorizontal;
    coordGrid.distribution = UIStackViewDistributionFillEqually;
    coordGrid.spacing = 7.0;

    self.headingView = [[GPSLabHeadingView alloc] initWithFrame:CGRectZero];
    self.headingView.translatesAutoresizingMaskIntoConstraints = NO;
    self.headingView.heading = 0.0;
    self.headingValueLabel = [self themedLabel:14.0 weight:UIFontWeightRegular color:GPSLabThemeMutedColor()];
    [GPSLabLocalization forceLeftToRight:self.headingValueLabel];
    [self.headingView.heightAnchor constraintEqualToConstant:24.0].active = YES;
    UIStackView *headingRow = [[UIStackView alloc] initWithArrangedSubviews:@[ self.headingView, self.headingValueLabel ]];
    headingRow.axis = UILayoutConstraintAxisHorizontal;
    headingRow.alignment = UIStackViewAlignmentCenter;
    headingRow.spacing = 10.0;
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
    self.scheduleButton.layer.cornerRadius = 12.0;
    self.scheduleButton.layer.masksToBounds = YES;
    self.scheduleButton.contentEdgeInsets = UIEdgeInsetsMake(8.0, 12.0, 8.0, 12.0);
    [self.scheduleButton addTarget:self action:@selector(scheduleTapped) forControlEvents:UIControlEventTouchUpInside];

    self.routeSection = [self routeSectionView];

    UIStackView *column = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.mapFavoritesSegment, self.staticRouteSegment,
        self.coordsTitleLabel, self.coordsBigLabel, coordGrid, headingRow,
        [self toggleRowWithKey:@"panel.toggle.drift" control:self.driftSwitch],
        [self driftRangeRowView],
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
        [column.topAnchor constraintEqualToAnchor:self.controlCard.topAnchor constant:14.0],
        [column.bottomAnchor constraintEqualToAnchor:self.controlCard.bottomAnchor constant:-14.0],
        [column.leadingAnchor constraintEqualToAnchor:self.controlCard.leadingAnchor constant:14.0],
        [column.trailingAnchor constraintEqualToAnchor:self.controlCard.trailingAnchor constant:-14.0],
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

// Compact, whole-row tappable localized drift range control shown immediately
// under the drift switch. The caption uses the exact localized catalog text
// ("مدى التذبذب" / "Drift range"), the live draft value is separate (so the shared
// subtree localization can never corrupt it), and a visible `>` chevron is the
// affordance. Tapping the row opens the fluctuation sheet; it never writes the
// engine (the sheet edits the same draft).
- (UIView *)driftRangeRowView {
    self.driftRangeButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.driftRangeButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.driftRangeButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentFill;
    [self.driftRangeButton addTarget:self action:@selector(driftRangeTapped)
                    forControlEvents:UIControlEventTouchUpInside];

    self.driftRangeCaptionLabel = [self themedLabel:12.0 weight:UIFontWeightRegular color:GPSLabThemeMutedColor()];
    // A real catalog key so the shared subtree localization re-applies the exact
    // localized label text.
    self.driftRangeCaptionLabel.accessibilityIdentifier = @"panel.drift.range";
    self.driftRangeCaptionLabel.text = GPSLabLocalized(@"panel.drift.range");
    self.driftRangeCaptionLabel.userInteractionEnabled = NO;
    self.driftRangeCaptionLabel.translatesAutoresizingMaskIntoConstraints = NO;

    // Deliberately NO accessibilityIdentifier: the shared subtree pass must not
    // overwrite the live value. Accessibility exposes the value on the row button.
    self.driftRangeValueLabel = [self themedLabel:14.0 weight:UIFontWeightMedium color:GPSLabThemeAccentSoftColor()];
    self.driftRangeValueLabel.textAlignment = NSTextAlignmentRight;
    self.driftRangeValueLabel.userInteractionEnabled = NO;
    self.driftRangeValueLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [GPSLabLocalization forceLeftToRight:self.driftRangeValueLabel];

    // A visible chevron. The `>` glyph is bidi-mirrored in RTL, so pin it LTR.
    self.driftRangeChevronLabel = [self themedLabel:14.0 weight:UIFontWeightSemibold color:GPSLabThemeAccentSoftColor()];
    self.driftRangeChevronLabel.text = @">";
    self.driftRangeChevronLabel.userInteractionEnabled = NO;
    self.driftRangeChevronLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [GPSLabLocalization forceLeftToRight:self.driftRangeChevronLabel];

    [self.driftRangeButton addSubview:self.driftRangeCaptionLabel];
    [self.driftRangeButton addSubview:self.driftRangeValueLabel];
    [self.driftRangeButton addSubview:self.driftRangeChevronLabel];
    [NSLayoutConstraint activateConstraints:@[
        [self.driftRangeCaptionLabel.leadingAnchor constraintEqualToAnchor:self.driftRangeButton.leadingAnchor
                                                                  constant:10.0],
        [self.driftRangeCaptionLabel.centerYAnchor constraintEqualToAnchor:self.driftRangeButton.centerYAnchor],
        [self.driftRangeValueLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.driftRangeCaptionLabel.trailingAnchor
                                                                            constant:10.0],
        [self.driftRangeValueLabel.trailingAnchor constraintEqualToAnchor:self.driftRangeChevronLabel.leadingAnchor
                                                                 constant:-6.0],
        [self.driftRangeValueLabel.centerYAnchor constraintEqualToAnchor:self.driftRangeButton.centerYAnchor],
        [self.driftRangeChevronLabel.trailingAnchor constraintEqualToAnchor:self.driftRangeButton.trailingAnchor
                                                                   constant:-10.0],
        [self.driftRangeChevronLabel.centerYAnchor constraintEqualToAnchor:self.driftRangeButton.centerYAnchor],
        [self.driftRangeButton.heightAnchor constraintEqualToConstant:36.0],
    ]];
    [self updateDriftRangeDisplay];
    return self.driftRangeButton;
}

- (void)updateDriftRangeDisplay {
    if (self.driftRangeValueLabel == nil) {
        return;
    }
    NSString *value = [NSString stringWithFormat:GPSLabLocalized(@"fluctuation.radiusFormat"),
                       self.pendingDriftRadius];
    self.driftRangeValueLabel.text = value;
    // The whole row is one button: expose the label and the live value for VoiceOver.
    self.driftRangeButton.accessibilityLabel = [NSString stringWithFormat:@"%@ %@",
                                                GPSLabLocalized(@"panel.drift.range"), value];
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
    // The draft is seeded from the COMMITTED configuration on every load/restore.
    self.pendingDriftEnabled = configuration.driftEnabled;
    self.pendingDriftRadius = configuration.driftRadiusMeters;
    [self updateDriftRangeDisplay];
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
    // The selection is persisted immediately and is INDEPENDENT of the location
    // Apply/Cancel draft: it is never a pending value and never reverted.
    [[GPSLabStore sharedStore] saveMapStyle:(GPSLabMapStyle)style];
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
    // The lightweight background snapshot must always match the selected style.
    [self scheduleBackgroundSnapshot];
}

/** Maps the persisted UI style onto the snapshot map type (single source of truth). */
- (MKMapType)mapTypeForStyle:(GPSLabMapStyle)style {
    switch (style) {
        case GPSLabMapStyleHybrid:
            return MKMapTypeHybrid;
        case GPSLabMapStyleSatellite:
            return MKMapTypeSatellite;
        case GPSLabMapStyleStandard:
        default:
            return MKMapTypeStandard;
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
    self.serviceTitleLabel.text = GPSLabLocalized(@"service.title");
    self.closeButton.accessibilityLabel = GPSLabLocalized(@"common.close");
    [self updateMasterAppearance];

    self.searchBar.placeholder = GPSLabLocalized(@"overlay.search.placeholder");
    self.searchBar.accessibilityLabel = GPSLabLocalized(@"overlay.search.placeholder");
    [self updateSearchSourceForText:self.searchBar.text];

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
    // The subtree pass re-applies the exact localized label; re-apply the live
    // draft value afterwards (its label has no identifier and is never clobbered).
    self.driftRangeCaptionLabel.text = GPSLabLocalized(@"panel.drift.range");
    [self updateDriftRangeDisplay];

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

    // Service row: the single master switch (same setEnabledAndNotify: path).
    self.serviceSwitch.on = enabled;
    self.serviceStateLabel.text = GPSLabLocalized(enabled ? @"service.state.enabled" : @"service.state.disabled");
    self.serviceStateLabel.textColor = enabled ? GPSLabThemeGreenColor() : GPSLabColorFromHex(0x9A9AA2);
    self.serviceHintLabel.text = GPSLabLocalized(enabled ? @"service.hint.enabled" : @"service.hint.disabled");
    self.serviceSwitch.accessibilityLabel = GPSLabLocalized(@"service.accessibility");
    [self updateStatusLabel];
}

- (void)masterTapped {
    // A manual switch interaction is a newer intent: it invalidates any pending
    // profile apply so that apply can never roll back this change.
    [self.masterIntentGuard invalidateIntents];
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
    [[GPSLabMapLinkResolver sharedResolver] cancel];
    [self.searchResultsController cancelActiveSearch];
    [[GPSLabScheduler sharedScheduler] cancelPending];
    [[GPSLabProfileApplicationCoordinator sharedCoordinator] cancelPendingApplication];
    [[GPSLabOverlayPresenter sharedPresenter] dismissOverlay];
}

- (void)centerTapped {
    CLLocationCoordinate2D coordinate = [[GPSLabEngine sharedEngine] baseCoordinate];
    [self.mapView setRegion:MKCoordinateRegionMakeWithDistance(coordinate, 800.0, 800.0) animated:YES];
}

- (void)bookmarkTapped {
    // Capture the SHOWN selection: the pending preview when one exists, otherwise
    // the committed anchor with its matching altitude. Shared policy helper so the
    // resolution is unit-tested without UIKit.
    GPSLabConfiguration *configuration = [[GPSLabEngine sharedEngine] configuration];
    double latitude = 0.0;
    double longitude = 0.0;
    double altitude = 0.0;
    GPSLabFavoriteResolveShownSelection(self.hasPendingSelection ? 1 : 0,
                                        self.pendingCoordinate.latitude,
                                        self.pendingCoordinate.longitude,
                                        self.pendingAltitude,
                                        configuration.latitude,
                                        configuration.longitude,
                                        configuration.altitude,
                                        &latitude,
                                        &longitude,
                                        &altitude);
    CLLocationCoordinate2D coordinate = CLLocationCoordinate2DMake(latitude, longitude);
    if (!GPSLabIsValidCoordinate(coordinate.latitude, coordinate.longitude)) {
        return;
    }
    // Refuse the pristine default (0,0) unless there is proof of an intentional
    // or legacy persisted selection; a pending/intentional 0,0 stays allowed.
    if (![[GPSLabStore sharedStore] shouldAllowFavoriteAtCoordinate:coordinate
                                                          hasPending:self.hasPendingSelection]) {
        // A visible native message: the status log has no UI consumer.
        [self presentFavoriteMessageKey:@"favorites.originRequired"];
        return;
    }
    [self presentFavoriteNamePromptForCoordinate:coordinate altitude:altitude];
}

- (void)presentFavoriteNamePromptForCoordinate:(CLLocationCoordinate2D)coordinate altitude:(double)altitude {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:GPSLabLocalized(@"favorites.add")
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        // A visible localized default the user can accept or replace.
        textField.text = GPSLabLocalized(@"favorites.defaultName");
        textField.placeholder = GPSLabLocalized(@"common.name");
    }];
    [alert addAction:[UIAlertAction actionWithTitle:GPSLabLocalized(@"common.cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    GPSLabOverlayViewController *__weak weakSelf = self;
    // Weak alert ref: the action block must not retain its own alert (cycle).
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:GPSLabLocalized(@"common.save")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        (void)action;
        GPSLabOverlayViewController *strongSelf = weakSelf;
        UIAlertController *strongAlert = weakAlert;
        if (strongSelf == nil || strongAlert == nil) {
            return;
        }
        // Revalidate and dedupe at the actual confirm (a preview may have moved or
        // a duplicate may have appeared while the prompt was open).
        if (!GPSLabIsValidCoordinate(coordinate.latitude, coordinate.longitude)) {
            [strongSelf presentFavoriteMessageKey:@"favorites.originRequired"];
            return;
        }
        NSString *name = [strongAlert.textFields.firstObject.text
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (name.length == 0) {
            name = GPSLabLocalized(@"favorites.defaultName");
        }
        GPSLabBookmark *bookmark = [GPSLabBookmark bookmarkWithName:name
                                                          coordinate:coordinate
                                                            altitude:altitude];
        if (![[GPSLabStore sharedStore] addBookmarkIfNotDuplicate:bookmark]) {
            [GPSLabStatusLog append:GPSLabLocalized(@"favorites.duplicate")];
            [strongSelf presentFavoriteMessageKey:@"favorites.duplicate"];
            [strongSelf updateFavoritesList];
            return;
        }
        [GPSLabStatusLog append:GPSLabLocalized(@"favorites.added")];
        [strongSelf updateFavoritesList];
    }]];
    [[GPSLabModalCoordinator sharedCoordinator] presentAlert:alert completion:nil];
}

/** Visible native message (the status log alone has no UI consumer). */
- (void)presentFavoriteMessageKey:(NSString *)key {
    NSString *message = GPSLabLocalized(key);
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:GPSLabLocalized(@"favorites.title")
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:GPSLabLocalized(@"common.ok")
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [[GPSLabModalCoordinator sharedCoordinator] presentAlert:alert completion:nil];
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
    // Draft only: editing the switch never touches the engine. Apply commits both
    // the enabled flag and the radius together.
    self.pendingDriftEnabled = self.driftSwitch.on;
    [self updateDriftRangeDisplay];
    [self updateStatusLabel];
}

- (void)driftRangeTapped {
    [self presentFluctuationSheet];
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
    [self.view endEditing:YES];
    if (self.staticRouteSegment.selectedSegmentIndex == 1) {
        [self startRouteFromPending];
        return;
    }
    if (self.hasPendingSelection) {
        // Commit the previewed selection through the existing engine path. The
        // draft is cleared only when the commit actually succeeds. The drift draft
        // is bundled into the same validated configuration inside applyCoordinate.
        BOOL applied = [self applyCoordinate:self.pendingCoordinate
                                    altitude:self.pendingAltitude
                                     heading:self.pendingHeading];
        if (applied) {
            [self clearPendingSelection];
        }
        [self endActiveSearch];
        return;
    }
    // No pending location: commit the drift draft through the valid anchor path.
    GPSLabConfiguration *configuration = [[GPSLabEngine sharedEngine] configuration];
    [self applyCoordinate:configuration.coordinate altitude:configuration.altitude heading:configuration.heading];
    [self endActiveSearch];
}

- (void)cancelTapped {
    [self.view endEditing:YES];
    [self endActiveSearch];
    [self clearPendingSelection];
    // Discard the drift draft and every other pending edit by resyncing from the
    // committed configuration (the engine is never written by a cancel).
    [self loadConfigurationIntoUI];
    [self updateTabVisibility];
}

/**
 * Reloads the overlay-owned drift draft/display from the COMMITTED configuration.
 * Called ONLY after a successful application; an edit never reaches the engine.
 */
- (void)syncDriftDraftFromCommittedConfiguration {
    GPSLabConfiguration *committed = [[GPSLabEngine sharedEngine] configuration];
    self.pendingDriftEnabled = committed.driftEnabled;
    self.pendingDriftRadius = committed.driftRadiusMeters;
    self.driftSwitch.on = committed.driftEnabled;
    [self updateDriftRangeDisplay];
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
    // A NEW profile captures the live master-switch state; an EDIT preserves the
    // profile's existing optional preference (never overwritten by unrelated live
    // state). Legacy profiles stay legacy on edit. Backward compatible.
    GPSLabProfile *toSave = profile;
    if (!editing) {
        toSave = [profile profileWithEnabledPreference:[GPSLabEngine sharedEngine].isEnabled];
    }
    GPSLabProfileStore *store = [GPSLabProfileStore sharedStore];
    NSError *error = nil;
    BOOL success = editing ? [store updateProfile:toSave error:&error]
                           : [store addProfile:toSave error:&error];
    if (!success) {
        [self presentErrorKey:(error.code == GPSLabProfileStoreErrorCapacity
                              ? @"profiles.error.capacity" : @"profiles.error.save")];
        return NO;
    }
    self.selectedProfileIdentifier = toSave.identifier;
    [store setSelectedProfileIdentifier:toSave.identifier error:NULL];
    [self reloadProfiles];
    [self rearmAppliedProfileIfNeeded:toSave];
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
    // Preflight WITHOUT touching the switch, so an invalid or locked profile can
    // never enable/disable the engine. The coordinator re-checks authoritatively.
    if (![profile isValidForApplication]) {
        [self presentErrorKey:@"profiles.error.invalid"];
        return;
    }
    if (![[GPSLabLicenseManager sharedManager] isUnlocked]) {
        [self presentErrorKey:@"profiles.error.locked"];
        return;
    }

    BOOL wasEnabled = [GPSLabEngine sharedEngine].isEnabled;
    // A profile apply claims the master-switch intent. Any newer intent — another
    // apply or a manual switch change — invalidates this one, so a superseded or
    // cancelled completion can never roll back or mutate newer state.
    NSUInteger intent = [self.masterIntentGuard beginIntent];

    // Explicitly DISABLED profile: after the gates, switch OFF, then stage the saved
    // configuration while OFF. The manual-disable intent is latched only when this
    // intent still owns the switch.
    if (profile.hasEnabledPreference && !profile.enabled) {
        BOOL switchWasChanged = wasEnabled;
        if (switchWasChanged) {
            [[GPSLabEngine sharedEngine] setEnabledAndNotify:NO];
            [self updateMasterAppearance];
        }
        GPSLabProfileApplicationCoordinator *coordinator = [GPSLabProfileApplicationCoordinator sharedCoordinator];
        __weak GPSLabOverlayViewController *weakSelf = self;
        [coordinator stageProfile:profile completion:^(GPSLabProfileApplicationResult *result) {
            GPSLabOverlayViewController *strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }
            GPSLabMasterIntentResolution resolution =
                [strongSelf.masterIntentGuard resolveIntent:intent
                                                     applied:result.applied
                                          switchWasChanged:switchWasChanged];
            if (resolution == GPSLabMasterIntentResolutionIgnoreStale) {
                return; // superseded/cancelled: no rollback, no UI, no schedule
            }
            if (resolution == GPSLabMasterIntentResolutionRollback) {
                [[GPSLabEngine sharedEngine] setEnabledAndNotify:YES];
                [strongSelf updateMasterAppearance];
                [strongSelf presentErrorKey:result.messageKey ?: @"profiles.error.invalid"];
                return;
            }
            if (resolution == GPSLabMasterIntentResolutionFailureNoChange) {
                [strongSelf presentErrorKey:result.messageKey ?: @"profiles.error.invalid"];
                return;
            }
            [[GPSLabScheduler sharedScheduler] noteManualEngineDisable];
            [GPSLabStatusLog append:GPSLabLocalized(@"overlay.engine.disabled")];
            [strongSelf updateMasterAppearance];
            [strongSelf applyStagedProfileUI:profile];
        }];
        return;
    }

    // Explicitly ENABLED profile: the gates passed, so it is now safe to restore
    // the switch. The completion rolls back ONLY while this intent still owns the
    // switch (a newer apply or manual change must not be clobbered).
    BOOL enabledSwitchChanged = profile.hasEnabledPreference && profile.enabled && !wasEnabled;
    if (enabledSwitchChanged) {
        [[GPSLabEngine sharedEngine] setEnabledAndNotify:YES];
        [GPSLabStatusLog append:GPSLabLocalized(@"overlay.engine.enabled")];
        [self updateMasterAppearance];
    }

    GPSLabProfileApplicationCoordinator *coordinator = [GPSLabProfileApplicationCoordinator sharedCoordinator];
    __weak GPSLabOverlayViewController *weakSelf = self;
    [coordinator applyProfile:profile completion:^(GPSLabProfileApplicationResult *result) {
        GPSLabOverlayViewController *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        GPSLabMasterIntentResolution resolution =
            [strongSelf.masterIntentGuard resolveIntent:intent
                                                 applied:result.applied
                                      switchWasChanged:enabledSwitchChanged];
        if (resolution == GPSLabMasterIntentResolutionIgnoreStale) {
            return; // superseded/cancelled: never touch newer state or the schedule
        }
        if (resolution == GPSLabMasterIntentResolutionRollback) {
            [[GPSLabEngine sharedEngine] setEnabledAndNotify:NO];
            [strongSelf updateMasterAppearance];
            [strongSelf presentErrorKey:result.messageKey ?: @"profiles.error.invalid"];
            return;
        }
        if (resolution == GPSLabMasterIntentResolutionFailureNoChange) {
            [strongSelf presentErrorKey:result.messageKey ?: @"profiles.error.invalid"];
            return;
        }
        strongSelf.appliedProfileIdentifier = profile.identifier;
        [[GPSLabScheduler sharedScheduler] armWithProfile:profile];
        // A profile apply commits its own anchor: drop any obsolete preview draft
        // so it cannot overshadow the freshly applied committed selection.
        [strongSelf clearPendingSelection];
        [strongSelf loadConfigurationIntoUI];
        [strongSelf updateMapFromState];
        [strongSelf scheduleBackgroundSnapshot];
    }];
}

/** Shows a staged (disabled) profile's configuration and pending route UI. */
- (void)applyStagedProfileUI:(GPSLabProfile *)profile {
    // A staged profile owns the committed anchor; an obsolete preview draft must
    // not overshadow it.
    [self clearPendingSelection];
    [self loadConfigurationIntoUI];
    [self updateMapFromState];
    // Restore the saved route endpoints + settings for an explicit later start.
    // A staged/disabled profile never auto-starts the route on enable.
    if (profile.locationMode == GPSLabProfileLocationRoute && profile.route != nil) {
        GPSLabProfileRoute *route = profile.route;
        self.pendingRouteStartItem = [self mapItemForCoordinate:CLLocationCoordinate2DMake(route.startLatitude, route.startLongitude)
                                                           name:GPSLabLocalized(@"route.annotation.start")];
        self.pendingRouteEndItem = [self mapItemForCoordinate:CLLocationCoordinate2DMake(route.endLatitude, route.endLongitude)
                                                         name:GPSLabLocalized(@"route.annotation.end")];
        self.routeModeSegment.selectedSegmentIndex = (NSInteger)route.mode;
        self.routeSpeedSlider.value = route.customSpeedKmh > 0.0 ? route.customSpeedKmh : 50.0;
        [self updateRouteAnnotations];
    }
    [self updateRouteControls];
    [self updateScheduleDisplay:profile.schedule];
    [self scheduleBackgroundSnapshot];
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
        [row setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];

        UIButton *menuButton = [UIButton buttonWithType:UIButtonTypeSystem];
        UIImageSymbolConfiguration *symbolConfiguration =
            [UIImageSymbolConfiguration configurationWithPointSize:15.0 weight:UIImageSymbolWeightSemibold];
        [menuButton setImage:[UIImage systemImageNamed:@"ellipsis" withConfiguration:symbolConfiguration]
                    forState:UIControlStateNormal];
        menuButton.tintColor = GPSLabThemeMutedColor();
        menuButton.showsMenuAsPrimaryAction = YES;
        menuButton.accessibilityLabel = GPSLabLocalized(@"favorites.manage");
        menuButton.menu = [self favoriteManagementMenuForBookmark:bookmark];
        [menuButton.widthAnchor constraintEqualToConstant:32.0].active = YES;
        [menuButton.heightAnchor constraintEqualToConstant:32.0].active = YES;
        [menuButton setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

        UIStackView *rowStack = [[UIStackView alloc] initWithArrangedSubviews:@[ row, menuButton ]];
        rowStack.axis = UILayoutConstraintAxisHorizontal;
        rowStack.alignment = UIStackViewAlignmentCenter;
        rowStack.spacing = 4.0;
        [self.favoritesList addArrangedSubview:rowStack];
    }
}

- (UIMenu *)favoriteManagementMenuForBookmark:(GPSLabBookmark *)bookmark {
    GPSLabOverlayViewController *__weak weakSelf = self;
    UIAction *rename = [UIAction actionWithTitle:GPSLabLocalized(@"common.rename")
                                           image:[UIImage systemImageNamed:@"pencil"]
                                      identifier:nil
                                         handler:^(UIAction *action) {
        (void)action;
        [weakSelf renameFavorite:bookmark];
    }];
    UIAction *delete = [UIAction actionWithTitle:GPSLabLocalized(@"common.delete")
                                           image:[UIImage systemImageNamed:@"trash"]
                                      identifier:nil
                                         handler:^(UIAction *action) {
        (void)action;
        [weakSelf deleteFavorite:bookmark];
    }];
    delete.attributes = UIMenuElementAttributesDestructive;
    return [UIMenu menuWithTitle:@"" children:@[ rename, delete ]];
}

/**
 * Resolves the captured bookmark against a freshly loaded list by content, so a
 * delayed rename/delete never writes a stale index. Old schema is untouched
 * (there are no stored identifiers); the captured object is matched carefully.
 */
- (NSInteger)indexOfFavoriteMatching:(GPSLabBookmark *)captured
                         inBookmarks:(NSArray<GPSLabBookmark *> *)bookmarks {
    if (captured == nil) {
        return -1;
    }
    for (NSUInteger index = 0; index < bookmarks.count; index++) {
        GPSLabBookmark *candidate = bookmarks[index];
        if (![candidate.name isEqualToString:captured.name]) {
            continue;
        }
        if (fabs(candidate.latitude - captured.latitude) > 1e-9) {
            continue;
        }
        if (fabs(candidate.longitude - captured.longitude) > 1e-9) {
            continue;
        }
        if (fabs(candidate.altitude - captured.altitude) > 1e-6) {
            continue;
        }
        return (NSInteger)index;
    }
    return -1;
}

- (void)renameFavorite:(GPSLabBookmark *)bookmark {
    if ([self indexOfFavoriteMatching:bookmark inBookmarks:[[GPSLabStore sharedStore] loadBookmarks]] < 0) {
        [self updateFavoritesList];
        return;
    }
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
    GPSLabOverlayViewController *__weak weakSelf = self;
    // Weak alert ref: the action block must not retain its own alert (cycle).
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:GPSLabLocalized(@"common.rename")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        (void)action;
        GPSLabOverlayViewController *strongSelf = weakSelf;
        UIAlertController *strongAlert = weakAlert;
        if (strongSelf == nil || strongAlert == nil) {
            return;
        }
        NSInteger current = [strongSelf indexOfFavoriteMatching:bookmark
                                                    inBookmarks:[[GPSLabStore sharedStore] loadBookmarks]];
        if (current < 0) {
            [strongSelf updateFavoritesList];
            return;
        }
        NSString *name = [strongAlert.textFields.firstObject.text
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        // A blank rename is a no-op: keep the existing name safely.
        if (name.length > 0) {
            [[GPSLabStore sharedStore] renameBookmarkAtIndex:(NSUInteger)current name:name];
        }
        [strongSelf updateFavoritesList];
    }]];
    [[GPSLabModalCoordinator sharedCoordinator] presentAlert:alert completion:nil];
}

- (void)deleteFavorite:(GPSLabBookmark *)bookmark {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:GPSLabLocalized(@"favorites.delete.title")
                                                                   message:bookmark.name
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:GPSLabLocalized(@"common.cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    GPSLabOverlayViewController *__weak weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:GPSLabLocalized(@"common.delete")
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
        (void)action;
        GPSLabOverlayViewController *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        NSInteger current = [strongSelf indexOfFavoriteMatching:bookmark
                                                    inBookmarks:[[GPSLabStore sharedStore] loadBookmarks]];
        if (current < 0) {
            [strongSelf updateFavoritesList];
            return;
        }
        [[GPSLabStore sharedStore] deleteBookmarkAtIndex:(NSUInteger)current];
        [strongSelf updateFavoritesList];
    }]];
    [[GPSLabModalCoordinator sharedCoordinator] presentAlert:alert completion:nil];
}

- (void)favoriteTapped:(UIButton *)sender {
    NSArray<GPSLabBookmark *> *bookmarks = [[GPSLabStore sharedStore] loadBookmarks];
    if (sender.tag < 0 || (NSUInteger)sender.tag >= bookmarks.count) {
        return;
    }
    GPSLabBookmark *bookmark = bookmarks[(NSUInteger)sender.tag];
    // The existing commit path also clears any obsolete preview draft.
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
    // The sheet is initialized from the DRAFT, and edits only the draft. Nothing
    // is written to the engine until the overlay's Apply.
    sheet.fluctuationEnabled = self.pendingDriftEnabled;
    sheet.radiusMeters = self.pendingDriftRadius;
    GPSLabOverlayViewController *__weak weakSelf = self;
    sheet.changeHandler = ^(BOOL enabled, double radiusMeters) {
        GPSLabOverlayViewController *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        strongSelf.pendingDriftEnabled = enabled;
        strongSelf.pendingDriftRadius = GPSLabClampDriftRadiusMeters(radiusMeters);
        // Auto-save the changed radius immediately (its own protected key), so the
        // last value survives a relaunch even without tapping Apply. This writes
        // ONLY the drift-radius preference, never the configuration/coordinate.
        [[GPSLabStore sharedStore] saveDriftRadiusMeters:strongSelf.pendingDriftRadius];
        strongSelf.driftSwitch.on = enabled;
        [strongSelf updateDriftRangeDisplay];
        [strongSelf updateStatusLabel];
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
        [weakSelf.masterIntentGuard invalidateIntents];
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
    options.accountHandler = ^{
        GPSLabOverlayViewController *strongSelf = weakSelf;
        if (strongSelf == nil) { return; }
        [[GPSLabModalCoordinator sharedCoordinator] dismissTopmostAnimated:YES completion:^{
            [strongSelf presentPortalSheet];
        }];
    };
    [[GPSLabModalCoordinator sharedCoordinator] presentSheetRoot:options completion:nil];
}

- (void)presentPortalSheet {
    GPSLabPortalViewController *portal = [[GPSLabPortalViewController alloc] init];
    [[GPSLabModalCoordinator sharedCoordinator] presentSheetRoot:portal completion:nil];
}

#pragma mark - Coordinate application

- (BOOL)applyCoordinate:(CLLocationCoordinate2D)coordinate altitude:(double)altitude {
    GPSLabConfiguration *configuration = [[GPSLabEngine sharedEngine] configuration];
    return [self applyCoordinate:coordinate altitude:altitude heading:configuration.heading];
}

- (BOOL)applyCoordinate:(CLLocationCoordinate2D)coordinate altitude:(double)altitude heading:(double)heading {
    // Validate the coordinate BEFORE touching any state: a failed Apply must not
    // commit the drift draft either.
    if (!GPSLabIsValidCoordinate(coordinate.latitude, coordinate.longitude)) {
        return NO;
    }
    GPSLabConfiguration *configuration = [[GPSLabEngine sharedEngine] configuration];
    configuration.latitude = coordinate.latitude;
    configuration.longitude = coordinate.longitude;
    configuration.altitude = GPSLabClampDouble(altitude, -500.0, 100000.0);
    configuration.heading = GPSLabNormalizeHeading(heading);
    // Bundle the drift draft into the SAME configuration passed to the engine, so a
    // successful Apply commits the enabled flag and the clamped radius together.
    configuration.driftEnabled = self.pendingDriftEnabled;
    configuration.driftRadiusMeters = GPSLabClampDriftRadiusMeters(self.pendingDriftRadius);
    [[GPSLabEngine sharedEngine] applyConfiguration:configuration];
    [[GPSLabEngine sharedEngine] persistConfiguration];
    // Only a successful application resyncs the draft/display from the committed,
    // sanitized configuration.
    [self syncDriftDraftFromCommittedConfiguration];
    // Record the committed coordinate (not a boolean) as proof of an intentional
    // selection, and add it to recents (legacy proof path).
    [[GPSLabStore sharedStore] recordCommittedSelection:
        [[GPSLabCommittedSelection alloc] initWithLatitude:coordinate.latitude
                                                 longitude:coordinate.longitude
                                                  altitude:configuration.altitude]];
    [[GPSLabStore sharedStore] addRecentCoordinate:coordinate altitude:configuration.altitude];
    // A manual anchor change invalidates any scheduled ownership.
    [[GPSLabProfileApplicationCoordinator sharedCoordinator] invalidateAppliedProfile];
    // Any explicit committed coordinate supersedes a stale preview draft.
    if (self.hasPendingSelection) {
        [self clearPendingSelection];
    }
    [self updateStatusLabel];
    [self updateMapFromState];
    [self scheduleBackgroundSnapshot];
    return YES;
}

- (void)updateMapFromState {
    if (self.hasPendingSelection) {
        // A preview pin must stay stable under engine notifications: the engine
        // anchor is only reflected on the map after Apply or Cancel resets it.
        return;
    }
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
    if (self.hasPendingSelection) {
        // Route Apply must honour the chosen altitude/heading through the existing
        // configuration -> synthetic path (applyConfiguration: sanitizes it).
        configuration.altitude = self.pendingAltitude;
        configuration.heading = self.pendingHeading;
    }
    configuration.routeMode = (GPSLabRouteMode)self.routeModeSegment.selectedSegmentIndex;
    configuration.routeCustomSpeedKmh = self.routeSpeedSlider.value;
    configuration.stopBehavior = (self.routeStopBehaviorSegment.selectedSegmentIndex == 1)
        ? GPSLabStopBehaviorReturnToStart : GPSLabStopBehaviorStayAtCurrent;
    // Endpoints were validated first; bundle the drift draft into the SAME
    // configuration so a route Apply commits the enabled flag and clamped radius.
    configuration.driftEnabled = self.pendingDriftEnabled;
    configuration.driftRadiusMeters = GPSLabClampDriftRadiusMeters(self.pendingDriftRadius);
    [[GPSLabEngine sharedEngine] applyConfiguration:configuration];
    // Only the applied configuration resyncs the draft/display.
    [self syncDriftDraftFromCommittedConfiguration];
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
    [self clearPendingSelection];
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
    [[GPSLabMapLinkResolver sharedResolver] cancel];
    searchBar.showsCancelButton = YES;
    [self setSearchResultsVisible:YES];
    if ([self searchHandleMapLinkInput:searchBar.text ?: @""]) {
        [self.searchResultsController cancelActiveSearch];
        [self setSearchResultsVisible:NO];
    } else {
        [self.searchResultsController updateSearchResultsForQuery:searchBar.text ?: @""];
    }
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    (void)searchBar;
    // EVERY input transition invalidates any in-flight link resolution, so a late
    // result from a superseded short link can never win.
    [[GPSLabMapLinkResolver sharedResolver] cancel];
    if (!GPSLabSearchSessionIsActive(&_searchSession)) {
        return;
    }
    if ([self searchHandleMapLinkInput:searchText ?: @""]) {
        // Switching to maps mode also drops any pending place search.
        [self.searchResultsController cancelActiveSearch];
        [self setSearchResultsVisible:NO];
    } else {
        [self setSearchResultsVisible:YES];
        [self.searchResultsController updateSearchResultsForQuery:searchText ?: @""];
    }
}

- (void)searchBarTextDidEndEditing:(UISearchBar *)searchBar {
    searchBar.showsCancelButton = GPSLabSearchSessionIsActive(&_searchSession) ? YES : NO;
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [[GPSLabMapLinkResolver sharedResolver] cancel];
    if (GPSLabSearchSessionCanCommit(&_searchSession)) {
        GPSLabSearchSessionCommit(&_searchSession);
    }
    if (![self searchHandleMapLinkInput:searchBar.text ?: @""]) {
        if (GPSLabSearchSessionIsActive(&_searchSession)) {
            [self.searchResultsController updateSearchResultsForQuery:searchBar.text ?: @""];
        }
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
    // Preview only: the map pin and coordinate readout move, but the synthetic
    // engine is not written until the user taps Apply.
    GPSLabConfiguration *configuration = [[GPSLabEngine sharedEngine] configuration];
    [self previewCoordinate:item.placemark.coordinate
              sourceKindKey:nil
                   altitude:configuration.altitude
                    heading:configuration.heading];
    [self endActiveSearch];
}

#pragma mark - Map-link search

- (GPSLabMapLink)mapLinkForText:(nullable NSString *)text {
    NSString *value = text ?: @"";
    return GPSLabMapLinkParseText(value.UTF8String, [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
}

- (nullable NSString *)sourceKindKeyForKind:(GPSLabMapLinkKind)kind {
    switch (kind) {
        case GPSLabMapLinkKindGoogle:
            return @"search.source.google";
        case GPSLabMapLinkKindApple:
            return @"search.source.apple";
        default:
            return nil;
    }
}

- (void)showSearchSourceWithText:(NSString *)text kindKey:(nullable NSString *)kindKey {
    self.searchSourceTextLabel.text = text;
    if (kindKey.length > 0) {
        self.searchSourceKindLabel.text = GPSLabLocalized(kindKey);
        self.searchSourceKindLabel.hidden = NO;
    } else {
        self.searchSourceKindLabel.text = @"";
        self.searchSourceKindLabel.hidden = YES;
    }
    self.searchSourceView.hidden = NO;
    self.searchSourceHeightConstraint.active = NO; // content-driven height
}

- (void)hideSearchSource {
    self.searchSourceView.hidden = YES;
    self.searchSourceHeightConstraint.active = YES; // collapse to zero
}

- (void)updateSearchSourceForText:(nullable NSString *)text {
    GPSLabMapLink link = [self mapLinkForText:text];
    switch (link.result) {
        case GPSLabMapLinkParseCoordinates:
        case GPSLabMapLinkParseURLWithCoordinates: {
            NSString *coords = [GPSLabLocalization coordinateStringWithLatitude:link.latitude
                                                                      longitude:link.longitude];
            [self showSearchSourceWithText:[NSString stringWithFormat:GPSLabLocalized(@"search.source.extracted"), coords]
                                   kindKey:[self sourceKindKeyForKind:link.kind]];
            break;
        }
        case GPSLabMapLinkParseShortLink:
            [self showSearchSourceWithText:GPSLabLocalized(@"search.source.short")
                                   kindKey:[self sourceKindKeyForKind:link.kind]];
            break;
        case GPSLabMapLinkParseRejected:
            [self showSearchSourceWithText:GPSLabLocalized(@"search.source.untrusted") kindKey:nil];
            break;
        case GPSLabMapLinkParseNone:
        default:
            [self hideSearchSource];
            break;
    }
}

/** Returns YES when the text is a maps link candidate (so no place search runs). */
- (BOOL)searchHandleMapLinkInput:(nullable NSString *)text {
    GPSLabMapLink link = [self mapLinkForText:text];
    switch (link.result) {
        case GPSLabMapLinkParseCoordinates: {
            NSString *coords = [GPSLabLocalization coordinateStringWithLatitude:link.latitude
                                                                      longitude:link.longitude];
            [self showSearchSourceWithText:[NSString stringWithFormat:GPSLabLocalized(@"search.source.extracted"), coords]
                                   kindKey:nil];
            [self previewCoordinate:CLLocationCoordinate2DMake(link.latitude, link.longitude)
                      sourceKindKey:nil];
            return YES;
        }
        case GPSLabMapLinkParseURLWithCoordinates: {
            NSString *kindKey = [self sourceKindKeyForKind:link.kind];
            NSString *coords = [GPSLabLocalization coordinateStringWithLatitude:link.latitude
                                                                      longitude:link.longitude];
            [self showSearchSourceWithText:[NSString stringWithFormat:GPSLabLocalized(@"search.source.extracted"), coords]
                                   kindKey:kindKey];
            [self previewCoordinate:CLLocationCoordinate2DMake(link.latitude, link.longitude)
                      sourceKindKey:kindKey];
            return YES;
        }
        case GPSLabMapLinkParseShortLink:
            [self showSearchSourceWithText:GPSLabLocalized(@"search.source.short")
                                   kindKey:[self sourceKindKeyForKind:link.kind]];
            [self resolveShortLink:(text ?: @"")];
            return YES;
        case GPSLabMapLinkParseRejected:
            [self showSearchSourceWithText:GPSLabLocalized(@"search.source.untrusted") kindKey:nil];
            return YES;
        case GPSLabMapLinkParseNone:
        default:
            [self hideSearchSource];
            return NO;
    }
}

- (void)resolveShortLink:(NSString *)text {
    GPSLabOverlayViewController *__weak weakSelf = self;
    [[GPSLabMapLinkResolver sharedResolver] resolveText:text
        completion:^(GPSLabMapLinkResolverResult *result) {
            GPSLabOverlayViewController *strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }
            // A late result after the session ended must never preview or banner.
            if (!GPSLabSearchSessionIsActive(&strongSelf->_searchSession)) {
                return;
            }
            if (result.isSuccess) {
                NSString *coords = [GPSLabLocalization coordinateStringWithLatitude:result.coordinate.latitude
                                                                          longitude:result.coordinate.longitude];
                [strongSelf showSearchSourceWithText:[NSString stringWithFormat:GPSLabLocalized(@"search.source.extracted"), coords]
                                           kindKey:result.sourceKindKey];
                [strongSelf previewCoordinate:result.coordinate sourceKindKey:result.sourceKindKey];
            } else {
                [strongSelf showSearchSourceWithText:GPSLabLocalized(@"search.source.untrusted") kindKey:nil];
            }
        }];
}

- (void)previewCoordinate:(CLLocationCoordinate2D)coordinate sourceKindKey:(nullable NSString *)kindKey {
    [self previewCoordinate:coordinate
              sourceKindKey:kindKey
                   altitude:[[GPSLabEngine sharedEngine] configuration].altitude
                    heading:[[GPSLabEngine sharedEngine] configuration].heading];
}

- (void)previewCoordinate:(CLLocationCoordinate2D)coordinate
            sourceKindKey:(nullable NSString *)kindKey
                 altitude:(double)altitude
                  heading:(double)heading {
    if (!GPSLabIsValidCoordinate(coordinate.latitude, coordinate.longitude)) {
        return;
    }
    // Preserve a user-edited pending altitude/heading across a new selection; only
    // fall back to the supplied (current engine) value when none is pending.
    double resolvedAltitude = self.hasPendingSelection ? self.pendingAltitude : altitude;
    double resolvedHeading = self.hasPendingSelection ? self.pendingHeading : heading;

    self.hasPendingSelection = YES;
    self.pendingCoordinate = coordinate;
    // Assign the ivar directly: the custom altitude setter persists the draft and
    // must not run while heading/provider are still stale (partially coherent).
    _pendingAltitude = resolvedAltitude;
    self.pendingHeading = resolvedHeading;
    self.pendingSourceKindKey = kindKey;
    // Move the pin AND the map region so the preview is actually visible.
    self.syntheticAnnotation.coordinate = coordinate;
    [self.mapView setRegion:MKCoordinateRegionMakeWithDistance(coordinate, 800.0, 800.0) animated:YES];
    [self updateStatusLabel];
    // Persist once, after every field is coherent.
    [self persistPendingSelection];
}

- (void)clearPendingSelection {
    self.hasPendingSelection = NO;
    self.pendingSourceKindKey = nil;
    [[GPSLabStore sharedStore] clearPendingSelection];
    [self updateStatusLabel];
    [self updateMapFromState];
}

#pragma mark - Pending selection persistence

/** Saves the current coherent preview as the persisted draft (UI state only). */
- (void)persistPendingSelection {
    if (!self.hasPendingSelection) {
        return;
    }
    if (!GPSLabSelectionFieldsValid(self.pendingCoordinate.latitude,
                                    self.pendingCoordinate.longitude,
                                    self.pendingAltitude,
                                    self.pendingHeading)) {
        return;
    }
    GPSLabPendingSelection *selection =
        [[GPSLabPendingSelection alloc] initWithLatitude:self.pendingCoordinate.latitude
                                              longitude:self.pendingCoordinate.longitude
                                               altitude:self.pendingAltitude
                                                heading:self.pendingHeading
                                            providerKey:self.pendingSourceKindKey];
    [[GPSLabStore sharedStore] savePendingSelection:selection];
}

/**
 * Restores a persisted draft into the UI once, without invoking the preview
 * route (so the engine is never written). The map pin/readout stay stable under
 * later engine/lifecycle updates because `hasPendingSelection` short-circuits
 * `updateMapFromState`.
 */
- (void)restorePendingSelection {
    GPSLabPendingSelection *selection = [[GPSLabStore sharedStore] loadPendingSelection];
    if (selection == nil) {
        return;
    }
    CLLocationCoordinate2D coordinate = CLLocationCoordinate2DMake(selection.latitude, selection.longitude);
    if (!GPSLabIsValidCoordinate(coordinate.latitude, coordinate.longitude)) {
        [[GPSLabStore sharedStore] clearPendingSelection];
        return;
    }
    self.hasPendingSelection = YES;
    self.pendingCoordinate = coordinate;
    _pendingAltitude = selection.altitude;
    self.pendingHeading = selection.heading;
    self.pendingSourceKindKey = selection.providerKey;
    self.syntheticAnnotation.coordinate = coordinate;
    [self.mapView setRegion:MKCoordinateRegionMakeWithDistance(coordinate, 800.0, 800.0) animated:YES];
    [self updateStatusLabel];
}

#pragma mark - Altitude

- (NSString *)altitudeStringForValue:(double)value {
    // POSIX/LTR with up to 3 decimals, trailing zeros trimmed (shared helper):
    // never unnecessarily truncate a fractional existing altitude.
    return [GPSLabLocalization trimmedDecimalString:value fractionDigits:3];
}

- (void)altitudeTapped {
    GPSLabConfiguration *configuration = [[GPSLabEngine sharedEngine] configuration];
    double current = self.hasPendingSelection ? self.pendingAltitude : configuration.altitude;
    // Reference-styled unit card presented through the existing sheet coordinator
    // (not UIAlertController). It validates finite/range itself and only calls back
    // with a valid value; it never writes the engine — setPendingAltitude: updates
    // the preview and the engine is written only on the main Apply.
    GPSLabAltitudeViewController *editor = [[GPSLabAltitudeViewController alloc] init];
    editor.initialValue = current;
    GPSLabOverlayViewController *__weak weakSelf = self;
    editor.applyHandler = ^(double value) {
        [weakSelf setPendingAltitude:value];
    };
    [[GPSLabModalCoordinator sharedCoordinator] presentSheetRoot:editor completion:nil];
}

- (void)setPendingAltitude:(double)altitude {
    // No new clamping is introduced here: the existing engine/profile path owns
    // range policy. Non-finite input is refused rather than silently coerced.
    if (!isfinite(altitude)) {
        return;
    }
    _pendingAltitude = altitude;
    if (!self.hasPendingSelection) {
        // Editing altitude alone previews the current anchor with the new value.
        GPSLabConfiguration *configuration = [[GPSLabEngine sharedEngine] configuration];
        self.hasPendingSelection = YES;
        self.pendingCoordinate = configuration.coordinate;
        self.pendingHeading = configuration.heading;
    }
    [self updateStatusLabel];
    // The altitude edit updates the persisted draft after the state is coherent.
    [self persistPendingSelection];
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
    // The background snapshot always matches the selected foreground map style.
    options.mapType = [self mapTypeForStyle:(GPSLabMapStyle)self.mapStyle];
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
    // A pending (preview) selection is displayed but not committed to the engine.
    CLLocationCoordinate2D displayCoordinate = configuration.coordinate;
    double displayAltitude = configuration.altitude;
    double displayHeading = configuration.heading;
    if (self.hasPendingSelection) {
        displayCoordinate = self.pendingCoordinate;
        displayAltitude = self.pendingAltitude;
        displayHeading = self.pendingHeading;
    }
    [GPSLabLocalization forceLeftToRight:self.coordsBigLabel];
    self.coordsBigLabel.text = [NSString stringWithFormat:@"%@ %.6f\n%@ %.6f",
                                GPSLabLocalized(@"panel.coord.latitude"),
                                displayCoordinate.latitude,
                                GPSLabLocalized(@"panel.coord.longitude"),
                                displayCoordinate.longitude];
    if (self.coordValueLabels.count >= 3) {
        self.coordValueLabels[0].text = [GPSLabLocalization decimalString:displayCoordinate.latitude fractionDigits:5];
        self.coordValueLabels[1].text = [GPSLabLocalization decimalString:displayCoordinate.longitude fractionDigits:5];
        self.coordValueLabels[2].text = [self altitudeStringForValue:displayAltitude];
    }
    self.headingView.heading = displayHeading;
    self.headingValueLabel.text = [NSString stringWithFormat:GPSLabLocalized(@"panel.heading.format"),
                                   [NSString stringWithFormat:@"°%03.0f", displayHeading < 0.0 ? 0.0 : displayHeading]];
    self.driftSwitch.on = self.pendingDriftEnabled;
    self.keepLastSwitch.on = configuration.keepLastCoordinate;
    self.driftRangeCaptionLabel.text = GPSLabLocalized(@"panel.drift.range");
    [self updateDriftRangeDisplay];
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
