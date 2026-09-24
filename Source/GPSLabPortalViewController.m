//
//  GPSLabPortalViewController.m
//  GPSLab
//
//  Account / subscription / help / feedback screen. Security posture:
//    * browser links come only from GPSLabLicenseConfig, which enforces the
//      license-endpoint origin and rejects credentialed/identifier URLs;
//    * the pairing code is displayed and copyable in-app only; it is never
//      appended to a URL and never logged;
//    * feedback is posted through GPSLabDevicePairing with bounded input and
//      safe offline/error states.
//  The entitlement states and the license network flow are untouched.
//

#import "GPSLabPortalViewController.h"

#import "GPSLabDevicePairing.h"
#import "GPSLabEntitlement.h"
#import "GPSLabLicenseConfig.h"
#import "GPSLabLicenseManager.h"
#import "GPSLabLocalization.h"
#import "GPSLabModalCoordinator.h"
#import "GPSLabPortalPolicy.h"

@interface GPSLabPortalViewController () <UITextViewDelegate>
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *planLabel;
@property (nonatomic, strong) UILabel *detailLabel;

@property (nonatomic, strong) UIButton *refreshButton;
@property (nonatomic, strong) UIButton *signInButton;
@property (nonatomic, strong) UIButton *manageButton;
@property (nonatomic, strong) UIButton *helpButton;

@property (nonatomic, strong) UILabel *trialHeader;
@property (nonatomic, strong) UILabel *trialNote;
@property (nonatomic, strong) UIButton *pairButton;
@property (nonatomic, strong) UILabel *pairCodeLabel;
@property (nonatomic, strong) UIButton *copyCodeButton;
@property (nonatomic, strong) UIButton *openPairPageButton;

@property (nonatomic, strong) UILabel *feedbackHeader;
@property (nonatomic, strong) UISegmentedControl *categoryControl;
@property (nonatomic, strong) UITextView *messageView;
@property (nonatomic, strong) UILabel *messageHint;
@property (nonatomic, strong) UIButton *sendFeedbackButton;
@property (nonatomic, strong) UILabel *feedbackStatusLabel;

@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@end

