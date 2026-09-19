//
//  GPSLabSubscriptionViewController.m
//  GPSLab
//
//  Fail-closed subscription screen. Actions are only enabled when their prerequisite
//  (endpoint/public key/sign-in URL/manage URL) is actually configured.
//

#import "GPSLabSubscriptionViewController.h"

#import "GPSLabEntitlement.h"
#import "GPSLabLicenseConfig.h"
#import "GPSLabLicenseManager.h"
#import "GPSLabOverlayPresenter.h"

@interface GPSLabSubscriptionViewController ()
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *planLabel;
@property (nonatomic, strong) UILabel *detailLabel;
@property (nonatomic, strong) UILabel *feedbackLabel;
@property (nonatomic, strong) UITextField *codeField;
@property (nonatomic, strong) UIButton *activateButton;
@property (nonatomic, strong) UIButton *signInButton;
@property (nonatomic, strong) UIButton *restoreButton;
@property (nonatomic, strong) UIButton *tryAgainButton;
@property (nonatomic, strong) UIButton *manageButton;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@end

@implementation GPSLabSubscriptionViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;

    UIScrollView *scrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.alwaysBounceVertical = YES;
    [self.view addSubview:scrollView];

    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 14.0;
    [scrollView addSubview:stack];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectZero];
    title.text = @"GPSLab";
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleLargeTitle];
    title.adjustsFontForContentSizeCategory = YES;

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    self.statusLabel.adjustsFontForContentSizeCategory = YES;
    self.statusLabel.numberOfLines = 0;

    self.planLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.planLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.planLabel.adjustsFontForContentSizeCategory = YES;
    self.planLabel.numberOfLines = 0;

    self.detailLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.detailLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    self.detailLabel.adjustsFontForContentSizeCategory = YES;
    self.detailLabel.textColor = UIColor.secondaryLabelColor;
    self.detailLabel.numberOfLines = 0;

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.hidesWhenStopped = YES;

    self.codeField = [[UITextField alloc] initWithFrame:CGRectZero];
    self.codeField.placeholder = @"Activation code";
    self.codeField.borderStyle = UITextBorderStyleRoundedRect;
    self.codeField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.codeField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.codeField.clearButtonMode = UITextFieldViewModeWhileEditing;

    self.activateButton = [self filledButtonWithTitle:@"Activate" action:@selector(activateTapped)];
    self.signInButton = [self plainButtonWithTitle:@"Sign In" action:@selector(signInTapped)];
    self.restoreButton = [self plainButtonWithTitle:@"Restore" action:@selector(restoreTapped)];
    self.tryAgainButton = [self plainButtonWithTitle:@"Try Again" action:@selector(tryAgainTapped)];
    self.manageButton = [self plainButtonWithTitle:@"Manage Account" action:@selector(manageTapped)];

    self.feedbackLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.feedbackLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    self.feedbackLabel.adjustsFontForContentSizeCategory = YES;
    self.feedbackLabel.textColor = UIColor.secondaryLabelColor;
    self.feedbackLabel.numberOfLines = 0;

    UIButton *close = [self plainButtonWithTitle:@"Close" action:@selector(closeTapped)];
    close.contentHorizontalAlignment = UIControlContentHorizontalAlignmentRight;

    [stack addArrangedSubview:title];
    [stack addArrangedSubview:self.statusLabel];
    [stack addArrangedSubview:self.planLabel];
    [stack addArrangedSubview:self.detailLabel];
    [stack addArrangedSubview:self.spinner];
    [stack addArrangedSubview:self.codeField];
    [stack addArrangedSubview:self.activateButton];
    [stack addArrangedSubview:self.signInButton];
    [stack addArrangedSubview:self.restoreButton];
    [stack addArrangedSubview:self.tryAgainButton];
    [stack addArrangedSubview:self.manageButton];
    [stack addArrangedSubview:self.feedbackLabel];
    [stack addArrangedSubview:close];

    UILayoutGuide *safeArea = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [scrollView.topAnchor constraintEqualToAnchor:safeArea.topAnchor],
        [scrollView.leadingAnchor constraintEqualToAnchor:safeArea.leadingAnchor],
        [scrollView.trailingAnchor constraintEqualToAnchor:safeArea.trailingAnchor],
        [scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [stack.topAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.topAnchor constant:24.0],
        [stack.bottomAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.bottomAnchor constant:-24.0],
        [stack.leadingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.leadingAnchor constant:20.0],
        [stack.trailingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.trailingAnchor constant:-20.0],
        [stack.widthAnchor constraintEqualToAnchor:scrollView.frameLayoutGuide.widthAnchor constant:-40.0],
    ]];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(licenseStateDidChange:)
                                                 name:GPSLabLicenseStateDidChangeNotification
                                               object:nil];
    [self refreshUI];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshUI];
}

#pragma mark - Buttons

- (UIButton *)filledButtonWithTitle:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [button setTitleColor:UIColor.secondaryLabelColor forState:UIControlStateDisabled];
    button.titleLabel.adjustsFontForContentSizeCategory = YES;
    button.backgroundColor = UIColor.systemBlueColor;
    button.layer.cornerRadius = 10.0;
    button.layer.masksToBounds = YES;
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:44.0].active = YES;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (UIButton *)plainButtonWithTitle:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.adjustsFontForContentSizeCategory = YES;
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:40.0].active = YES;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

