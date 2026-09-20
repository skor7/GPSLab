//
//  GPSLabProfilesPanelView.m
//  GPSLab
//

#import "GPSLabProfilesPanelView.h"

// UIButton.contentEdgeInsets is deprecated under UIButtonConfiguration (iOS 15)
// but remains the supported API for the plain, configuration-less buttons used
// here. The deprecation is suppressed narrowly for this file.
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

#import "GPSLabLocalization.h"
#import "GPSLabTheme.h"

@interface GPSLabProfilesPanelView ()

@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIButton *addButton;
@property (nonatomic, strong) UIScrollView *chipScroll;
@property (nonatomic, strong) UIStackView *chipRow;
@property (nonatomic, strong) UILabel *emptyLabel;

@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIStackView *summaryGrid;
@property (nonatomic, copy) NSArray<UILabel *> *summaryCaptionLabels;
@property (nonatomic, copy) NSArray<UILabel *> *summaryValueLabels;
@property (nonatomic, strong) UIButton *editButton;
@property (nonatomic, strong) UIButton *applyButton;

@property (nonatomic, copy) NSArray<GPSLabProfile *> *profiles;
@property (nonatomic, copy, nullable) NSString *selectedIdentifier;

@end

@implementation GPSLabProfilesPanelView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self build];
        [self applyLocalization];
    }
    return self;
}

- (void)build {
    self.backgroundColor = GPSLabThemeCardColor();
    GPSLabThemeApplyCardStyle(self, 24.0);

    self.titleLabel = [self labelWithFont:GPSLabThemeFont(18.0, UIFontWeightSemibold)];
    self.addButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.addButton.titleLabel.font = GPSLabThemeFont(13.0, UIFontWeightSemibold);
    [self.addButton setTitleColor:GPSLabThemeAccentSoftColor() forState:UIControlStateNormal];
    self.addButton.backgroundColor = GPSLabThemeChipColor();
    self.addButton.layer.cornerRadius = 11.0;
    self.addButton.layer.borderWidth = 0.5;
    self.addButton.layer.borderColor = [GPSLabThemeAccentColor() colorWithAlphaComponent:0.35].CGColor;
    self.addButton.contentEdgeInsets = UIEdgeInsetsMake(8.0, 11.0, 8.0, 11.0);
    [self.addButton addTarget:self action:@selector(addTapped) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[ self.titleLabel, [UIView new], self.addButton ]];
    header.axis = UILayoutConstraintAxisHorizontal;
    header.alignment = UIStackViewAlignmentCenter;
    header.spacing = 12.0;

    self.chipScroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    self.chipScroll.showsHorizontalScrollIndicator = NO;
    self.chipRow = [[UIStackView alloc] initWithFrame:CGRectZero];
    self.chipRow.axis = UILayoutConstraintAxisHorizontal;
    self.chipRow.spacing = 9.0;
    self.chipRow.translatesAutoresizingMaskIntoConstraints = NO;
    [self.chipScroll addSubview:self.chipRow];
    [NSLayoutConstraint activateConstraints:@[
        [self.chipRow.topAnchor constraintEqualToAnchor:self.chipScroll.contentLayoutGuide.topAnchor],
        [self.chipRow.bottomAnchor constraintEqualToAnchor:self.chipScroll.contentLayoutGuide.bottomAnchor],
        [self.chipRow.leadingAnchor constraintEqualToAnchor:self.chipScroll.contentLayoutGuide.leadingAnchor],
        [self.chipRow.trailingAnchor constraintEqualToAnchor:self.chipScroll.contentLayoutGuide.trailingAnchor],
        [self.chipRow.heightAnchor constraintEqualToAnchor:self.chipScroll.frameLayoutGuide.heightAnchor],
        [self.chipScroll.heightAnchor constraintEqualToConstant:64.0],
    ]];

    self.emptyLabel = [self labelWithFont:GPSLabThemeFont(13.0, UIFontWeightRegular)];
    self.emptyLabel.textColor = GPSLabThemeMutedColor();
    self.emptyLabel.numberOfLines = 0;

    // Summary
    self.nameLabel = [self labelWithFont:GPSLabThemeFont(17.0, UIFontWeightSemibold)];
    self.statusLabel = [self labelWithFont:GPSLabThemeFont(12.0, UIFontWeightSemibold)];
    self.statusLabel.textColor = GPSLabThemeGreenColor();
    UIStackView *summaryHead = [[UIStackView alloc] initWithArrangedSubviews:@[ self.nameLabel, [UIView new], self.statusLabel ]];
    summaryHead.axis = UILayoutConstraintAxisHorizontal;
    summaryHead.alignment = UIStackViewAlignmentCenter;
    summaryHead.spacing = 10.0;

    self.summaryGrid = [[UIStackView alloc] initWithFrame:CGRectZero];
    self.summaryGrid.axis = UILayoutConstraintAxisVertical;
    self.summaryGrid.spacing = 8.0;

    self.editButton = [self actionButtonWithTitle:@"" background:GPSLabColorFromHex(0x2A2A30) gradient:NO];
    [self.editButton addTarget:self action:@selector(editTapped) forControlEvents:UIControlEventTouchUpInside];
    self.applyButton = [self actionButtonWithTitle:@"" background:GPSLabThemeAccentColor() gradient:YES];
    [self.applyButton addTarget:self action:@selector(applyTapped) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *actions = [[UIStackView alloc] initWithArrangedSubviews:@[ self.editButton, self.applyButton ]];
    actions.axis = UILayoutConstraintAxisHorizontal;
    actions.distribution = UIStackViewDistributionFillEqually;
    actions.spacing = 9.0;

    UIStackView *summary = [[UIStackView alloc] initWithArrangedSubviews:@[ summaryHead, self.summaryGrid, actions ]];
    summary.axis = UILayoutConstraintAxisVertical;
    summary.spacing = 10.0;
    summary.translatesAutoresizingMaskIntoConstraints = NO;
    UIView *summaryContainer = [[UIView alloc] initWithFrame:CGRectZero];
    summaryContainer.backgroundColor = GPSLabThemeChipColor();
    summaryContainer.layer.cornerRadius = 14.0;
    summaryContainer.layer.masksToBounds = YES;
    summaryContainer.layer.borderWidth = 0.5;
    summaryContainer.layer.borderColor = GPSLabThemeBorderColor().CGColor;
    [summaryContainer addSubview:summary];
    [NSLayoutConstraint activateConstraints:@[
        [summary.topAnchor constraintEqualToAnchor:summaryContainer.topAnchor constant:11.0],
        [summary.bottomAnchor constraintEqualToAnchor:summaryContainer.bottomAnchor constant:-11.0],
        [summary.leadingAnchor constraintEqualToAnchor:summaryContainer.leadingAnchor constant:11.0],
        [summary.trailingAnchor constraintEqualToAnchor:summaryContainer.trailingAnchor constant:-11.0],
    ]];

    UIStackView *column = [[UIStackView alloc] initWithArrangedSubviews:@[ header, self.chipScroll, self.emptyLabel, summaryContainer ]];
    column.axis = UILayoutConstraintAxisVertical;
    column.spacing = 12.0;
    column.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:column];
    [NSLayoutConstraint activateConstraints:@[
        [column.topAnchor constraintEqualToAnchor:self.topAnchor constant:16.0],
        [column.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16.0],
        [column.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16.0],
        [column.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-16.0],
    ]];

    [self rebuildSummaryCells];
    [self refresh];
}

