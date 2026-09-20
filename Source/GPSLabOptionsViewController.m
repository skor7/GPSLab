//
//  GPSLabOptionsViewController.m
//  GPSLab
//
//  Options hub. Destination sheets are requested through handlers so the canvas owns
//  presentation and dismissal; preferences are applied through handlers too.
//  The language picker is native and updates every active screen immediately
//  through the GPSLab localization notification (no root rebuild).
//

#import "GPSLabOptionsViewController.h"

#import "GPSLabLocalization.h"

@interface GPSLabOptionsViewController ()
@property (nonatomic, strong) UISwitch *keepLastSwitch;
@property (nonatomic, strong) UISwitch *realLocationSwitch;
@property (nonatomic, strong) UISegmentedControl *mapStyleControl;
@property (nonatomic, strong) UISegmentedControl *languageControl;

@property (nonatomic, strong) UIButton *manualButton;
@property (nonatomic, strong) UIButton *recentsButton;
@property (nonatomic, strong) UIButton *fluctuationButton;
@property (nonatomic, strong) UILabel *anchorHeader;
@property (nonatomic, strong) UILabel *preferencesHeader;
@property (nonatomic, strong) UILabel *mapStyleHeader;
@property (nonatomic, strong) UILabel *languageHeader;
@property (nonatomic, strong) UILabel *keepLastLabel;
@property (nonatomic, strong) UILabel *realLocationLabel;
@property (nonatomic, strong) UILabel *subscriptionHeader;
@property (nonatomic, strong) UILabel *subscriptionBody;
@end

@implementation GPSLabOptionsViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.manualButton = [self actionButtonWithTitle:@"" action:@selector(manualTapped)];
    self.recentsButton = [self actionButtonWithTitle:@"" action:@selector(recentsTapped)];
    self.fluctuationButton = [self actionButtonWithTitle:@"" action:@selector(fluctuationTapped)];

    self.keepLastSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
    self.keepLastSwitch.on = self.keepLastCoordinate;
    [self.keepLastSwitch addTarget:self
                            action:@selector(keepLastChanged)
                  forControlEvents:UIControlEventValueChanged];

    self.realLocationSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
    self.realLocationSwitch.on = self.realLocationEnabled;
    [self.realLocationSwitch addTarget:self
                                action:@selector(realLocationChanged)
                      forControlEvents:UIControlEventValueChanged];

    self.mapStyleControl = [[UISegmentedControl alloc] initWithItems:@[@"", @"", @""]];
    self.mapStyleControl.selectedSegmentIndex = self.mapStyle;
    [self.mapStyleControl addTarget:self
                             action:@selector(mapStyleChanged)
                   forControlEvents:UIControlEventValueChanged];

    self.languageControl = [[UISegmentedControl alloc] initWithItems:@[@"", @""]];
    self.languageControl.selectedSegmentIndex =
        ([GPSLabLocalization currentLanguage] == GPSLabLanguageEnglish) ? 1 : 0;
    [self.languageControl addTarget:self
                             action:@selector(languageChanged)
                   forControlEvents:UIControlEventValueChanged];

    self.anchorHeader = [self sectionHeaderLabel:@""];
    self.preferencesHeader = [self sectionHeaderLabel:@""];
    self.mapStyleHeader = [self sectionHeaderLabel:@""];
    self.languageHeader = [self sectionHeaderLabel:@""];
    self.keepLastLabel = [self bodyLabel:@""];
    self.realLocationLabel = [self bodyLabel:@""];

    UIStackView *content = self.contentStack;
    [content addArrangedSubview:self.anchorHeader];
    [content addArrangedSubview:self.manualButton];
    [content addArrangedSubview:self.recentsButton];
    [content addArrangedSubview:self.fluctuationButton];
    [content addArrangedSubview:self.preferencesHeader];
    [content addArrangedSubview:[self gpslab_rowWithLabel:self.keepLastLabel control:self.keepLastSwitch]];
    [content addArrangedSubview:[self gpslab_rowWithLabel:self.realLocationLabel
                                                  control:self.realLocationSwitch]];
    [content addArrangedSubview:self.mapStyleHeader];
    [content addArrangedSubview:self.mapStyleControl];
    [content addArrangedSubview:self.languageHeader];
    [content addArrangedSubview:self.languageControl];

    // Active is deliberately silent; only a meaningful status (e.g. grace) is shown here.
    if (self.subscriptionStatusText.length > 0) {
        self.subscriptionHeader = [self sectionHeaderLabel:@""];
        self.subscriptionBody = [self bodyLabel:self.subscriptionStatusText];
        [content addArrangedSubview:self.subscriptionHeader];
        [content addArrangedSubview:self.subscriptionBody];
    }

    [self gpslab_applyLocalization];
}

