//
//  GPSLabProfilesPanelView.h
//  GPSLab
//
//  Inline profiles card from the approved reference: header + add, a horizontal
//  chip strip, a 4-cell summary (location/fluctuation/Wi-Fi/Bluetooth) and
//  edit/apply actions. Pure presentation; the overlay owns presentation of forms.
//

#import <UIKit/UIKit.h>

#import "GPSLabProfile.h"

NS_ASSUME_NONNULL_BEGIN

@interface GPSLabProfilesPanelView : UIView

@property (nonatomic, copy, nullable) void (^addHandler)(void);
@property (nonatomic, copy, nullable) void (^selectHandler)(GPSLabProfile *profile);
@property (nonatomic, copy, nullable) void (^editHandler)(GPSLabProfile *profile);
@property (nonatomic, copy, nullable) void (^applyHandler)(GPSLabProfile *profile);

- (void)setProfiles:(NSArray<GPSLabProfile *> *)profiles
 selectedIdentifier:(nullable NSString *)selectedIdentifier;

- (void)applyLocalization;

@end

NS_ASSUME_NONNULL_END
