//
//  GPSLabSheetViewController.m
//  GPSLab
//
//  Reusable native sheet scaffolding and small form helpers.
//

#import "GPSLabSheetViewController.h"

#import "GPSLabLocalization.h"
#import "GPSLabModalCoordinator.h"

UINavigationController *GPSLabSheetNavigationController(UIViewController *root) {
    if (root == nil) {
        return nil;
    }
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:root];
    navigation.modalPresentationStyle = UIModalPresentationPageSheet;
    if (@available(iOS 15.0, *)) {
        UISheetPresentationController *sheet = navigation.sheetPresentationController;
        if (sheet != nil) {
            sheet.detents = @[[UISheetPresentationControllerDetent mediumDetent],
                              [UISheetPresentationControllerDetent largeDetent]];
            sheet.prefersGrabberVisible = YES;
            sheet.preferredCornerRadius = 20.0;
        }
    }
    if (root.navigationItem.leftBarButtonItem == nil) {
        UIBarButtonItem *close = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                                                               target:root
                                                                               action:@selector(gpslab_dismissSheet)];
        root.navigationItem.leftBarButtonItem = close;
    }
    return navigation;
}

@implementation UIViewController (GPSLabSheet)

- (void)gpslab_dismissSheet {
    [[GPSLabModalCoordinator sharedCoordinator] dismissTopmostAnimated:YES completion:nil];
}

@end

#pragma mark - Form base

@interface GPSLabSheetViewController ()
@property (nonatomic, strong) UIStackView *stack;
@end

@implementation GPSLabSheetViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;

    UIScrollView *scrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.alwaysBounceVertical = YES;
    scrollView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.view addSubview:scrollView];

    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12.0;
    [scrollView addSubview:stack];

    UILayoutGuide *safeArea = self.view.safeAreaLayoutGuide;
    // The scroll viewport hugs the keyboard when it is up and the safe-area
    // bottom otherwise. Required inequalities plus two equalities (safe area at
    // 999, keyboard at 998) keep the height >= 0 and never produce an
    // unsatisfiable layout in tiny landscape / docked / undocked keyboards.
    NSLayoutConstraint *bottomToSafeArea = [scrollView.bottomAnchor constraintEqualToAnchor:safeArea.bottomAnchor];
    bottomToSafeArea.priority = 999.0;
    NSLayoutConstraint *bottomToKeyboard =
        [scrollView.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor];
    bottomToKeyboard.priority = 998.0;
    [NSLayoutConstraint activateConstraints:@[
        [scrollView.topAnchor constraintEqualToAnchor:safeArea.topAnchor],
        [scrollView.leadingAnchor constraintEqualToAnchor:safeArea.leadingAnchor],
        [scrollView.trailingAnchor constraintEqualToAnchor:safeArea.trailingAnchor],
        [scrollView.bottomAnchor constraintLessThanOrEqualToAnchor:safeArea.bottomAnchor],
        [scrollView.bottomAnchor constraintLessThanOrEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor],
        [scrollView.heightAnchor constraintGreaterThanOrEqualToConstant:0.0],
        bottomToSafeArea,
        bottomToKeyboard,

        [stack.topAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.topAnchor constant:16.0],
        [stack.bottomAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.bottomAnchor constant:-24.0],
        [stack.leadingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.leadingAnchor constant:16.0],
        [stack.trailingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.trailingAnchor constant:-16.0],
        [stack.widthAnchor constraintEqualToAnchor:scrollView.frameLayoutGuide.widthAnchor constant:-32.0],
    ]];

    self.stack = stack;

    [self gpslab_applyLocalization];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(gpslab_languageDidChange:)
                                                 name:GPSLabLanguageDidChangeNotification
                                               object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)gpslab_applyLocalization {
    // Subclasses override to re-apply their own catalog strings.
}

- (void)gpslab_languageDidChange:(NSNotification *)notification {
    (void)notification;
    [self gpslab_applyLocalization];
}

- (UIStackView *)contentStack {
    return self.stack;
}

#pragma mark - Helpers

- (UILabel *)sectionHeaderLabel:(NSString *)text {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.text = [text uppercaseString];
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    label.adjustsFontForContentSizeCategory = YES;
    label.textColor = UIColor.secondaryLabelColor;
    return label;
}

- (UILabel *)bodyLabel:(NSString *)text {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.text = text;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    label.adjustsFontForContentSizeCategory = YES;
    label.numberOfLines = 0;
    label.textColor = UIColor.labelColor;
    return label;
}

- (UIStackView *)rowWithTitle:(NSString *)title control:(UIView *)control {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.text = title;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    label.adjustsFontForContentSizeCategory = YES;
    label.numberOfLines = 0;

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[label, [UIView new], control]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 8.0;
    return row;
}

- (UIButton *)actionButtonWithTitle:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.adjustsFontForContentSizeCategory = YES;
    button.titleLabel.numberOfLines = 0;
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (UITextField *)decimalFieldWithPlaceholder:(NSString *)placeholder {
    UITextField *field = [[UITextField alloc] initWithFrame:CGRectZero];
    field.placeholder = placeholder;
    field.borderStyle = UITextBorderStyleRoundedRect;
    field.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.clearButtonMode = UITextFieldViewModeWhileEditing;
    // Numeric fields stay LTR so digits/signs are never reordered by RTL.
    [GPSLabLocalization forceLeftToRight:field];
    return field;
}

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:GPSLabLocalized(@"common.ok")
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [[GPSLabModalCoordinator sharedCoordinator] presentAlert:alert completion:nil];
}

@end