@implementation GPSLabPortalViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.statusLabel = [self bodyLabel:@""];
    self.statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    self.planLabel = [self bodyLabel:@""];
    self.detailLabel = [self bodyLabel:@""];
    self.detailLabel.textColor = UIColor.secondaryLabelColor;
    self.detailLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];

    self.refreshButton = [self actionButtonWithTitle:@"" action:@selector(refreshTapped)];
    self.signInButton = [self actionButtonWithTitle:@"" action:@selector(signInTapped)];
    self.manageButton = [self actionButtonWithTitle:@"" action:@selector(manageTapped)];
    self.helpButton = [self actionButtonWithTitle:@"" action:@selector(helpTapped)];

    self.trialHeader = [self sectionHeaderLabel:@""];
    self.trialNote = [self bodyLabel:@""];
    self.trialNote.textColor = UIColor.secondaryLabelColor;
    self.pairButton = [self actionButtonWithTitle:@"" action:@selector(pairTapped)];
    self.pairCodeLabel = [self bodyLabel:@""];
    self.pairCodeLabel.font = [UIFont monospacedSystemFontOfSize:20.0 weight:UIFontWeightSemibold];
    [GPSLabLocalization forceLeftToRight:self.pairCodeLabel];
    self.copyCodeButton = [self actionButtonWithTitle:@"" action:@selector(copyCodeTapped)];
    self.openPairPageButton = [self actionButtonWithTitle:@"" action:@selector(openPairPageTapped)];

    self.feedbackHeader = [self sectionHeaderLabel:@""];
    // Size the control from the shared allow-list so client and server
    // categories (six today) can never drift apart again.
    NSMutableArray<NSString *> *feedbackTitles = [NSMutableArray array];
    for (int index = 0; index < GPSLabPortalFeedbackCategoryCount(); index++) {
        [feedbackTitles addObject:@""];
    }
    self.categoryControl = [[UISegmentedControl alloc] initWithItems:feedbackTitles];
    [self.categoryControl setTitleTextAttributes:@{NSFontAttributeName: [UIFont systemFontOfSize:12.0 weight:UIFontWeightMedium]}
                                        forState:UIControlStateNormal];
    self.categoryControl.selectedSegmentIndex = 0;
    self.messageView = [[UITextView alloc] initWithFrame:CGRectZero];
    self.messageView.delegate = self;
    self.messageView.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.messageView.layer.borderColor = UIColor.separatorColor.CGColor;
    self.messageView.layer.borderWidth = 1.0;
    self.messageView.layer.cornerRadius = 8.0;
    self.messageView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.messageView.heightAnchor constraintGreaterThanOrEqualToConstant:120.0].active = YES;
    self.messageHint = [self bodyLabel:@""];
    self.messageHint.textColor = UIColor.secondaryLabelColor;
    self.messageHint.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    self.sendFeedbackButton = [self actionButtonWithTitle:@"" action:@selector(sendFeedbackTapped)];
    self.feedbackStatusLabel = [self bodyLabel:@""];
    self.feedbackStatusLabel.textColor = UIColor.secondaryLabelColor;

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.hidesWhenStopped = YES;

    UIStackView *content = self.contentStack;
    [content addArrangedSubview:self.statusLabel];
    [content addArrangedSubview:self.planLabel];
    [content addArrangedSubview:self.detailLabel];
    [content addArrangedSubview:self.spinner];
    [content addArrangedSubview:self.refreshButton];
    [content addArrangedSubview:self.signInButton];
    [content addArrangedSubview:self.manageButton];
    [content addArrangedSubview:self.helpButton];
    [content addArrangedSubview:self.trialHeader];
    [content addArrangedSubview:self.trialNote];
    [content addArrangedSubview:self.pairButton];
    [content addArrangedSubview:self.pairCodeLabel];
    [content addArrangedSubview:self.copyCodeButton];
    [content addArrangedSubview:self.openPairPageButton];
    [content addArrangedSubview:self.feedbackHeader];
    [content addArrangedSubview:self.categoryControl];
    [content addArrangedSubview:self.messageView];
    [content addArrangedSubview:self.messageHint];
    [content addArrangedSubview:self.sendFeedbackButton];
    [content addArrangedSubview:self.feedbackStatusLabel];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(licenseStateDidChange:)
                                                 name:GPSLabLicenseStateDidChangeNotification
                                               object:nil];

    [self gpslab_applyLocalization];
    [self refreshUI];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshUI];
}

#pragma mark - Localization

- (void)gpslab_applyLocalization {
    [super gpslab_applyLocalization];
    self.title = GPSLabLocalized(@"portal.title");
    [self.refreshButton setTitle:GPSLabLocalized(@"portal.refresh") forState:UIControlStateNormal];
    [self.signInButton setTitle:GPSLabLocalized(@"subscription.signIn") forState:UIControlStateNormal];
    [self.manageButton setTitle:GPSLabLocalized(@"subscription.manage") forState:UIControlStateNormal];
    [self.helpButton setTitle:GPSLabLocalized(@"portal.help") forState:UIControlStateNormal];
    self.trialHeader.text = GPSLabLocalized(@"portal.trial.header");
    self.trialNote.text = GPSLabLocalized(@"portal.trial.note");
    [self.pairButton setTitle:GPSLabLocalized(@"portal.trial.pair") forState:UIControlStateNormal];
    [self.copyCodeButton setTitle:GPSLabLocalized(@"portal.trial.copy") forState:UIControlStateNormal];
    [self.openPairPageButton setTitle:GPSLabLocalized(@"portal.trial.open") forState:UIControlStateNormal];
    self.feedbackHeader.text = GPSLabLocalized(@"portal.feedback.header");
    [self.sendFeedbackButton setTitle:GPSLabLocalized(@"portal.feedback.send") forState:UIControlStateNormal];
    self.messageHint.text = GPSLabLocalized(@"portal.feedback.hint");

    if (self.categoryControl.numberOfSegments >= GPSLabPortalFeedbackCategoryCount()) {
        for (int index = 0; index < GPSLabPortalFeedbackCategoryCount(); index++) {
            const char *token = GPSLabPortalFeedbackCategoryAt(index);
            NSString *key = [NSString stringWithFormat:@"portal.feedback.category.%s", token];
            [self.categoryControl setTitle:GPSLabLocalized(key) forSegmentAtIndex:(NSUInteger)index];
        }
    }
    [GPSLabLocalization applyLanguageAttributesToView:self.view];
}