- (UIStackView *)gpslab_rowWithLabel:(UILabel *)label control:(UIView *)control {
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[label, [UIView new], control]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 8.0;
    return row;
}

#pragma mark - Localization

- (void)gpslab_applyLocalization {
    self.title = GPSLabLocalized(@"options.title");
    [self.manualButton setTitle:GPSLabLocalized(@"options.manual") forState:UIControlStateNormal];
    [self.recentsButton setTitle:GPSLabLocalized(@"options.recents") forState:UIControlStateNormal];
    [self.fluctuationButton setTitle:GPSLabLocalized(@"options.fluctuation")
                            forState:UIControlStateNormal];
    self.anchorHeader.text = GPSLabLocalized(@"options.section.anchor");
    self.preferencesHeader.text = GPSLabLocalized(@"options.section.preferences");
    self.mapStyleHeader.text = GPSLabLocalized(@"options.section.mapStyle");
    self.languageHeader.text = GPSLabLocalized(@"options.section.language");
    self.keepLastLabel.text = GPSLabLocalized(@"options.keepLast");
    self.realLocationLabel.text = GPSLabLocalized(@"options.realLocation");
    self.keepLastSwitch.accessibilityLabel = GPSLabLocalized(@"options.keepLast");
    self.realLocationSwitch.accessibilityLabel = GPSLabLocalized(@"options.realLocation");

    if (self.mapStyleControl.numberOfSegments >= 3) {
        [self.mapStyleControl setTitle:GPSLabLocalized(@"map.style.standard") forSegmentAtIndex:0];
        [self.mapStyleControl setTitle:GPSLabLocalized(@"map.style.hybrid") forSegmentAtIndex:1];
        [self.mapStyleControl setTitle:GPSLabLocalized(@"map.style.satellite") forSegmentAtIndex:2];
    }
    if (self.languageControl.numberOfSegments >= 2) {
        [self.languageControl setTitle:GPSLabLocalized(@"options.language.arabic") forSegmentAtIndex:0];
        [self.languageControl setTitle:GPSLabLocalized(@"options.language.english") forSegmentAtIndex:1];
    }
    self.languageControl.selectedSegmentIndex =
        ([GPSLabLocalization currentLanguage] == GPSLabLanguageEnglish) ? 1 : 0;

    if (self.subscriptionHeader != nil) {
        self.subscriptionHeader.text = GPSLabLocalized(@"options.section.subscription");
        self.subscriptionBody.text = self.subscriptionStatusText;
    }

    [GPSLabLocalization applyLanguageAttributesToView:self.view];
}

#pragma mark - Actions

- (void)manualTapped {
    if (self.manualEntryHandler != nil) {
        self.manualEntryHandler();
    }
}

- (void)recentsTapped {
    if (self.recentsHandler != nil) {
        self.recentsHandler();
    }
}

- (void)fluctuationTapped {
    if (self.fluctuationHandler != nil) {
        self.fluctuationHandler();
    }
}

- (void)keepLastChanged {
    if (self.keepLastHandler != nil) {
        self.keepLastHandler(self.keepLastSwitch.on);
    }
}

- (void)realLocationChanged {
    if (self.realLocationHandler != nil) {
        self.realLocationHandler(self.realLocationSwitch.on);
    }
}

- (void)mapStyleChanged {
    if (self.mapStyleHandler != nil) {
        self.mapStyleHandler(self.mapStyleControl.selectedSegmentIndex);
    }
}

- (void)languageChanged {
    GPSLabLanguageCode language = (self.languageControl.selectedSegmentIndex == 1)
        ? GPSLabLanguageEnglish
        : GPSLabLanguageArabic;
    // Persists and broadcasts; every active GPSLab screen re-applies its own strings.
    [GPSLabLocalization setLanguage:language];
}

@end
