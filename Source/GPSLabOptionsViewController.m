//
//  GPSLabOptionsViewController.m
//  GPSLab
//
//  Options hub. Destination sheets are requested through handlers so the canvas owns
//  presentation and dismissal; preferences are applied through handlers too.
//

#import "GPSLabOptionsViewController.h"

@interface GPSLabOptionsViewController ()
@property (nonatomic, strong) UISwitch *keepLastSwitch;
@property (nonatomic, strong) UISwitch *realLocationSwitch;
@property (nonatomic, strong) UISegmentedControl *mapStyleControl;
@end

@implementation GPSLabOptionsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Options";

    UIButton *manual = [self actionButtonWithTitle:@"Manual coordinate..." action:@selector(manualTapped)];
    UIButton *recents = [self actionButtonWithTitle:@"Recents..." action:@selector(recentsTapped)];
    UIButton *fluctuation = [self actionButtonWithTitle:@"Location fluctuation..."
                                                 action:@selector(fluctuationTapped)];

    self.keepLastSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
    self.keepLastSwitch.on = self.keepLastCoordinate;
    [self.keepLastSwitch addTarget:self
                            action:@selector(keepLastChanged)
                  forControlEvents:UIControlEventValueChanged];

    self.realLocationSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
    self.realLocationSwitch.on = self.realLocationEnabled;
    [self.realLocationSwitch addTarget:self
                                action:@selector(realLocationChanged)
                      forControlEvents:UIControlEventValueChanged];

    self.mapStyleControl = [[UISegmentedControl alloc] initWithItems:@[@"Standard", @"Hybrid", @"Satellite"]];
    self.mapStyleControl.selectedSegmentIndex = self.mapStyle;
    [self.mapStyleControl addTarget:self
                             action:@selector(mapStyleChanged)
                   forControlEvents:UIControlEventValueChanged];

    UIStackView *content = self.contentStack;
    [content addArrangedSubview:[self sectionHeaderLabel:@"Anchor"]];
    [content addArrangedSubview:manual];
    [content addArrangedSubview:recents];
    [content addArrangedSubview:fluctuation];
    [content addArrangedSubview:[self sectionHeaderLabel:@"Preferences"]];
    [content addArrangedSubview:[self rowWithTitle:@"Keep last coordinate" control:self.keepLastSwitch]];
    [content addArrangedSubview:[self rowWithTitle:@"Show real user location" control:self.realLocationSwitch]];
    [content addArrangedSubview:[self sectionHeaderLabel:@"Map style"]];
    [content addArrangedSubview:self.mapStyleControl];

    // Active is deliberately silent; only a meaningful status (e.g. grace) is shown here.
    if (self.subscriptionStatusText.length > 0) {
        [content addArrangedSubview:[self sectionHeaderLabel:@"Subscription"]];
        [content addArrangedSubview:[self bodyLabel:self.subscriptionStatusText]];
    }
}

- (void)manualTapped {
    if (self.manualEntryHandler != nil) {
        self.manualEntryHandler();
    }
}

- (void)recentsTapped {
    if (self.recentsHandler != nil) {
        self.recentsHandler();
    }
}

- (void)fluctuationTapped {
    if (self.fluctuationHandler != nil) {
        self.fluctuationHandler();
    }
}

- (void)keepLastChanged {
    if (self.keepLastHandler != nil) {
        self.keepLastHandler(self.keepLastSwitch.on);
    }
}

- (void)realLocationChanged {
    if (self.realLocationHandler != nil) {
        self.realLocationHandler(self.realLocationSwitch.on);
    }
}

- (void)mapStyleChanged {
    if (self.mapStyleHandler != nil) {
        self.mapStyleHandler(self.mapStyleControl.selectedSegmentIndex);
    }
}

@end