- (UILabel *)labelWithFont:(UIFont *)font {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.font = font;
    label.textColor = GPSLabThemeTextColor();
    return label;
}

- (UIButton *)actionButtonWithTitle:(NSString *)title background:(UIColor *)background gradient:(BOOL)gradient {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.titleLabel.font = GPSLabThemeFont(15.0, UIFontWeightSemibold);
    button.layer.cornerRadius = 12.0;
    button.layer.masksToBounds = YES;
    if (gradient) {
        CAGradientLayer *layer = GPSLabThemeAccentGradient();
        layer.frame = CGRectMake(0.0, 0.0, 320.0, 44.0);
        [button.layer insertSublayer:layer atIndex:0];
    } else {
        button.backgroundColor = background;
    }
    button.contentEdgeInsets = UIEdgeInsetsMake(11.0, 11.0, 11.0, 11.0);
    return button;
}

- (UIView *)summaryItemWithKey:(NSString *)key {
    UILabel *caption = [self labelWithFont:GPSLabThemeFont(11.0, UIFontWeightRegular)];
    caption.textColor = GPSLabThemeMutedColor();
    caption.accessibilityIdentifier = key;
    UILabel *value = [self labelWithFont:GPSLabThemeFont(14.0, UIFontWeightSemibold)];
    value.numberOfLines = 1;
    value.adjustsFontSizeToFitWidth = YES;
    UIStackView *texts = [[UIStackView alloc] initWithArrangedSubviews:@[ caption, value ]];
    texts.axis = UILayoutConstraintAxisVertical;
    texts.spacing = 3.0;
    texts.translatesAutoresizingMaskIntoConstraints = NO;

    UIView *item = [[UIView alloc] initWithFrame:CGRectZero];
    item.backgroundColor = GPSLabThemeCardColor();
    item.layer.cornerRadius = 10.0;
    item.layer.masksToBounds = YES;
    [item addSubview:texts];
    [NSLayoutConstraint activateConstraints:@[
        [texts.topAnchor constraintEqualToAnchor:item.topAnchor constant:9.0],
        [texts.bottomAnchor constraintEqualToAnchor:item.bottomAnchor constant:-9.0],
        [texts.leadingAnchor constraintEqualToAnchor:item.leadingAnchor constant:10.0],
        [texts.trailingAnchor constraintEqualToAnchor:item.trailingAnchor constant:-10.0],
    ]];
    self.summaryCaptionLabels = [self.summaryCaptionLabels arrayByAddingObject:caption];
    self.summaryValueLabels = [self.summaryValueLabels arrayByAddingObject:value];
    return item;
}

