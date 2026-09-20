//
//  GPSLabRouteViewController.m
//  GPSLab
//
//  Route controls. The engine remains the single source of truth; this sheet only
//  reads state, drives the existing start/pause/resume/stop API and asks the canvas
//  to pick map endpoints. Only GPSLab UI strings are localized.
//

#import "GPSLabRouteViewController.h"

#import "GPSLabEngine.h"
#import "GPSLabLocalization.h"
#import "GPSLabTypes.h"

@implementation GPSLabRouteViewController {
    UISegmentedControl *_modeControl;
    UITextField *_customSpeedField;
    UISegmentedControl *_stopBehaviorControl;
    UILabel *_startLabel;
    UILabel *_endLabel;
    UIProgressView *_progressView;
    UILabel *_statusLabel;
    NSTimer *_statusTimer;

    UILabel *_modeHeader;
    UILabel *_endpointsHeader;
    UILabel *_playbackHeader;
    UILabel *_onStopHeader;
    UILabel *_speedsLabel;
    UIButton *_setStartButton;
    UIButton *_setEndButton;
    UIButton *_playButton;
    UIButton *_pauseButton;
    UIButton *_stopButton;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    GPSLabConfiguration *configuration = [[GPSLabEngine sharedEngine] configuration];

    _modeControl = [[UISegmentedControl alloc] initWithItems:@[@"", @"", @"", @""]];
    _modeControl.selectedSegmentIndex = configuration.routeMode;
    [_modeControl addTarget:self action:@selector(modeChanged) forControlEvents:UIControlEventValueChanged];

    _customSpeedField = [self decimalFieldWithPlaceholder:@""];
    _customSpeedField.keyboardType = UIKeyboardTypeDecimalPad;
    _customSpeedField.text = [NSString stringWithFormat:@"%.1f", configuration.routeCustomSpeedKmh];

    _stopBehaviorControl = [[UISegmentedControl alloc] initWithItems:@[@"", @""]];
    _stopBehaviorControl.selectedSegmentIndex = configuration.stopBehavior;
    [_stopBehaviorControl addTarget:self
                             action:@selector(stopBehaviorChanged)
                   forControlEvents:UIControlEventValueChanged];

    _setStartButton = [self actionButtonWithTitle:@"" action:@selector(pickStartTapped)];
    _setEndButton = [self actionButtonWithTitle:@"" action:@selector(pickEndTapped)];
    _startLabel = [self bodyLabel:@""];
    _endLabel = [self bodyLabel:@""];
    _startLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    _endLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    _startLabel.textColor = UIColor.secondaryLabelColor;
    _endLabel.textColor = UIColor.secondaryLabelColor;

    _playButton = [self actionButtonWithTitle:@"" action:@selector(startTapped)];
    _pauseButton = [self actionButtonWithTitle:@"" action:@selector(pauseTapped)];
    _stopButton = [self actionButtonWithTitle:@"" action:@selector(stopTapped)];

    _progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    _statusLabel = [self bodyLabel:@""];
    _statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    _statusLabel.textColor = UIColor.secondaryLabelColor;

    _modeHeader = [self sectionHeaderLabel:@""];
    _endpointsHeader = [self sectionHeaderLabel:@""];
    _playbackHeader = [self sectionHeaderLabel:@""];
    _onStopHeader = [self sectionHeaderLabel:@""];
    _speedsLabel = [self bodyLabel:@""];

    UIStackView *content = self.contentStack;
    [content addArrangedSubview:_modeHeader];
    [content addArrangedSubview:_modeControl];
    [content addArrangedSubview:_speedsLabel];
    [content addArrangedSubview:_customSpeedField];
    [content addArrangedSubview:_endpointsHeader];
    [content addArrangedSubview:_setStartButton];
    [content addArrangedSubview:_setEndButton];
    [content addArrangedSubview:_startLabel];
    [content addArrangedSubview:_endLabel];
    [content addArrangedSubview:_playbackHeader];
    [content addArrangedSubview:_playButton];
    [content addArrangedSubview:_pauseButton];
    [content addArrangedSubview:_stopButton];
    [content addArrangedSubview:_progressView];
    [content addArrangedSubview:_statusLabel];
    [content addArrangedSubview:_onStopHeader];
    [content addArrangedSubview:_stopBehaviorControl];

    [self gpslab_applyLocalization];
    [self refreshFromEngine];
    [self updateCustomSpeedEnabled];
}

