//
//  GPSLabTheme.h
//  GPSLab
//
//  Fixed dark/violet visual tokens that reproduce the approved UI reference
//  (UI_REFERENCE_FINAL.html). Values are the exact reference palette; all fonts
//  are the system font at the reference sizes/weights (no bundled or remote fonts).
//

#ifndef GPSLAB_THEME_H
#define GPSLAB_THEME_H

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/** Panel / card / text / accent tokens from the reference. */
FOUNDATION_EXPORT UIColor *GPSLabThemePanelColor(void);      // #111116
FOUNDATION_EXPORT UIColor *GPSLabThemeCardColor(void);       // #19191e
FOUNDATION_EXPORT UIColor *GPSLabThemeFieldColor(void);      // #0e0e13 / #0f0f12
FOUNDATION_EXPORT UIColor *GPSLabThemeChipColor(void);       // #101014
FOUNDATION_EXPORT UIColor *GPSLabThemeTextColor(void);       // #f5f5f7
FOUNDATION_EXPORT UIColor *GPSLabThemeMutedColor(void);      // #9b9ba4
FOUNDATION_EXPORT UIColor *GPSLabThemeAccentColor(void);     // #8e5cff
FOUNDATION_EXPORT UIColor *GPSLabThemeAccentSoftColor(void); // #cbb6ff
FOUNDATION_EXPORT UIColor *GPSLabThemeGreenColor(void);      // #30d158
FOUNDATION_EXPORT UIColor *GPSLabThemeRedColor(void);        // #ff375f
FOUNDATION_EXPORT UIColor *GPSLabThemeBorderColor(void);     // #2a2a31
FOUNDATION_EXPORT UIColor *GPSLabThemeSeparatorColor(void);  // #28282f

/** Builds an opaque color from a 0xRRGGBB literal. */
FOUNDATION_EXPORT UIColor *GPSLabColorFromHex(uint32_t rgb);

/** System font at an explicit size/weight (Dynamic Type is applied by callers). */
FOUNDATION_EXPORT UIFont *GPSLabThemeFont(CGFloat size, UIFontWeight weight);

/** Rounds a view to the reference radius and adds the reference hairline border. */
FOUNDATION_EXPORT void GPSLabThemeApplyCardStyle(UIView *view, CGFloat radius);

/** Solid violet gradient for primary actions (reference apply-action). */
FOUNDATION_EXPORT CAGradientLayer *GPSLabThemeAccentGradient(void);

NS_ASSUME_NONNULL_END

#endif /* GPSLAB_THEME_H */
