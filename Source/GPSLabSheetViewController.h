//
//  GPSLabSheetViewController.h
//  GPSLab
//
//  Small reusable native sheet building blocks. Feature screens subclass the form
//  base or present their own table controller wrapped by `GPSLabSheetNavigationController`.
//  These helpers keep the map canvas free of dashboard code.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * Wraps `root` in a navigation controller configured as a native sheet (medium/large
 * detents, visible grabber, rounded corners) and installs a Close bar button on the
 * root when it has no bar buttons yet. Pushed controllers keep the system Back button.
 */
FOUNDATION_EXPORT UINavigationController *GPSLabSheetNavigationController(UIViewController *root);

@interface UIViewController (GPSLabSheet)

/** Dismisses the enclosing sheet presentation (works from any controller in the stack). */
- (void)gpslab_dismissSheet;

@end

/** Lightweight base for form-like sheets: a scrolling vertical stack plus shared helpers. */
@interface GPSLabSheetViewController : UIViewController

/** Vertical stack the subclass fills in `viewDidLoad`. */
@property (nonatomic, strong, readonly) UIStackView *contentStack;

- (UILabel *)sectionHeaderLabel:(NSString *)text;
- (UIStackView *)rowWithTitle:(NSString *)title control:(UIView *)control;
- (UIButton *)actionButtonWithTitle:(NSString *)title action:(SEL)action;
- (UITextField *)decimalFieldWithPlaceholder:(NSString *)placeholder;
- (UILabel *)bodyLabel:(NSString *)text;

/** Presents a validation alert on top of the sheet. */
- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message;

@end

NS_ASSUME_NONNULL_END
