//
//  GPSLabTheme.m
//  GPSLab
//

#import "GPSLabTheme.h"

UIColor *GPSLabColorFromHex(uint32_t rgb) {
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                           green:((rgb >> 8) & 0xFF) / 255.0
                            blue:(rgb & 0xFF) / 255.0
                           alpha:1.0];
}

UIColor *GPSLabThemePanelColor(void)      { return GPSLabColorFromHex(0x111116); }
UIColor *GPSLabThemeCardColor(void)       { return GPSLabColorFromHex(0x19191E); }
UIColor *GPSLabThemeFieldColor(void)      { return GPSLabColorFromHex(0x0E0E13); }
UIColor *GPSLabThemeChipColor(void)       { return GPSLabColorFromHex(0x101014); }
UIColor *GPSLabThemeTextColor(void)       { return GPSLabColorFromHex(0xF5F5F7); }
UIColor *GPSLabThemeMutedColor(void)      { return GPSLabColorFromHex(0x9B9BA4); }
UIColor *GPSLabThemeAccentColor(void)     { return GPSLabColorFromHex(0x8E5CFF); }
UIColor *GPSLabThemeAccentSoftColor(void) { return GPSLabColorFromHex(0xCBB6FF); }
UIColor *GPSLabThemeGreenColor(void)      { return GPSLabColorFromHex(0x30D158); }
UIColor *GPSLabThemeRedColor(void)        { return GPSLabColorFromHex(0xFF375F); }
UIColor *GPSLabThemeBorderColor(void)     { return GPSLabColorFromHex(0x2A2A31); }
UIColor *GPSLabThemeSeparatorColor(void)  { return GPSLabColorFromHex(0x28282F); }

UIFont *GPSLabThemeFont(CGFloat size, UIFontWeight weight) {
    return [UIFont systemFontOfSize:size weight:weight];
}

void GPSLabThemeApplyCardStyle(UIView *view, CGFloat radius) {
    view.layer.cornerRadius = radius;
    view.layer.masksToBounds = YES;
    view.layer.borderWidth = 0.5;
    view.layer.borderColor = GPSLabThemeBorderColor().CGColor;
}

CAGradientLayer *GPSLabThemeAccentGradient(void) {
    CAGradientLayer *gradient = [CAGradientLayer layer];
    gradient.colors = @[(id)GPSLabColorFromHex(0x9C64FF).CGColor,
                        (id)GPSLabColorFromHex(0x7A42EB).CGColor];
    gradient.startPoint = CGPointMake(0.5, 0.0);
    gradient.endPoint = CGPointMake(0.5, 1.0);
    return gradient;
}
