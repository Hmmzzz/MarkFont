#import <CoreText/CoreText.h>
#import <UIKit/UIKit.h>

#import "FMLocalization.h"

// Font Manager's product palette, typography, cards, and Profile visuals.

NS_ASSUME_NONNULL_BEGIN

static inline UIColor *FMColorRGB(CGFloat red, CGFloat green, CGFloat blue) {
    return [UIColor colorWithRed:red / 255.0 green:green / 255.0 blue:blue / 255.0 alpha:1.0];
}

// The product palette intentionally feels closer to paper, ink and printed type
// than to a generic settings utility.
static inline UIColor *FMAccentColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
                   ? FMColorRGB(255, 145, 111)
                   : FMColorRGB(222, 91, 58);
    }];
}

static inline UIColor *FMCanvasColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
                   ? FMColorRGB(16, 18, 17)
                   : FMColorRGB(247, 244, 238);
    }];
}

static inline UIColor *FMCardColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
                   ? FMColorRGB(29, 32, 30)
                   : FMColorRGB(255, 253, 249);
    }];
}

static inline UIColor *FMPrimaryActionColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
                   ? FMColorRGB(242, 239, 231)
                   : FMColorRGB(29, 36, 32);
    }];
}

static inline UIColor *FMPrimaryActionForegroundColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
                   ? FMColorRGB(24, 28, 26)
                   : UIColor.whiteColor;
    }];
}

static inline UIColor *FMHairlineColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
                   ? [UIColor.whiteColor colorWithAlphaComponent:0.10]
                   : [FMColorRGB(43, 51, 47) colorWithAlphaComponent:0.10];
    }];
}

static inline UIColor *FMSuccessColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
                   ? FMColorRGB(105, 221, 168)
                   : FMColorRGB(28, 143, 94);
    }];
}

static inline UIColor *FMWarnColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
                   ? FMColorRGB(255, 193, 105)
                   : FMColorRGB(190, 111, 24);
    }];
}

static inline UIColor *FMDangerColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
                   ? FMColorRGB(255, 126, 121)
                   : FMColorRGB(202, 56, 61);
    }];
}

static inline UIColor *FMPurpleColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
                   ? FMColorRGB(195, 154, 255)
                   : FMColorRGB(125, 75, 194);
    }];
}

static inline UIColor *FMTintedBackground(UIColor *color) {
    return [color colorWithAlphaComponent:0.12];
}

static inline UIView *FMCardView(void) {
    UIView *view = [[UIView alloc] initWithFrame:CGRectZero];
    view.backgroundColor = FMCardColor();
    view.layer.cornerRadius = 22.0;
    view.layer.cornerCurve = kCACornerCurveContinuous;
    view.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
    view.layer.borderColor = FMHairlineColor().CGColor;
    return view;
}

static inline UILabel *FMLabel(UIFontTextStyle style, UIFontWeight weight, UIColor *color) {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    UIFontDescriptor *descriptor = [UIFontDescriptor preferredFontDescriptorWithTextStyle:style];
    label.font = [UIFont systemFontOfSize:descriptor.pointSize weight:weight];
    label.textColor = color;
    label.adjustsFontForContentSizeCategory = YES;
    label.numberOfLines = 0;
    return label;
}

static inline UIFont *FMFontWithDesign(CGFloat size, UIFontWeight weight,
                                      UIFontDescriptorSystemDesign design) {
    UIFont *base = [UIFont systemFontOfSize:size weight:weight];
    UIFontDescriptor *designed = [base.fontDescriptor fontDescriptorWithDesign:design];
    return designed == nil ? base : [UIFont fontWithDescriptor:designed size:size];
}

