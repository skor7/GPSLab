//
//  GPSLabScheduleViewController.m
//  GPSLab
//

#import "GPSLabScheduleViewController.h"

#import "GPSLabLocalization.h"

@interface GPSLabScheduleViewController ()
@property (nonatomic, strong) UISegmentedControl *modeSegment;
@property (nonatomic, strong) UIDatePicker *startPicker;
@property (nonatomic, strong) UIDatePicker *endPicker;
@property (nonatomic, strong) UILabel *startLabel;
@property (nonatomic, strong) UILabel *endLabel;
@property (nonatomic, strong) UILabel *noteLabel;
@property (nonatomic, strong) UIButton *saveButton;
@property (nonatomic, strong) UIButton *clearButton;
@end

@implementation GPSLabScheduleViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    NSDate *start = self.schedule != nil
        ? [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)self.schedule.startEpoch]
        : [NSDate dateWithTimeIntervalSinceNow:3600.0];
    NSDate *end = self.schedule != nil && self.schedule.endEpoch > self.schedule.startEpoch
        ? [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)self.schedule.endEpoch]
        : [start dateByAddingTimeInterval:3600.0];

    self.modeSegment = [[UISegmentedControl alloc] initWithItems:@[@"", @"", @""]];
    self.modeSegment.selectedSegmentIndex = (self.schedule != nil)
        ? (NSInteger)self.schedule.mode
        : 0;
    [self.modeSegment addTarget:self action:@selector(modeChanged)
               forControlEvents:UIControlEventValueChanged];

    self.startPicker = [self pickerWithDate:start];
    self.endPicker = [self pickerWithDate:end];
    self.startLabel = [self sectionHeaderLabel:GPSLabLocalized(@"schedule.start")];
    self.endLabel = [self sectionHeaderLabel:GPSLabLocalized(@"schedule.end")];
    self.noteLabel = [self bodyLabel:GPSLabLocalized(@"schedule.note")];
    self.saveButton = [self actionButtonWithTitle:GPSLabLocalized(@"common.save")
                                           action:@selector(saveTapped)];
    self.clearButton = [self actionButtonWithTitle:GPSLabLocalized(@"schedule.clear")
                                            action:@selector(clearTapped)];

    UIStackView *content = self.contentStack;
    [content addArrangedSubview:[self sectionHeaderLabel:GPSLabLocalized(@"schedule.mode")]];
    [content addArrangedSubview:self.modeSegment];
    [content addArrangedSubview:self.startLabel];
    [content addArrangedSubview:self.startPicker];
    [content addArrangedSubview:self.endLabel];
    [content addArrangedSubview:self.endPicker];
    [content addArrangedSubview:self.saveButton];
    [content addArrangedSubview:self.clearButton];
    [content addArrangedSubview:self.noteLabel];

    [self gpslab_applyLocalization];
    [self updateVisibility];
}

- (UIDatePicker *)pickerWithDate:(NSDate *)date {
    UIDatePicker *picker = [[UIDatePicker alloc] initWithFrame:CGRectZero];
    picker.datePickerMode = UIDatePickerModeDateAndTime;
    picker.preferredDatePickerStyle = UIDatePickerStyleCompact;
    picker.date = date;
    return picker;
}

- (void)gpslab_applyLocalization {
    self.title = GPSLabLocalized(@"schedule.title");
    if (self.modeSegment != nil) {
        [self.modeSegment setTitle:GPSLabLocalized(@"schedule.mode.none") forSegmentAtIndex:0];
        [self.modeSegment setTitle:GPSLabLocalized(@"schedule.mode.once") forSegmentAtIndex:1];
        [self.modeSegment setTitle:GPSLabLocalized(@"schedule.mode.window") forSegmentAtIndex:2];
        self.startLabel.text = GPSLabLocalized(@"schedule.start");
        self.endLabel.text = GPSLabLocalized(@"schedule.end");
        self.noteLabel.text = GPSLabLocalized(@"schedule.note");
        [self.saveButton setTitle:GPSLabLocalized(@"common.save") forState:UIControlStateNormal];
        [self.clearButton setTitle:GPSLabLocalized(@"schedule.clear") forState:UIControlStateNormal];
    }
}

- (void)modeChanged {
    [self updateVisibility];
}

- (void)updateVisibility {
    NSInteger mode = self.modeSegment.selectedSegmentIndex;
    self.startLabel.hidden = mode == 0;
    self.startPicker.hidden = mode == 0;
    self.endLabel.hidden = mode != 2;
    self.endPicker.hidden = mode != 2;
}

- (void)saveTapped {
    NSInteger modeIndex = self.modeSegment.selectedSegmentIndex;
    if (modeIndex == 0) {
        if (self.saveHandler == nil || !self.saveHandler(nil)) {
            return; // keep the sheet open so input is not lost
        }
        [self gpslab_dismissSheet];
        return;
    }
    long long startEpoch = (long long)[self.startPicker.date timeIntervalSince1970];
    long long endEpoch = (modeIndex == 2)
        ? (long long)[self.endPicker.date timeIntervalSince1970]
        : startEpoch;
    if (!GPSLabProfileScheduleValid(startEpoch, endEpoch) ||
        (modeIndex == 2 && endEpoch <= startEpoch)) {
        [self showAlertWithTitle:GPSLabLocalized(@"schedule.title")
                         message:GPSLabLocalized(@"schedule.note")];
        return;
    }
    NSInteger offset = (NSInteger)[NSTimeZone.localTimeZone
        secondsFromGMTForDate:self.startPicker.date];
    GPSLabProfileScheduleMode mode = (modeIndex == 2)
        ? GPSLabProfileScheduleWindow : GPSLabProfileScheduleOnce;
    GPSLabProfileSchedule *schedule =
        [[GPSLabProfileSchedule alloc] initWithMode:mode
                                          startEpoch:startEpoch
                                            endEpoch:endEpoch
                              timeZoneOffsetSeconds:offset];
    if (self.saveHandler == nil || !self.saveHandler(schedule)) {
        return;
    }
    [self gpslab_dismissSheet];
}

- (void)clearTapped {
    if (self.saveHandler == nil || !self.saveHandler(nil)) {
        return;
    }
    [self gpslab_dismissSheet];
}

@end