- (NSDateFormatter *)localizedExpiryFormatter {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    NSString *identifier = ([GPSLabLocalization currentLanguage] == GPSLabLanguageEnglish)
        ? @"en_US"
        : @"ar";
    formatter.locale = [NSLocale localeWithLocaleIdentifier:identifier];
    formatter.dateStyle = NSDateFormatterMediumStyle;
    formatter.timeStyle = NSDateFormatterShortStyle;
    return formatter;
}

#pragma mark - UI state

- (void)setBusy:(BOOL)busy {
    [self refreshUI];
    if (busy) {
        self.refreshButton.enabled = NO;
        self.pairButton.enabled = NO;
        self.sendFeedbackButton.enabled = NO;
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

    self.statusLabel.text = [self statusTextForState:state];
    self.planLabel.text = entitlement.plan.length > 0
        ? [NSString stringWithFormat:GPSLabLocalized(@"subscription.plan.format"), entitlement.plan]
        : GPSLabLocalized(@"subscription.plan.none");

    NSMutableArray<NSString *> *details = [NSMutableArray array];
    if (entitlement.expiresAt > 0) {
        NSDate *expiry = [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)entitlement.expiresAt];
        [details addObject:[NSString stringWithFormat:GPSLabLocalized(@"subscription.validUntil"),
                            [[self localizedExpiryFormatter] stringFromDate:expiry]]];
    }
    if (!configured) {
        [details addObject:GPSLabLocalized(@"subscription.noService")];
    }
    self.detailLabel.text = [details componentsJoinedByString:@"\n"];

    self.refreshButton.enabled = configured && state != GPSLabEntitlementStateChecking;
    self.signInButton.enabled = config.signInURL != nil;
    self.manageButton.enabled = config.manageAccountURL != nil;
    self.helpButton.enabled = config.helpURL != nil;

    BOOL pairingConfigured = [GPSLabDevicePairing sharedClient].isConfigured;
    self.pairButton.enabled = pairingConfigured;
    self.openPairPageButton.enabled = config.trialPairingURL != nil;
    self.copyCodeButton.enabled = self.pairCodeLabel.text.length > 0;

    self.sendFeedbackButton.enabled = [GPSLabDevicePairing sharedClient].isConfigured;

    if (state == GPSLabEntitlementStateChecking) {
        [self.spinner startAnimating];
    } else {
        [self.spinner stopAnimating];
    }
}