static inline NSString *FMFriendlyProfileName(NSString *_Nullable profileID,
                                              NSString *_Nullable storedName) {
    if (profileID == nil) return FMLocalized(@"系统默认");
    if ([profileID isEqual:@"profile-a"]) return FMLocalized(@"柔和圆体");
    if ([profileID isEqual:@"profile-b"]) return FMLocalized(@"醒目黑体");
    if (storedName.length > 0) return storedName;
    return FMLocalized(@"自定义字体");
}

static inline NSString *FMProfileDescription(NSString *_Nullable profileID) {
    if (profileID == nil) return FMLocalized(@"清晰、克制，熟悉的系统阅读节奏");
    if ([profileID isEqual:@"profile-a"]) return FMLocalized(@"柔和亲切，适合轻松的日常阅读");
    if ([profileID isEqual:@"profile-b"]) return FMLocalized(@"更有分量，让标题和重点脱颖而出");
    return FMLocalized(@"来自你的字体库，为系统界面换一种表达");
}

static inline UIFont *FMRepresentativeFont(NSString *_Nullable profileID, CGFloat size,
                                           UIFontWeight weight) {
    if ([profileID isEqual:@"profile-a"]) {
        return FMFontWithDesign(size, weight, UIFontDescriptorSystemDesignRounded);
    }
    if ([profileID isEqual:@"profile-b"]) {
        return FMFontWithDesign(size, UIFontWeightBlack, UIFontDescriptorSystemDesignDefault);
    }
    if ([profileID hasPrefix:@"import-"]) {
        return FMFontWithDesign(size, weight, UIFontDescriptorSystemDesignSerif);
    }
    return FMFontWithDesign(size, weight, UIFontDescriptorSystemDesignDefault);
}

// Creates a process-local preview font directly from a Profile replacement.
// This does not register or install the font and therefore cannot affect the
// system outside Font Manager's own preview labels.
static inline NSInteger FMPreviewFontNameScore(NSString *_Nullable fontName,
                                               NSString *_Nullable path) {
    if (![fontName isKindOfClass:NSString.class] || fontName.length == 0) {
        return NSIntegerMax;
    }
    NSString *name = fontName.lowercaseString;
    NSInteger score = 1000;

    // Width is more important than weight for a neutral specimen. In
    // particular, iOS 17 SFUI exposes UltraCompressed descriptors first.
    if ([name containsString:@"compressed"] || [name containsString:@"condensed"] ||
        [name containsString:@"expanded"]) score += 800;
    if ([name containsString:@"italic"] || [name containsString:@"oblique"]) score += 500;

    if ([name containsString:@"regular"]) score -= 400;
    else if ([name containsString:@"-medium"]) score += 50;
    else if ([name containsString:@"-light"]) score += 180;
    else if ([name containsString:@"-thin"] || [name containsString:@"ultralight"]) score += 260;
    else if ([name containsString:@"semibold"] || [name containsString:@"-bold"] ||
             [name containsString:@"-heavy"] || [name containsString:@"-black"]) score += 220;

    if ([name hasPrefix:@"."]) score += 5;
    if ([name hasSuffix:@"g1"] || [name hasSuffix:@"g2"] ||
        [name hasSuffix:@"g3"] || [name hasSuffix:@"g4"]) score += 20;

    // PingFang.ttc begins with HK and TC faces. Simplified Chinese specimens
    // should use the SC Regular face when it is available.
    if ([path.lowercaseString.lastPathComponent containsString:@"pingfang"] ||
        [name containsString:@"pingfang"]) {
        if ([name containsString:@"pingfangsc-regular"]) score -= 120;
        else if ([name containsString:@"pingfangtc-regular"]) score += 20;
        else if ([name containsString:@"pingfanghk-regular"]) score += 40;
    }
    return score;
}

