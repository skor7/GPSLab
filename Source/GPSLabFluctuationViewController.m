//
//  GPSLabFluctuationViewController.m
//  GPSLab
//
//  Drift controls. Reporting is via `changeHandler`; the canvas applies it through
//  GPSLabEngine so clamping/persistence stay in one place.
//

#import "GPSLabFluctuationViewController.h"

#import "GPSLabLocalization.h"

@interface GPSLabFluctuationViewController ()
@property (nonatomic, strong) UISwitch *enabledSwitch;
@property (nonatomic, strong) UISlider *radiusSlider;
@property (nonatomic, strong) UILabel *radiusValueLabel;
@property (nonatomic, strong) UILabel *sectionHeader;
@property (nonatomic, strong) UILabel *enabledLabel;
@end

@implementation GPSLabFluctuationViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.enabledSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
    self.enabledSwitch.on = self.fluctuationEnabled;
    [self.enabledSwitch addTarget:self
                           action:@selector(toggleChanged)
                 forControlEvents:UIControlEventValueChanged];

    self.enabledLabel = [self bodyLabel:@""];
    UIStackView *enabledRow = [[UIStackView alloc] initWithArrangedSubviews:@[self.enabledLabel,
                                                                              [UIView new],
                                                                              self.enabledSwitch]];
    enabledRow.axis = UILayoutConstraintAxisHorizontal;
    enabledRow.alignment = UIStackViewAlignmentCenter;
    enabledRow.spacing = 8.0;

    self.radiusSlider = [[UISlider alloc] initWithFrame:CGRectZero];
    self.radiusSlider.minimumValue = 1.0;
    self.radiusSlider.maximumValue = 100.0;
    self.radiusSlider.value = (float)self.radiusMeters;
    [self.radiusSlider addTarget:self
                          action:@selector(radiusChanged)
                forControlEvents:UIControlEventValueChanged];

    self.radiusValueLabel = [self bodyLabel:@""];
    self.radiusValueLabel.textAlignment = NSTextAlignmentRight;
    [GPSLabLocalization forceLeftToRight:self.radiusValueLabel];

    UIStackView *sliderRow = [[UIStackView alloc] initWithArrangedSubviews:@[self.radiusSlider,
                                                                             self.radiusValueLabel]];
    sliderRow.axis = UILayoutConstraintAxisHorizontal;
    sliderRow.alignment = UIStackViewAlignmentCenter;
    sliderRow.spacing = 8.0;

    self.sectionHeader = [self sectionHeaderLabel:@""];

    UIStackView *content = self.contentStack;
    [content addArrangedSubview:self.sectionHeader];
    [content addArrangedSubview:enabledRow];
    [content addArrangedSubview:sliderRow];

    [self gpslab_applyLocalization];
}

#pragma mark - Localization

- (void)gpslab_applyLocalization {
    self.title = GPSLabLocalized(@"fluctuation.title");
    self.sectionHeader.text = GPSLabLocalized(@"fluctuation.section");
    self.enabledLabel.text = GPSLabLocalized(@"fluctuation.boundedWalk");
    self.enabledSwitch.accessibilityLabel = GPSLabLocalized(@"fluctuation.boundedWalk");
    self.radiusSlider.accessibilityLabel = GPSLabLocalized(@"fluctuation.radius");
    [self updateRadiusLabel];
    [GPSLabLocalization applyLanguageAttributesToView:self.view];
}

- (void)updateRadiusLabel {
    NSString *format = GPSLabLocalized(@"fluctuation.radiusFormat");
    self.radiusValueLabel.text = [NSString stringWithFormat:format, (double)self.radiusSlider.value];
}

#pragma mark - Actions

- (void)toggleChanged {
    [self notifyChange];
}

- (void)radiusChanged {
    [self updateRadiusLabel];
    [self notifyChange];
}

- (void)notifyChange {
    if (self.changeHandler != nil) {
        self.changeHandler(self.enabledSwitch.on, (double)self.radiusSlider.value);
    }
}

@end
