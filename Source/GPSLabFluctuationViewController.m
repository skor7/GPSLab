//
//  GPSLabFluctuationViewController.m
//  GPSLab
//
//  Compact Arabic drift control: a التذبذب label, a 0..20 m radius slider with a
//  live "<n> م" readout, and the bounded-walk toggle. Reporting is via
//  `changeHandler`, which the overlay uses to update its OWN draft only; the
//  engine is written later by the overlay's Apply (clamping/persistence stay in
//  the engine). Editing the slider NEVER touches the engine.
//

#import "GPSLabFluctuationViewController.h"

#import "GPSLabLocalization.h"
#import "GPSLabTypes.h"

@interface GPSLabFluctuationViewController ()
@property (nonatomic, strong) UISwitch *enabledSwitch;
@property (nonatomic, strong) UISlider *radiusSlider;
@property (nonatomic, strong) UILabel *radiusValueLabel;
@property (nonatomic, strong) UILabel *sectionHeader;
@property (nonatomic, strong) UILabel *enabledLabel;
@property (nonatomic, strong) UIStackView *sliderRow;
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
    self.radiusSlider.minimumValue = (float)GPSLabMinDriftRadiusMeters();
    self.radiusSlider.maximumValue = (float)GPSLabMaxDriftRadiusMeters();
    // Preserve (and clamp) the current value; a legacy larger radius shows as the bound.
    self.radiusSlider.value = (float)GPSLabClampDriftRadiusMeters(self.radiusMeters);
    self.radiusSlider.continuous = YES;
    self.radiusSlider.accessibilityLabel = GPSLabLocalized(@"fluctuation.radius");
    [self.radiusSlider addTarget:self
                          action:@selector(radiusChanged)
                forControlEvents:UIControlEventValueChanged];

    self.radiusValueLabel = [self bodyLabel:@""];
    self.radiusValueLabel.textAlignment = NSTextAlignmentRight;
    [GPSLabLocalization forceLeftToRight:self.radiusValueLabel];

    self.sliderRow = [[UIStackView alloc] initWithArrangedSubviews:@[self.radiusSlider,
                                                                    self.radiusValueLabel]];
    self.sliderRow.axis = UILayoutConstraintAxisHorizontal;
    self.sliderRow.alignment = UIStackViewAlignmentCenter;
    self.sliderRow.spacing = 8.0;

    self.sectionHeader = [self sectionHeaderLabel:@""];

    UIStackView *content = self.contentStack;
    [content addArrangedSubview:self.sectionHeader];
    [content addArrangedSubview:enabledRow];
    [content addArrangedSubview:self.sliderRow];

    [self gpslab_applyLocalization];
    [self updateEnabledAppearance];
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

// The radius control is only meaningful while drift is on; dim it and stop it
// receiving touches when drift is off, but keep its value so nothing is lost.
- (void)updateEnabledAppearance {
    BOOL enabled = self.enabledSwitch.on;
    self.sliderRow.alpha = enabled ? 1.0 : 0.4;
    self.sliderRow.userInteractionEnabled = enabled;
    self.radiusSlider.enabled = enabled;
    self.radiusValueLabel.alpha = enabled ? 1.0 : 0.4;
}

#pragma mark - Actions

- (void)toggleChanged {
    [self updateEnabledAppearance];
    [self notifyChange];
}

- (void)radiusChanged {
    [self updateRadiusLabel];
    [self notifyChange];
}

- (void)notifyChange {
    if (self.changeHandler != nil) {
        // The slider only edits the radius: it forwards the toggle's current state,
        // so moving the slider must never enable the engine by itself.
        self.changeHandler(self.enabledSwitch.on, (double)self.radiusSlider.value);
    }
}

@end
