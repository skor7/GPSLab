//
//  GPSLabSubscriptionViewController.m
//  GPSLab
//
//  Fail-closed subscription screen. Actions are only enabled when their prerequisite
//  (endpoint/public key/sign-in URL/manage URL) is actually configured. This class
//  only changes the displayed strings; the entitlement states, activation behavior,
//  service gate and network flow are untouched.
//

#import "GPSLabSubscriptionViewController.h"

#import "GPSLabEntitlement.h"
#import "GPSLabLicenseConfig.h"
#import "GPSLabLicenseManager.h"
#import "GPSLabLocalization.h"
#import "GPSLabModalCoordinator.h"
#import "GPSLabOverlayPresenter.h"
#import "GPSLabPortalViewController.h"

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
@property (nonatomic, strong) UIButton *accountButton;
@property (nonatomic, strong) UIButton *closeButton;
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
    title.text = GPSLabLocalized(@"overlay.title");
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
    self.codeField.borderStyle = UITextBorderStyleRoundedRect;
    self.codeField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.codeField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.codeField.clearButtonMode = UITextFieldViewModeWhileEditing;

    self.activateButton = [self filledButtonWithTitle:@"" action:@selector(activateTapped)];
    self.signInButton = [self plainButtonWithTitle:@"" action:@selector(signInTapped)];
    self.restoreButton = [self plainButtonWithTitle:@"" action:@selector(restoreTapped)];
    self.tryAgainButton = [self plainButtonWithTitle:@"" action:@selector(tryAgainTapped)];
    self.manageButton = [self plainButtonWithTitle:@"" action:@selector(manageTapped)];
    self.accountButton = [self plainButtonWithTitle:@"" action:@selector(accountTapped)];

    self.feedbackLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.feedbackLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    self.feedbackLabel.adjustsFontForContentSizeCategory = YES;
    self.feedbackLabel.textColor = UIColor.secondaryLabelColor;
    self.feedbackLabel.numberOfLines = 0;

    self.closeButton = [self plainButtonWithTitle:@"" action:@selector(closeTapped)];
    self.closeButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentRight;

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
    [stack addArrangedSubview:self.accountButton];
    [stack addArrangedSubview:self.feedbackLabel];
    [stack addArrangedSubview:self.closeButton];

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
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(languageDidChange:)
                                                 name:GPSLabLanguageDidChangeNotification
                                               object:nil];
    [self applyLocalization];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshUI];
}

#pragma mark - Localization

- (void)languageDidChange:(NSNotification *)notification {
    (void)notification;
    [self applyLocalization];
}

- (void)applyLocalization {
    [self.activateButton setTitle:GPSLabLocalized(@"subscription.activate") forState:UIControlStateNormal];
    [self.signInButton setTitle:GPSLabLocalized(@"subscription.signIn") forState:UIControlStateNormal];
    [self.restoreButton setTitle:GPSLabLocalized(@"subscription.restore") forState:UIControlStateNormal];
    [self.tryAgainButton setTitle:GPSLabLocalized(@"subscription.tryAgain") forState:UIControlStateNormal];
    [self.manageButton setTitle:GPSLabLocalized(@"subscription.manage") forState:UIControlStateNormal];
    [self.accountButton setTitle:GPSLabLocalized(@"subscription.account") forState:UIControlStateNormal];
    [self.closeButton setTitle:GPSLabLocalized(@"common.close") forState:UIControlStateNormal];
    self.codeField.placeholder = GPSLabLocalized(@"subscription.codePlaceholder");
    [GPSLabLocalization applyLanguageAttributesToView:self.view];
    [self refreshUI];
}

- (NSString *)localizedStatusForState:(GPSLabEntitlementState)state
                          entitlement:(GPSLabEntitlement *)entitlement {
    switch (state) {
        case GPSLabEntitlementStateActive:
            if (entitlement.plan.length > 0) {
                return [NSString stringWithFormat:GPSLabLocalized(@"subscription.status.activeWithPlan"),
                        entitlement.plan];
            }
            return GPSLabLocalized(@"subscription.status.active");
        case GPSLabEntitlementStateGrace:
            return GPSLabLocalized(@"subscription.status.grace");
        case GPSLabEntitlementStateExpired:
            return GPSLabLocalized(@"subscription.status.expired");
        case GPSLabEntitlementStateInvalid:
            return GPSLabLocalized(@"subscription.status.invalid");
        case GPSLabEntitlementStateOffline:
            return GPSLabLocalized(@"subscription.status.offline");
        case GPSLabEntitlementStateChecking:
            return GPSLabLocalized(@"subscription.status.checking");
        case GPSLabEntitlementStateUnknown:
        default:
            return GPSLabLocalized(@"subscription.status.unknown");
    }
}