- (void)rebuildSummaryCells {
    for (UIView *view in self.summaryGrid.arrangedSubviews) {
        [view removeFromSuperview];
    }
    self.summaryCaptionLabels = @[];
    self.summaryValueLabels = @[];
    UIStackView *row1 = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self summaryItemWithKey:@"profiles.field.location"],
        [self summaryItemWithKey:@"profiles.field.drift"],
    ]];
    row1.axis = UILayoutConstraintAxisHorizontal;
    row1.distribution = UIStackViewDistributionFillEqually;
    row1.spacing = 8.0;
    UIStackView *row2 = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self summaryItemWithKey:@"profiles.field.wifi"],
        [self summaryItemWithKey:@"profiles.field.ble"],
    ]];
    row2.axis = UILayoutConstraintAxisHorizontal;
    row2.distribution = UIStackViewDistributionFillEqually;
    row2.spacing = 8.0;
    [self.summaryGrid addArrangedSubview:row1];
    [self.summaryGrid addArrangedSubview:row2];
}

- (void)applyLocalization {
    self.titleLabel.text = GPSLabLocalized(@"profiles.title");
    [self.addButton setTitle:GPSLabLocalized(@"profiles.add") forState:UIControlStateNormal];
    self.emptyLabel.text = GPSLabLocalized(@"profiles.empty");
    [self.editButton setTitle:GPSLabLocalized(@"profiles.edit") forState:UIControlStateNormal];
    [self.applyButton setTitle:GPSLabLocalized(@"profiles.apply") forState:UIControlStateNormal];
    self.statusLabel.text = GPSLabLocalized(@"profiles.ready");
    [self refresh];
}

- (void)setProfiles:(NSArray<GPSLabProfile *> *)profiles
 selectedIdentifier:(nullable NSString *)selectedIdentifier {
    self.profiles = profiles ?: @[];
    self.selectedIdentifier = selectedIdentifier;
    [self refresh];
}

- (GPSLabProfile *)selectedProfile {
    for (GPSLabProfile *profile in self.profiles) {
        if ([profile.identifier isEqualToString:self.selectedIdentifier]) {
            return profile;
        }
    }
    return self.profiles.firstObject;
}

- (void)refresh {
    [self rebuildChips];
    GPSLabProfile *selected = [self selectedProfile];
    self.emptyLabel.hidden = self.profiles.count > 0;
    self.applyButton.enabled = selected != nil;
    self.editButton.enabled = selected != nil;
    self.nameLabel.text = selected.name ?: @"";
    NSArray<UILabel *> *values = self.summaryValueLabels;
    if (values.count >= 4 && selected != nil) {
        values[0].text = (selected.locationMode == GPSLabProfileLocationRoute)
            ? GPSLabLocalized(@"profiles.mode.route") : GPSLabLocalized(@"profiles.mode.static");
        values[1].text = selected.driftEnabled ? GPSLabLocalized(@"profiles.value.on")
                                               : GPSLabLocalized(@"profiles.value.off");
        values[2].text = selected.wifi ? selected.wifi.profileName : GPSLabLocalized(@"profiles.value.off");
        values[3].text = selected.bluetooth ? selected.bluetooth.profileName
                                            : GPSLabLocalized(@"profiles.value.off");
    }
    for (UILabel *caption in self.summaryCaptionLabels) {
        if (caption.accessibilityIdentifier.length > 0) {
            caption.text = GPSLabLocalized(caption.accessibilityIdentifier);
        }
    }
}