- (NSString *)statusTextForState:(GPSLabEntitlementState)state {
    switch (state) {
        case GPSLabEntitlementStateActive:
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

#pragma mark - Actions

- (void)refreshTapped {
    [self.view endEditing:YES];
    self.feedbackStatusLabel.text = GPSLabLocalized(@"portal.refresh.status");
    [self setBusy:YES];
    GPSLabPortalViewController *__weak weakSelf = self;
    [[GPSLabLicenseManager sharedManager] refreshWithCompletion:^(GPSLabEntitlementState state) {
        (void)state;
        [weakSelf setBusy:NO];
        weakSelf.feedbackStatusLabel.text = GPSLabLocalized(@"portal.refresh.done");
    }];
}

- (void)signInTapped {
    [self openExternalURL:[GPSLabLicenseConfig sharedConfig].signInURL
                  missing:GPSLabLocalized(@"subscription.signInUnavailable")];
}

- (void)manageTapped {
    [self openExternalURL:[GPSLabLicenseConfig sharedConfig].manageAccountURL
                  missing:GPSLabLocalized(@"subscription.manageUnavailable")];
}

- (void)helpTapped {
    [self openExternalURL:[GPSLabLicenseConfig sharedConfig].helpURL
                  missing:GPSLabLocalized(@"portal.help.unavailable")];
}

- (void)pairTapped {
    [self.view endEditing:YES];
    self.feedbackStatusLabel.text = GPSLabLocalized(@"portal.trial.pairing");
    [self setBusy:YES];
    GPSLabPortalViewController *__weak weakSelf = self;
    [[GPSLabDevicePairing sharedClient] requestPairingCodeWithCompletion:
        ^(GPSLabDeviceRequestResult result, NSString *code, NSString *message) {
        GPSLabPortalViewController *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        [strongSelf setBusy:NO];
        strongSelf.feedbackStatusLabel.text = message;
        if (result == GPSLabDeviceRequestResultSuccess && code.length > 0) {
            // Display/copy only; the code never enters a URL or a log.
            strongSelf.pairCodeLabel.text = code;
        } else {
            strongSelf.pairCodeLabel.text = nil;
        }
        [strongSelf refreshUI];
    }];
}

- (void)copyCodeTapped {
    NSString *code = self.pairCodeLabel.text;
    if (code.length == 0) {
        return;
    }
    UIPasteboard.generalPasteboard.string = code;
    self.feedbackStatusLabel.text = GPSLabLocalized(@"portal.trial.copied");
}

- (void)openPairPageTapped {
    // Never append the pairing code: the user types it on the page.
    [self openExternalURL:[GPSLabLicenseConfig sharedConfig].trialPairingURL
                  missing:GPSLabLocalized(@"portal.trial.unavailable")];
}

- (void)sendFeedbackTapped {
    [self.view endEditing:YES];
    NSInteger index = self.categoryControl.selectedSegmentIndex;
    const char *token = GPSLabPortalFeedbackCategoryAt((int)index);
    NSString *category = token != NULL ? [NSString stringWithUTF8String:token] : @"";
    NSString *message = self.messageView.text ?: @"";
    if (message.length == 0) {
        self.feedbackStatusLabel.text = GPSLabLocalized(@"portal.feedback.empty");
        return;
    }
    self.feedbackStatusLabel.text = GPSLabLocalized(@"portal.feedback.sending");
    [self setBusy:YES];
    self.messageView.editable = NO;
    GPSLabPortalViewController *__weak weakSelf = self;
    [[GPSLabDevicePairing sharedClient] submitFeedbackWithCategory:category
                                                           message:message
                                                        completion:^(GPSLabDeviceRequestResult result, NSString *text) {
        GPSLabPortalViewController *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        strongSelf.messageView.editable = YES;
        [strongSelf setBusy:NO];
        strongSelf.feedbackStatusLabel.text = text;
        if (result == GPSLabDeviceRequestResultSuccess) {
            strongSelf.messageView.text = @"";
        }
    }];
}

- (void)openExternalURL:(NSURL *)url missing:(NSString *)missingMessage {
    if (url == nil) {
        self.feedbackStatusLabel.text = missingMessage;
        return;
    }
    UIApplication *application = [UIApplication sharedApplication];
    [application openURL:url options:@{} completionHandler:nil];
}

#pragma mark - Notifications

- (void)licenseStateDidChange:(NSNotification *)notification {
    (void)notification;
    [self refreshUI];
}

@end