- (NSDateFormatter *)localizedExpiryFormatter {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    // Explicit GPSLab-only locale; never the host default.
    NSString *identifier = ([GPSLabLocalization currentLanguage] == GPSLabLanguageEnglish)
        ? @"en_US"
        : @"ar";
    formatter.locale = [NSLocale localeWithLocaleIdentifier:identifier];
    formatter.dateStyle = NSDateFormatterMediumStyle;
    formatter.timeStyle = NSDateFormatterShortStyle;
    return formatter;
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
    // End editing FIRST so the activation is never raced by a pending field resign
    // or the keyboard's own teardown. Licensing behavior is unchanged.
    [self.view endEditing:YES];
    if (![[GPSLabLicenseManager sharedManager] isServiceConfigured]) {
        self.feedbackLabel.text = GPSLabLocalized(@"subscription.activationUnavailable");
        return;
    }
    self.feedbackLabel.text = GPSLabLocalized(@"subscription.activating");
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
        self.feedbackLabel.text = GPSLabLocalized(@"subscription.signInUnavailable");
        return;
    }
    [self openExternalURL:url];
}

- (void)manageTapped {
    NSURL *url = [GPSLabLicenseConfig sharedConfig].manageAccountURL;
    if (url == nil) {
        self.feedbackLabel.text = GPSLabLocalized(@"subscription.manageUnavailable");
        return;
    }
    [self openExternalURL:url];
}

- (void)restoreTapped {
    if (![[GPSLabLicenseManager sharedManager] isServiceConfigured]) {
        self.feedbackLabel.text = GPSLabLocalized(@"subscription.restoreUnavailable");
        return;
    }
    self.feedbackLabel.text = GPSLabLocalized(@"subscription.restoring");
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
        self.feedbackLabel.text = GPSLabLocalized(@"subscription.retryUnavailable");
        return;
    }
    self.feedbackLabel.text = GPSLabLocalized(@"subscription.checkingNow");
    [self setBusy:YES];
    GPSLabSubscriptionViewController *__weak weakSelf = self;
    [[GPSLabLicenseManager sharedManager] refreshWithCompletion:^(GPSLabEntitlementState state) {
        (void)state;
        [weakSelf setBusy:NO];
        [weakSelf refreshUI];
    }];
}

- (void)accountTapped {
    // Account/support is always available, locked or unlocked: subscription,
    // sign-in, manage/renew, trial pairing, help and in-app feedback.
    GPSLabPortalViewController *portal = [[GPSLabPortalViewController alloc] init];
    [[GPSLabModalCoordinator sharedCoordinator] presentSheetRoot:portal completion:nil];
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

    // UI-only mapping of the existing state enum; behavior is unchanged.
    self.statusLabel.text = [self localizedStatusForState:state entitlement:entitlement];
    self.planLabel.text = entitlement.plan.length > 0
        ? [NSString stringWithFormat:GPSLabLocalized(@"subscription.plan.format"), entitlement.plan]
        : GPSLabLocalized(@"subscription.plan.none");

    NSMutableArray<NSString *> *details = [NSMutableArray array];
    if (entitlement.expiresAt > 0) {
        NSDate *expiry = [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)entitlement.expiresAt];
        NSDateFormatter *formatter = [self localizedExpiryFormatter];
        [details addObject:[NSString stringWithFormat:GPSLabLocalized(@"subscription.validUntil"),
                            [formatter stringFromDate:expiry]]];
    }
    if (!configured) {
        [details addObject:GPSLabLocalized(@"subscription.noService")];
    }
    if (config.signInURL == nil) {
        [details addObject:GPSLabLocalized(@"subscription.noSignIn")];
    }
    if (config.manageAccountURL == nil) {
        [details addObject:GPSLabLocalized(@"subscription.noManage")];
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