#pragma mark - Localization

- (void)gpslab_applyLocalization {
    self.title = GPSLabLocalized(@"route.title");
    if (_modeControl.numberOfSegments >= 4) {
        [_modeControl setTitle:GPSLabLocalized(@"route.mode.driving") forSegmentAtIndex:0];
        [_modeControl setTitle:GPSLabLocalized(@"route.mode.walking") forSegmentAtIndex:1];
        [_modeControl setTitle:GPSLabLocalized(@"route.mode.cycling") forSegmentAtIndex:2];
        [_modeControl setTitle:GPSLabLocalized(@"route.mode.custom") forSegmentAtIndex:3];
    }
    if (_stopBehaviorControl.numberOfSegments >= 2) {
        [_stopBehaviorControl setTitle:GPSLabLocalized(@"route.stop.stay") forSegmentAtIndex:0];
        [_stopBehaviorControl setTitle:GPSLabLocalized(@"route.stop.return") forSegmentAtIndex:1];
    }
    _customSpeedField.placeholder = GPSLabLocalized(@"route.customSpeed");
    _modeHeader.text = GPSLabLocalized(@"route.section.mode");
    _endpointsHeader.text = GPSLabLocalized(@"route.section.endpoints");
    _playbackHeader.text = GPSLabLocalized(@"route.section.playback");
    _onStopHeader.text = GPSLabLocalized(@"route.section.onStop");
    _speedsLabel.text = GPSLabLocalized(@"route.speedsInfo");
    [_setStartButton setTitle:GPSLabLocalized(@"route.setStart") forState:UIControlStateNormal];
    [_setEndButton setTitle:GPSLabLocalized(@"route.setEnd") forState:UIControlStateNormal];
    [_playButton setTitle:GPSLabLocalized(@"route.start") forState:UIControlStateNormal];
    [_pauseButton setTitle:GPSLabLocalized(@"route.pauseResume") forState:UIControlStateNormal];
    [_stopButton setTitle:GPSLabLocalized(@"route.stop") forState:UIControlStateNormal];

    [GPSLabLocalization applyLanguageAttributesToView:self.view];
    [self updateEndpointLabels];
    [self refreshFromEngine];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self startStatusTimer];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self stopStatusTimer];
}

- (void)dealloc {
    [self stopStatusTimer];
}

#pragma mark - Endpoints

- (void)setStartItem:(MKMapItem *)startItem {
    _startItem = startItem;
    [self updateEndpointLabels];
}

- (void)setEndItem:(MKMapItem *)endItem {
    _endItem = endItem;
    [self updateEndpointLabels];
}

- (void)updateEndpointLabels {
    _startLabel.text = [self labelTextForItem:self.startItem start:YES];
    _endLabel.text = [self labelTextForItem:self.endItem start:NO];
}

- (NSString *)labelTextForItem:(MKMapItem *)item start:(BOOL)isStart {
    if (item == nil) {
        return isStart ? GPSLabLocalized(@"route.startLabel") : GPSLabLocalized(@"route.endLabel");
    }
    CLLocationCoordinate2D coordinate = item.placemark.coordinate;
    NSString *latitude = [GPSLabLocalization decimalString:coordinate.latitude fractionDigits:5];
    NSString *longitude = [GPSLabLocalization decimalString:coordinate.longitude fractionDigits:5];
    NSString *coordinates = [NSString stringWithFormat:@"%@, %@", latitude, longitude];
    NSString *format = isStart ? GPSLabLocalized(@"route.startLabel.format")
                               : GPSLabLocalized(@"route.endLabel.format");
    NSString *text = [NSString stringWithFormat:format, coordinates];
    return text;
}

- (void)pickStartTapped {
    if (self.pickStartHandler != nil) {
        self.pickStartHandler();
    }
}

- (void)pickEndTapped {
    if (self.pickEndHandler != nil) {
        self.pickEndHandler();
    }
}

#pragma mark - Config changes

- (void)modeChanged {
    [self updateCustomSpeedEnabled];
    GPSLabConfiguration *configuration = [[GPSLabEngine sharedEngine] configuration];
    configuration.routeMode = (GPSLabRouteMode)_modeControl.selectedSegmentIndex;
    [[GPSLabEngine sharedEngine] applyConfiguration:configuration];
    [[GPSLabEngine sharedEngine] persistConfiguration];
}