- (void)rebuildChips {
    for (UIView *view in self.chipRow.arrangedSubviews) {
        [view removeFromSuperview];
    }
    for (GPSLabProfile *profile in self.profiles) {
        BOOL selected = [profile.identifier isEqualToString:self.selectedIdentifier];
        UIButton *chip = [UIButton buttonWithType:UIButtonTypeSystem];
        chip.backgroundColor = selected
            ? [GPSLabThemeAccentColor() colorWithAlphaComponent:0.12] : GPSLabThemeChipColor();
        chip.layer.cornerRadius = 16.0;
        chip.layer.borderWidth = selected ? 1.0 : 0.5;
        chip.layer.borderColor = (selected ? GPSLabThemeAccentColor() : GPSLabThemeBorderColor()).CGColor;
        chip.layer.masksToBounds = YES;
        chip.accessibilityIdentifier = profile.identifier;
        [chip addTarget:self action:@selector(chipTapped:) forControlEvents:UIControlEventTouchUpInside];

        UILabel *name = [self labelWithFont:GPSLabThemeFont(15.0, UIFontWeightSemibold)];
        name.text = profile.name;
        name.userInteractionEnabled = NO;
        UILabel *subtitle = [self labelWithFont:GPSLabThemeFont(11.0, UIFontWeightRegular)];
        subtitle.textColor = GPSLabThemeMutedColor();
        subtitle.text = [self subtitleForProfile:profile];
        subtitle.userInteractionEnabled = NO;
        UIStackView *texts = [[UIStackView alloc] initWithArrangedSubviews:@[ name, subtitle ]];
        texts.axis = UILayoutConstraintAxisVertical;
        texts.spacing = 4.0;
        texts.userInteractionEnabled = NO;
        texts.translatesAutoresizingMaskIntoConstraints = NO;
        [chip addSubview:texts];
        [NSLayoutConstraint activateConstraints:@[
            [texts.topAnchor constraintEqualToAnchor:chip.topAnchor constant:11.0],
            [texts.bottomAnchor constraintEqualToAnchor:chip.bottomAnchor constant:-11.0],
            [texts.leadingAnchor constraintEqualToAnchor:chip.leadingAnchor constant:12.0],
            [texts.trailingAnchor constraintEqualToAnchor:chip.trailingAnchor constant:-12.0],
            [chip.widthAnchor constraintGreaterThanOrEqualToConstant:118.0],
        ]];
        [self.chipRow addArrangedSubview:chip];
    }
}

- (NSString *)subtitleForProfile:(GPSLabProfile *)profile {
    NSString *location = (profile.locationMode == GPSLabProfileLocationRoute)
        ? GPSLabLocalized(@"profiles.mode.route") : GPSLabLocalized(@"profiles.mode.static");
    if (profile.wifi != nil) {
        return [NSString stringWithFormat:@"%@ • Wi-Fi", location];
    }
    if (profile.bluetooth != nil) {
        return [NSString stringWithFormat:@"%@ • BLE", location];
    }
    if (profile.driftEnabled) {
        return [NSString stringWithFormat:@"%@ • %@", location, GPSLabLocalized(@"profiles.field.drift")];
    }
    return location;
}

- (GPSLabProfile *)profileWithIdentifier:(NSString *)identifier {
    for (GPSLabProfile *profile in self.profiles) {
        if ([profile.identifier isEqualToString:identifier]) {
            return profile;
        }
    }
    return nil;
}

- (void)addTapped {
    if (self.addHandler != nil) {
        self.addHandler();
    }
}

- (void)chipTapped:(UIButton *)sender {
    GPSLabProfile *profile = [self profileWithIdentifier:sender.accessibilityIdentifier];
    if (profile != nil && self.selectHandler != nil) {
        self.selectHandler(profile);
    }
}

- (void)editTapped {
    GPSLabProfile *profile = [self selectedProfile];
    if (profile != nil && self.editHandler != nil) {
        self.editHandler(profile);
    }
}

- (void)applyTapped {
    GPSLabProfile *profile = [self selectedProfile];
    if (profile != nil && self.applyHandler != nil) {
        self.applyHandler(profile);
    }
}

@end