static inline UIFont *_Nullable FMPreviewFontAtPath(NSString *_Nullable path,
                                                    CGFloat pointSize) {
    if (![path isKindOfClass:NSString.class] || path.length == 0 ||
        ![NSFileManager.defaultManager fileExistsAtPath:path]) {
        return nil;
    }
    CFArrayRef descriptors = CTFontManagerCreateFontDescriptorsFromURL(
        (__bridge CFURLRef)[NSURL fileURLWithPath:path isDirectory:NO]);
    if (descriptors == NULL || CFArrayGetCount(descriptors) == 0) {
        if (descriptors != NULL) CFRelease(descriptors);
        return nil;
    }
    CTFontDescriptorRef descriptor = NULL;
    NSInteger bestScore = NSIntegerMax;
    CFIndex count = CFArrayGetCount(descriptors);
    for (CFIndex index = 0; index < count; index++) {
        CTFontDescriptorRef candidate =
            (CTFontDescriptorRef)CFArrayGetValueAtIndex(descriptors, index);
        NSString *fontName = CFBridgingRelease(
            CTFontDescriptorCopyAttribute(candidate, kCTFontNameAttribute));
        NSInteger score = FMPreviewFontNameScore(fontName, path);
        if (descriptor == NULL || score < bestScore) {
            descriptor = candidate;
            bestScore = score;
        }
    }
    CTFontRef coreTextFont = descriptor == NULL
        ? NULL
        : CTFontCreateWithFontDescriptor(descriptor, pointSize, NULL);
    CFRelease(descriptors);
    return coreTextFont == NULL ? nil : CFBridgingRelease(coreTextFont);
}

static inline NSArray<UIColor *> *FMProfileGradientColors(NSString *_Nullable profileID,
                                                          UITraitCollection *traits) {
    (void)traits;
    NSArray<UIColor *> *lightColors = nil;
    NSArray<UIColor *> *darkColors = nil;
    if ([profileID isEqual:@"profile-a"]) {
        lightColors = @[ FMColorRGB(220, 242, 225), FMColorRGB(166, 220, 194) ];
        darkColors = @[ FMColorRGB(31, 77, 61), FMColorRGB(21, 50, 42) ];
    } else if ([profileID isEqual:@"profile-b"]) {
        lightColors = @[ FMColorRGB(224, 221, 250), FMColorRGB(183, 178, 232) ];
        darkColors = @[ FMColorRGB(61, 56, 105), FMColorRGB(35, 34, 67) ];
    } else if ([profileID hasPrefix:@"import-"]) {
        lightColors = @[ FMColorRGB(249, 222, 204), FMColorRGB(238, 178, 144) ];
        darkColors = @[ FMColorRGB(104, 57, 42), FMColorRGB(59, 36, 30) ];
    } else {
        lightColors = @[ FMColorRGB(241, 229, 212), FMColorRGB(218, 198, 174) ];
        darkColors = @[ FMColorRGB(76, 65, 53), FMColorRGB(46, 42, 36) ];
    }
    return @[
        [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *currentTraits) {
            return currentTraits.userInterfaceStyle == UIUserInterfaceStyleDark
                       ? darkColors[0]
                       : lightColors[0];
        }],
        [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *currentTraits) {
            return currentTraits.userInterfaceStyle == UIUserInterfaceStyleDark
                       ? darkColors[1]
                       : lightColors[1];
        }],
    ];
}

static inline UIColor *FMProfileInkColor(NSString *_Nullable profileID,
                                         UITraitCollection *traits) {
    (void)profileID;
    (void)traits;
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *currentTraits) {
        return currentTraits.userInterfaceStyle == UIUserInterfaceStyleDark
                   ? FMColorRGB(249, 246, 237)
                   : FMColorRGB(31, 38, 34);
    }];
}

// These mappings are retained for the secondary diagnostics screens only.
static inline NSString *FMClassificationTitle(NSString *classification) {
    if ([classification isEqual:@"initializeEmptyMirror"]) return FMLocalized(@"可准备");
    if ([classification isEqual:@"adoptStockMirror"]) return FMLocalized(@"可接管");
    if ([classification isEqual:@"adoptManualChanges"]) return FMLocalized(@"可保留");
    if ([classification isEqual:@"managedReady"]) return FMLocalized(@"正常");
    if ([classification isEqual:@"unavailable"]) return FMLocalized(@"不可用");
    return FMLocalized(@"已暂停");
}

