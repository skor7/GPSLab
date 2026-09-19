//
//  GPSLabRouteViewController.m
//  GPSLab
//
//  Route controls. The engine remains the single source of truth; this sheet only
//  reads state, drives the existing start/pause/resume/stop API and asks the canvas
//  to pick map endpoints.
//

#import "GPSLabRouteViewController.h"

#import "GPSLabEngine.h"
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
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Route";

    GPSLabConfiguration *configuration = [[GPSLabEngine sharedEngine] configuration];

    _modeControl = [[UISegmentedControl alloc] initWithItems:@[
        GPSLabRouteModeName(GPSLabRouteModeDriving),
        GPSLabRouteModeName(GPSLabRouteModeWalking),
        GPSLabRouteModeName(GPSLabRouteModeCycling),
        GPSLabRouteModeName(GPSLabRouteModeCustom),
    ]];
    _modeControl.selectedSegmentIndex = configuration.routeMode;
    [_modeControl addTarget:self action:@selector(modeChanged) forControlEvents:UIControlEventValueChanged];

    _customSpeedField = [self decimalFieldWithPlaceholder:@"Custom speed (km/h)"];
    _customSpeedField.keyboardType = UIKeyboardTypeDecimalPad;
    _customSpeedField.text = [NSString stringWithFormat:@"%.1f", configuration.routeCustomSpeedKmh];

    _stopBehaviorControl = [[UISegmentedControl alloc] initWithItems:@[
        GPSLabStopBehaviorName(GPSLabStopBehaviorStayAtCurrent),
        GPSLabStopBehaviorName(GPSLabStopBehaviorReturnToStart),
    ]];
    _stopBehaviorControl.selectedSegmentIndex = configuration.stopBehavior;
    [_stopBehaviorControl addTarget:self
                             action:@selector(stopBehaviorChanged)
                   forControlEvents:UIControlEventValueChanged];

    UIButton *setStart = [self actionButtonWithTitle:@"Set start on map" action:@selector(pickStartTapped)];
    UIButton *setEnd = [self actionButtonWithTitle:@"Set end on map" action:@selector(pickEndTapped)];
    _startLabel = [self bodyLabel:@"Start: not set"];
    _endLabel = [self bodyLabel:@"End: not set"];
    _startLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    _endLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    _startLabel.textColor = UIColor.secondaryLabelColor;
    _endLabel.textColor = UIColor.secondaryLabelColor;

    UIButton *play = [self actionButtonWithTitle:@"Start route" action:@selector(startTapped)];
    UIButton *pause = [self actionButtonWithTitle:@"Pause / Resume" action:@selector(pauseTapped)];
    UIButton *stop = [self actionButtonWithTitle:@"Stop route" action:@selector(stopTapped)];

    _progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    _statusLabel = [self bodyLabel:@"Idle"];
    _statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    _statusLabel.textColor = UIColor.secondaryLabelColor;

    UIStackView *content = self.contentStack;
    [content addArrangedSubview:[self sectionHeaderLabel:@"Mode"]];
    [content addArrangedSubview:_modeControl];
    [content addArrangedSubview:[self bodyLabel:@"Speeds: Walking 5 | Cycling 15 | Driving 50 km/h. "
                                               @"Custom uses the value below."]];
    [content addArrangedSubview:_customSpeedField];
    [content addArrangedSubview:[self sectionHeaderLabel:@"Endpoints"]];
    [content addArrangedSubview:setStart];
    [content addArrangedSubview:setEnd];
    [content addArrangedSubview:_startLabel];
    [content addArrangedSubview:_endLabel];
    [content addArrangedSubview:[self sectionHeaderLabel:@"Playback"]];
    [content addArrangedSubview:play];
    [content addArrangedSubview:pause];
    [content addArrangedSubview:stop];
    [content addArrangedSubview:_progressView];
    [content addArrangedSubview:_statusLabel];
    [content addArrangedSubview:[self sectionHeaderLabel:@"On stop"]];
    [content addArrangedSubview:_stopBehaviorControl];

    [self updateEndpointLabels];
    [self refreshFromEngine];
    [self updateCustomSpeedEnabled];
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
    _startLabel.text = [self labelTextForItem:self.startItem prefix:@"Start: "];
    _endLabel.text = [self labelTextForItem:self.endItem prefix:@"End: "];
}

- (NSString *)labelTextForItem:(MKMapItem *)item prefix:(NSString *)prefix {
    if (item == nil) {
        return [prefix stringByAppendingString:@"not set"];
    }
    CLLocationCoordinate2D coordinate = item.placemark.coordinate;
    return [NSString stringWithFormat:@"%@%.5f, %.5f", prefix, coordinate.latitude, coordinate.longitude];
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
        [self showAlertWithTitle:@"Route incomplete" message:@"Set both a start and an end point first."];
        return;
    }

    GPSLabConfiguration *configuration = [[GPSLabEngine sharedEngine] configuration];
    double customSpeed = [_customSpeedField.text doubleValue];
    if (customSpeed > 0.0) {
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
            [strongSelf showAlertWithTitle:@"Route failed" message:error.localizedDescription];
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

    NSString *stateName = @"Idle";
    if ([simulator isLoading]) {
        stateName = @"Loading route";
    } else if (state == GPSLabRouteStatePlaying) {
        stateName = @"Playing";
    } else if (state == GPSLabRouteStatePaused) {
        stateName = @"Paused";
    }
    _statusLabel.text = [NSString stringWithFormat:@"%@  %.0f m  %.0f%%",
                         stateName, [simulator totalDistanceMeters], [simulator progress] * 100.0];
}

@end
