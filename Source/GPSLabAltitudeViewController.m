//
//  GPSLabAltitudeViewController.m
//  GPSLab
//

#import "GPSLabAltitudeViewController.h"

#import <math.h>

#import "GPSLabLocalization.h"
#import "GPSLabProfile.h" // GPSLabProfileAltitudeValid (shared range policy)

@interface GPSLabAltitudeViewController () <UITextFieldDelegate>

@property (nonatomic, strong) UITextField *valueField;
@property (nonatomic, strong) UILabel *unitLabel;
@property (nonatomic, strong) UILabel *noteLabel;
@property (nonatomic, strong) UILabel *errorLabel;
@property (nonatomic, strong) UIButton *zeroButton;
@property (nonatomic, strong) UIButton *applyButton;
@property (nonatomic, strong) UIButton *cancelButton;

@end

@implementation GPSLabAltitudeViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = GPSLabLocalized(@"altitude.title");

    UITextField *field = [self decimalFieldWithPlaceholder:GPSLabLocalized(@"altitude.field")];
    field.textAlignment = NSTextAlignmentCenter;
    field.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle2];
    field.adjustsFontForContentSizeCategory = YES;
    field.delegate = self;
    field.text = [GPSLabLocalization trimmedDecimalString:self.initialValue fractionDigits:3];
    self.valueField = field;

    self.unitLabel = [self bodyLabel:GPSLabLocalized(@"altitude.unit")];
    self.unitLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle3];

    // Card matching the reference `.altitude-card`: an input row with a meter unit.
    UIView *card = [[UIView alloc] initWithFrame:CGRectZero];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    card.layer.cornerRadius = 16.0;
    card.layer.masksToBounds = YES;

    UIStackView *inputRow = [[UIStackView alloc] initWithArrangedSubviews:@[ field, self.unitLabel ]];
    inputRow.axis = UILayoutConstraintAxisHorizontal;
    inputRow.alignment = UIStackViewAlignmentCenter;
    inputRow.spacing = 8.0;
    inputRow.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:inputRow];
    [NSLayoutConstraint activateConstraints:@[
        [inputRow.topAnchor constraintEqualToAnchor:card.topAnchor constant:14.0],
        [inputRow.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-14.0],
        [inputRow.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14.0],
        [inputRow.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14.0],
    ]];
    [self.contentStack addArrangedSubview:card];

    self.noteLabel = [self bodyLabel:GPSLabLocalized(@"altitude.note")];
    self.noteLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    self.noteLabel.textColor = UIColor.secondaryLabelColor;
    [self.contentStack addArrangedSubview:self.noteLabel];

    self.errorLabel = [self bodyLabel:@""];
    self.errorLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    self.errorLabel.textColor = UIColor.systemRedColor;
    self.errorLabel.hidden = YES;
    [self.contentStack addArrangedSubview:self.errorLabel];

    self.zeroButton = [self altitudeActionButtonWithKey:@"altitude.zero" action:@selector(zeroTapped)];
    self.applyButton = [self altitudeActionButtonWithKey:@"altitude.apply" action:@selector(applyTapped)];
    self.cancelButton = [self altitudeActionButtonWithKey:@"common.cancel" action:@selector(cancelTapped)];
    self.applyButton.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];

    UIStackView *actions = [[UIStackView alloc] initWithArrangedSubviews:@[ self.cancelButton, self.zeroButton, self.applyButton ]];
    actions.axis = UILayoutConstraintAxisHorizontal;
    actions.distribution = UIStackViewDistributionFillEqually;
    actions.spacing = 8.0;
    [self.contentStack addArrangedSubview:actions];

    [self gpslab_applyLocalization];
}

- (UIButton *)altitudeActionButtonWithKey:(NSString *)key action:(SEL)action {
    UIButton *button = [self actionButtonWithTitle:GPSLabLocalized(key) action:action];
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
    return button;
}

- (void)gpslab_applyLocalization {
    self.title = GPSLabLocalized(@"altitude.title");
    if (self.valueField != nil) {
        self.valueField.placeholder = GPSLabLocalized(@"altitude.field");
        self.unitLabel.text = GPSLabLocalized(@"altitude.unit");
        self.noteLabel.text = GPSLabLocalized(@"altitude.note");
        [self.zeroButton setTitle:GPSLabLocalized(@"altitude.zero") forState:UIControlStateNormal];
        [self.applyButton setTitle:GPSLabLocalized(@"altitude.apply") forState:UIControlStateNormal];
        [self.cancelButton setTitle:GPSLabLocalized(@"common.cancel") forState:UIControlStateNormal];
    }
    [GPSLabLocalization applyLanguageAttributesToView:self.view];
    // The numeric input is technical text: always LTR.
    [GPSLabLocalization forceLeftToRight:self.valueField];
}

#pragma mark - Actions

- (void)cancelTapped {
    [self.view endEditing:YES];
    [self gpslab_dismissSheet];
}

- (void)zeroTapped {
    [self.view endEditing:YES];
    self.valueField.text = @"0";
    [self commitValue:0.0];
}

- (void)applyTapped {
    [self.view endEditing:YES];
    double value = 0.0;
    if (![GPSLabLocalization parseNumber:self.valueField.text value:&value] || !isfinite(value)) {
        [self showErrorKey:@"altitude.error.invalid"];
        return;
    }
    [self commitValue:value];
}

- (void)commitValue:(double)value {
    // Same range policy the engine/profile path enforces: fail loudly, never
    // silently accept then let the engine alter the value.
    if (!GPSLabProfileAltitudeValid(value)) {
        [self showErrorKey:@"altitude.error.range"];
        return;
    }
    self.errorLabel.hidden = YES;
    void (^handler)(double) = self.applyHandler;
    [self gpslab_dismissSheet];
    if (handler != nil) {
        handler(value);
    }
}

- (void)showErrorKey:(NSString *)key {
    self.errorLabel.text = GPSLabLocalized(key);
    self.errorLabel.hidden = NO;
}

#pragma mark - UITextFieldDelegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    [self applyTapped];
    return YES;
}

@end