static inline UIColor *FMClassificationColor(NSString *classification) {
    if ([classification isEqual:@"managedReady"] ||
        [classification isEqual:@"adoptStockMirror"]) return FMSuccessColor();
    if ([classification isEqual:@"initializeEmptyMirror"]) return FMAccentColor();
    if ([classification isEqual:@"adoptManualChanges"]) return FMPurpleColor();
    if ([classification isEqual:@"unavailable"]) return FMDangerColor();
    return FMWarnColor();
}

static inline NSString *FMClassificationSymbol(NSString *classification) {
    if ([classification isEqual:@"managedReady"]) return @"checkmark.shield.fill";
    if ([classification isEqual:@"adoptStockMirror"]) return @"checkmark.circle.fill";
    if ([classification isEqual:@"initializeEmptyMirror"]) return @"sparkles";
    if ([classification isEqual:@"adoptManualChanges"]) return @"tray.and.arrow.down.fill";
    if ([classification isEqual:@"unavailable"]) return @"xmark.octagon.fill";
    return @"exclamationmark.triangle.fill";
}

static inline NSString *FMActionTitle(NSString *action) {
    if ([action isEqual:@"none"]) return FMLocalized(@"无需操作");
    if ([action isEqual:@"initializeProvider"]) return FMLocalized(@"准备字体环境");
    if ([action isEqual:@"adoptStockMirror"]) return FMLocalized(@"接管现有系统副本");
    if ([action isEqual:@"importExistingDifferences"]) return FMLocalized(@"保存现有字体改动");
    if ([action isEqual:@"restoreStockWithConfirmation"]) return FMLocalized(@"确认后恢复系统字体");
    if ([action isEqual:@"reviewMirrorDifferences"]) return FMLocalized(@"检查现有字体差异");
    if ([action isEqual:@"repairMirror"]) return FMLocalized(@"恢复未完成操作");
    if ([action isEqual:@"installProvider"]) return FMLocalized(@"安装挂载组件");
    if ([action isEqual:@"updateProviderAdapter"]) return FMLocalized(@"更新挂载组件");
    if ([action isEqual:@"repairRootfsAccess"]) return FMLocalized(@"恢复系统字体访问");
    return action;
}

static inline NSString *FMIssueTitle(NSString *issue) {
    NSDictionary<NSString *, NSString *> *titles = @{
        @"providerUnavailable" : FMLocalized(@"挂载组件不可用"),
        @"providerCapabilityMismatch" : FMLocalized(@"挂载能力与当前系统不匹配"),
        @"fontSourceUnavailable" : FMLocalized(@"无法读取系统字体"),
        @"mirrorOutsideJBRoot" : FMLocalized(@"字体镜像位置异常"),
        @"rootfsMirrorAliased" : FMLocalized(@"系统字体与镜像路径重叠"),
        @"unexpectedActiveMapping" : FMLocalized(@"挂载关系不符合预期"),
        @"manifestBuildMismatch" : FMLocalized(@"系统版本与字体基线不匹配"),
        @"stateInvalidOrBuildMismatch" : FMLocalized(@"已保存状态无法继续使用"),
        @"repairRequired" : FMLocalized(@"上次操作需要恢复"),
        @"managedStateEvidenceMismatch" : FMLocalized(@"字体环境状态不一致"),
        @"activeMappingWithoutMirror" : FMLocalized(@"已挂载但找不到字体镜像"),
        @"unexpectedEmptyMirrorManifest" : FMLocalized(@"空镜像状态不一致"),
        @"mirrorIncompleteOrUnsafe" : FMLocalized(@"字体镜像不完整或包含未知内容"),
    };
    return titles[issue] ?: issue;
}

NS_ASSUME_NONNULL_END