#pragma mark - Actions

- (void)activateTapped {
    if (![[GPSLabLicenseManager sharedManager] isServiceConfigured]) {
        self.feedbackLabel.text = @"Activation is not available in this build.";
        return;
    }
    self.feedbackLabel.text = @"Activating...";
    [self setBusy:YES];
    GPSLabSubscriptionViewController *__weak weakSelf = self;
    [[GPSLabLicenseManager sharedManager] activateWithCode:self.codeField.text
                                               completion:^(GPSLabEntitlementState state, NSString *message) {
        (void)state;
        [weakSelf setBusy:NO];
        weakSelf.feedbackLabel.text = message;
        [weakSelf refreshUI];
    }];
}

- (void)signInTapped {
    NSURL *url = [GPSLabLicenseConfig sharedConfig].signInURL;
    if (url == nil) {
        self.feedbackLabel.text = @"Sign in is not available in this build.";
        return;
    }
    [self openExternalURL:url];
}

- (void)manageTapped {
    NSURL *url = [GPSLabLicenseConfig sharedConfig].manageAccountURL;
    if (url == nil) {
        self.feedbackLabel.text = @"Account management is not available in this build.";
        return;
    }
    [self openExternalURL:url];
}

- (void)restoreTapped {
    if (![[GPSLabLicenseManager sharedManager] isServiceConfigured]) {
        self.feedbackLabel.text = @"Restore is not available in this build.";
        return;
    }
    self.feedbackLabel.text = @"Restoring...";
    [self setBusy:YES];
    GPSLabSubscriptionViewController *__weak weakSelf = self;
    [[GPSLabLicenseManager sharedManager] restoreWithCompletion:^(GPSLabEntitlementState state, NSString *message) {
        (void)state;
        [weakSelf setBusy:NO];
        weakSelf.feedbackLabel.text = message;
        [weakSelf refreshUI];
    }];
}

- (void)tryAgainTapped {
    if (![[GPSLabLicenseManager sharedManager] isServiceConfigured]) {
        self.feedbackLabel.text = @"Retry is not available in this build.";
        return;
    }
    self.feedbackLabel.text = @"Checking...";
    [self setBusy:YES];
    GPSLabSubscriptionViewController *__weak weakSelf = self;
    [[GPSLabLicenseManager sharedManager] refreshWithCompletion:^(GPSLabEntitlementState state) {
        (void)state;
        [weakSelf setBusy:NO];
        [weakSelf refreshUI];
    }];
}

- (void)closeTapped {
    [[GPSLabOverlayPresenter sharedPresenter] dismissOverlay];
}

- (void)openExternalURL:(NSURL *)url {
    UIApplication *application = [UIApplication sharedApplication];
    [application openURL:url options:@{} completionHandler:nil];
}

#pragma mark - UI state

- (void)setBusy:(BOOL)busy {
    self.activateButton.enabled = !busy && [[GPSLabLicenseManager sharedManager] isServiceConfigured];
    self.restoreButton.enabled = !busy && [[GPSLabLicenseManager sharedManager] isServiceConfigured];
    self.tryAgainButton.enabled = !busy && [[GPSLabLicenseManager sharedManager] isServiceConfigured];
    if (busy) {
        [self.spinner startAnimating];
    } else {
        [self.spinner stopAnimating];
    }
}

- (void)refreshUI {
    GPSLabLicenseManager *manager = [GPSLabLicenseManager sharedManager];
    GPSLabLicenseConfig *config = [GPSLabLicenseConfig sharedConfig];
    BOOL configured = manager.isServiceConfigured;
    GPSLabEntitlementState state = [manager state];
    GPSLabEntitlement *entitlement = [manager currentEntitlement];

    self.statusLabel.text = [manager nonTechnicalServiceStatus];
    self.planLabel.text = entitlement.plan.length > 0
        ? [NSString stringWithFormat:@"Plan: %@", entitlement.plan]
        : @"Plan: -";

    NSMutableArray<NSString *> *details = [NSMutableArray array];
    if (entitlement.expiresAt > 0) {
        NSDate *expiry = [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)entitlement.expiresAt];
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        formatter.dateStyle = NSDateFormatterMediumStyle;
        formatter.timeStyle = NSDateFormatterShortStyle;
        [details addObject:[NSString stringWithFormat:@"Valid until %@", [formatter stringFromDate:expiry]]];
    }
    if (!configured) {
        [details addObject:@"This build has no subscription service configured."];
    }
    if (config.signInURL == nil) {
        [details addObject:@"Sign in is unavailable in this build."];
    }
    if (config.manageAccountURL == nil) {
        [details addObject:@"Account management is unavailable in this build."];
    }
    self.detailLabel.text = [details componentsJoinedByString:@"\n"];

    self.codeField.enabled = configured;
    self.activateButton.enabled = configured;
    self.restoreButton.enabled = configured;
    self.tryAgainButton.enabled = configured && state != GPSLabEntitlementStateChecking;
    self.signInButton.enabled = config.signInURL != nil;
    self.manageButton.enabled = config.manageAccountURL != nil;

    if (state == GPSLabEntitlementStateChecking) {
        [self.spinner startAnimating];
    } else {
        [self.spinner stopAnimating];
    }
}

- (void)licenseStateDidChange:(NSNotification *)notification {
    (void)notification;
    [self refreshUI];
}

@end