- (void)updateCustomSpeedEnabled {
    BOOL isCustom = _modeControl.selectedSegmentIndex == GPSLabRouteModeCustom;
    _customSpeedField.enabled = isCustom;
    _customSpeedField.alpha = isCustom ? 1.0 : 0.5;
}

- (void)stopBehaviorChanged {
    GPSLabConfiguration *configuration = [[GPSLabEngine sharedEngine] configuration];
    configuration.stopBehavior = (GPSLabStopBehavior)_stopBehaviorControl.selectedSegmentIndex;
    [[GPSLabEngine sharedEngine] applyConfiguration:configuration];
    [[GPSLabEngine sharedEngine] persistConfiguration];
}

#pragma mark - Playback

- (void)startTapped {
    if (self.startItem == nil || self.endItem == nil) {
        [self showAlertWithTitle:GPSLabLocalized(@"route.incomplete.title")
                         message:GPSLabLocalized(@"route.incomplete.message")];
        return;
    }

    GPSLabConfiguration *configuration = [[GPSLabEngine sharedEngine] configuration];
    double customSpeed = 0.0;
    if (_customSpeedField.text.length > 0 &&
        [GPSLabLocalization parseNumber:_customSpeedField.text value:&customSpeed] &&
        customSpeed > 0.0) {
        configuration.routeCustomSpeedKmh = customSpeed;
    }

    GPSLabRouteViewController *__weak weakSelf = self;
    [[GPSLabEngine sharedEngine] startRouteFrom:self.startItem.placemark.coordinate
                                             to:self.endItem.placemark.coordinate
                                           mode:(GPSLabRouteMode)_modeControl.selectedSegmentIndex
                                 customSpeedKmh:configuration.routeCustomSpeedKmh
                                     completion:^(NSError *error) {
        GPSLabRouteViewController *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        if (error != nil) {
            [strongSelf showAlertWithTitle:GPSLabLocalized(@"route.failed.title")
                                   message:error.localizedDescription];
        }
        [strongSelf refreshFromEngine];
        if (strongSelf.routeChangedHandler != nil) {
            strongSelf.routeChangedHandler();
        }
    }];

    if (self.routeChangedHandler != nil) {
        self.routeChangedHandler();
    }
    [self refreshFromEngine];
}

- (void)pauseTapped {
    GPSLabRouteSimulator *simulator = [[GPSLabEngine sharedEngine] routeSimulator];
    if ([simulator state] == GPSLabRouteStatePaused) {
        [[GPSLabEngine sharedEngine] resumeRoute];
    } else {
        [[GPSLabEngine sharedEngine] pauseRoute];
    }
    [self refreshFromEngine];
}

- (void)stopTapped {
    [[GPSLabEngine sharedEngine] stopRoute];
    if (self.routeChangedHandler != nil) {
        self.routeChangedHandler();
    }
    [self refreshFromEngine];
}

#pragma mark - Status

- (void)startStatusTimer {
    if (_statusTimer != nil) {
        return;
    }
    GPSLabRouteViewController *__weak weakSelf = self;
    _statusTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                   repeats:YES
                                                     block:^(NSTimer *timer) {
        (void)timer;
        [weakSelf refreshFromEngine];
    }];
}

- (void)stopStatusTimer {
    if (_statusTimer != nil) {
        [_statusTimer invalidate];
        _statusTimer = nil;
    }
}

- (void)refreshFromEngine {
    GPSLabRouteSimulator *simulator = [[GPSLabEngine sharedEngine] routeSimulator];
    GPSLabRouteState state = [simulator state];

    _progressView.progress = (float)[simulator progress];

    NSString *stateName = GPSLabLocalized(@"route.state.idle");
    if ([simulator isLoading]) {
        stateName = GPSLabLocalized(@"route.state.loading");
    } else if (state == GPSLabRouteStatePlaying) {
        stateName = GPSLabLocalized(@"route.state.playing");
    } else if (state == GPSLabRouteStatePaused) {
        stateName = GPSLabLocalized(@"route.state.paused");
    }
    NSString *format = GPSLabLocalized(@"route.status.format");
    _statusLabel.text = [NSString stringWithFormat:format,
                         stateName,
                         [simulator totalDistanceMeters],
                         [simulator progress] * 100.0];
}

@end
