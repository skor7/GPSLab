//
//  GPSLabFluctuationViewController.m
//  GPSLab
//
//  Drift controls. Reporting is via `changeHandler`; the canvas applies it through
//  GPSLabEngine so clamping/persistence stay in one place.
//

#import "GPSLabFluctuationViewController.h"

@interface GPSLabFluctuationViewController ()
@property (nonatomic, strong) UISwitch *enabledSwitch;
@property (nonatomic, strong) UISlider *radiusSlider;
@property (nonatomic, strong) UILabel *radiusValueLabel;
@end

@implementation GPSLabFluctuationViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Location fluctuation";

    self.enabledSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
    self.enabledSwitch.on = self.fluctuationEnabled;
    [self.enabledSwitch addTarget:self
                           action:@selector(toggleChanged)
                 forControlEvents:UIControlEventValueChanged];
    UIStackView *enabledRow = [self rowWithTitle:@"Bounded random walk" control:self.enabledSwitch];

    self.radiusSlider = [[UISlider alloc] initWithFrame:CGRectZero];
    self.radiusSlider.minimumValue = 1.0;
    self.radiusSlider.maximumValue = 100.0;
    self.radiusSlider.value = (float)self.radiusMeters;
    [self.radiusSlider addTarget:self
                          action:@selector(radiusChanged)
                forControlEvents:UIControlEventValueChanged];

    self.radiusValueLabel = [self bodyLabel:[NSString stringWithFormat:@"%.0f m", self.radiusMeters]];
    self.radiusValueLabel.textAlignment = NSTextAlignmentRight;

    UIStackView *sliderRow = [[UIStackView alloc] initWithArrangedSubviews:@[self.radiusSlider,
                                                                             self.radiusValueLabel]];
    sliderRow.axis = UILayoutConstraintAxisHorizontal;
    sliderRow.alignment = UIStackViewAlignmentCenter;
    sliderRow.spacing = 8.0;

    UIStackView *content = self.contentStack;
    [content addArrangedSubview:[self sectionHeaderLabel:@"Fluctuation"]];
    [content addArrangedSubview:enabledRow];
    [content addArrangedSubview:sliderRow];
}

- (void)toggleChanged {
    [self notifyChange];
}

- (void)radiusChanged {
    self.radiusValueLabel.text = [NSString stringWithFormat:@"%.0f m", self.radiusSlider.value];
    [self notifyChange];
}

- (void)notifyChange {
    if (self.changeHandler != nil) {
        self.changeHandler(self.enabledSwitch.on, (double)self.radiusSlider.value);
    }
}

@end
