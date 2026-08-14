#import "FMProfileLabViewController.h"

// Product UI contains no device paths or Simulator fixture implementation.

#import <QuartzCore/QuartzCore.h>

#import "FMDesignSystem.h"
#import "FMFloatingActionDockView.h"
#import "FMFontLibraryViewController.h"
#import "FMProfileWorkspace.h"
#import "FMSettingsViewController.h"

static BOOL FMProfileIDsEqual(NSString *_Nullable left, NSString *_Nullable right) {
    return left == right || [left isEqual:right];
}

static NSString *_Nullable FMNormalizedProfileID(id value) {
    return value == nil || value == NSNull.null ? nil : [value description];
}

static const NSUInteger FMWorkspaceRecoveryRetryLimit = 15;
static const NSTimeInterval FMWorkspaceRecoveryRetryDelay = 1.0;

@interface FMPressableButton : UIButton
@end

@implementation FMPressableButton

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    if (!self.enabled) return;
    NSTimeInterval duration = UIAccessibilityIsReduceMotionEnabled() ? 0.0 : 0.14;
    [UIView animateWithDuration:duration
                          delay:0
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionCurveEaseOut |
                                UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        self.transform = highlighted ? CGAffineTransformMakeScale(0.97, 0.97)
                                     : CGAffineTransformIdentity;
    }
                     completion:nil];
}

@end

@interface FMGradientView : UIView
@property(nonatomic, copy) NSArray<UIColor *> *gradientColors;
@end

@implementation FMGradientView

+ (Class)layerClass {
    return CAGradientLayer.class;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self == nil) return nil;
    CAGradientLayer *gradient = (CAGradientLayer *)self.layer;
    gradient.startPoint = CGPointMake(0.05, 0.08);
    gradient.endPoint = CGPointMake(0.94, 0.92);
    self.layer.cornerRadius = 30;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.layer.masksToBounds = YES;
    if (@available(iOS 17.0, *)) {
        __weak typeof(self) weakSelf = self;
        [self registerForTraitChanges:@[ UITraitUserInterfaceStyle.class ]
                          withHandler:^(__unused id<UITraitEnvironment> environment,
                                        __unused UITraitCollection *previousTraitCollection) {
            [weakSelf updateResolvedGradientColors];
        }];
    }
    return self;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#pragma clang diagnostic ignored "-Wdeprecated-implementations"
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (@available(iOS 17.0, *)) return;
    if (previousTraitCollection == nil ||
        previousTraitCollection.userInterfaceStyle !=
            self.traitCollection.userInterfaceStyle) {
        [self updateResolvedGradientColors];
    }
}
#pragma clang diagnostic pop

- (void)setGradientColors:(NSArray<UIColor *> *)gradientColors {
    _gradientColors = [gradientColors copy];
    [self updateResolvedGradientColors];
}

- (void)updateResolvedGradientColors {
    if (self.gradientColors.count == 0) return;
    UIColor *first = [self.gradientColors.firstObject
        resolvedColorWithTraitCollection:self.traitCollection];
    UIColor *last = [self.gradientColors.lastObject
        resolvedColorWithTraitCollection:self.traitCollection];
    ((CAGradientLayer *)self.layer).colors = @[ (id)first.CGColor, (id)last.CGColor ];
}

@end

@interface FMTypefaceHeroView : FMGradientView
@property(nonatomic, strong) UILabel *previewBadge;
@property(nonatomic, strong) UILabel *decorativeGlyph;
@property(nonatomic, strong) UILabel *headlineLabel;
@property(nonatomic, strong) UILabel *sampleLabel;
@property(nonatomic, strong) UILabel *profileLabel;
- (void)configureWithProfileID:(nullable NSString *)profileID
                          name:(NSString *)name
                   previewFont:(nullable UIFont *)previewFont
              latinPreviewFont:(nullable UIFont *)latinPreviewFont
                       current:(BOOL)current
                       pending:(BOOL)pending
                      animated:(BOOL)animated;
@end

@implementation FMTypefaceHeroView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self == nil) return nil;

    self.accessibilityIdentifier = @"profile_preview";
    self.isAccessibilityElement = YES;

    _decorativeGlyph = [[UILabel alloc] initWithFrame:CGRectZero];
    _decorativeGlyph.translatesAutoresizingMaskIntoConstraints = NO;
    _decorativeGlyph.text = @"Aa";
    _decorativeGlyph.font = [UIFont systemFontOfSize:108 weight:UIFontWeightBlack];
    _decorativeGlyph.alpha = 0.09;
    [self addSubview:_decorativeGlyph];

    _previewBadge = FMLabel(UIFontTextStyleCaption1, UIFontWeightSemibold,
                            FMColorRGB(31, 38, 34));
    _previewBadge.translatesAutoresizingMaskIntoConstraints = NO;
    _previewBadge.text = FMLocalized(@"实时预览");
    _previewBadge.textAlignment = NSTextAlignmentCenter;
    _previewBadge.backgroundColor = [UIColor.whiteColor colorWithAlphaComponent:0.52];
    _previewBadge.layer.cornerRadius = 12;
    _previewBadge.layer.cornerCurve = kCACornerCurveContinuous;
    _previewBadge.layer.masksToBounds = YES;
    [self addSubview:_previewBadge];

    _headlineLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _headlineLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _headlineLabel.numberOfLines = 2;
    _headlineLabel.adjustsFontSizeToFitWidth = YES;
    _headlineLabel.minimumScaleFactor = 0.78;
    _headlineLabel.text = FMLocalized(@"让每个字，\n都有自己的性格。");
    [self addSubview:_headlineLabel];

    _sampleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _sampleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _sampleLabel.text = FMLocalized(@"春风有信 · 0123456789");
    _sampleLabel.alpha = 0.68;
    [self addSubview:_sampleLabel];

    _profileLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _profileLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _profileLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
    _profileLabel.textAlignment = NSTextAlignmentRight;
    [self addSubview:_profileLabel];

    [NSLayoutConstraint activateConstraints:@[
        [_previewBadge.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:22],
        [_previewBadge.topAnchor constraintEqualToAnchor:self.topAnchor constant:18],
        [_previewBadge.widthAnchor constraintEqualToConstant:88],
        [_previewBadge.heightAnchor constraintEqualToConstant:25],

        [_decorativeGlyph.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:16],
        [_decorativeGlyph.topAnchor constraintEqualToAnchor:self.topAnchor constant:-26],

        [_headlineLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:22],
        [_headlineLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-22],
        [_headlineLabel.topAnchor constraintEqualToAnchor:_previewBadge.bottomAnchor constant:19],

        [_sampleLabel.leadingAnchor constraintEqualToAnchor:_headlineLabel.leadingAnchor],
        [_sampleLabel.topAnchor constraintEqualToAnchor:_headlineLabel.bottomAnchor constant:8],

        [_profileLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:22],
        [_profileLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-22],
        [_profileLabel.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-18],
    ]];
    return self;
}

- (void)configureWithProfileID:(NSString *_Nullable)profileID
                          name:(NSString *)name
                   previewFont:(UIFont *_Nullable)previewFont
              latinPreviewFont:(UIFont *_Nullable)latinPreviewFont
                       current:(BOOL)current
                       pending:(BOOL)pending
                      animated:(BOOL)animated {
    void (^updates)(void) = ^{
        UIColor *ink = FMProfileInkColor(profileID, self.traitCollection);
        self.gradientColors = FMProfileGradientColors(profileID, self.traitCollection);
        UIFont *decorativeFont = latinPreviewFont ?: previewFont;
        self.decorativeGlyph.font = decorativeFont != nil
            ? [decorativeFont fontWithSize:108]
            : FMRepresentativeFont(profileID, 108, UIFontWeightBlack);
        self.decorativeGlyph.textColor = ink;
        self.headlineLabel.font = previewFont != nil
            ? [previewFont fontWithSize:34]
            : FMRepresentativeFont(profileID, 34, UIFontWeightBold);
        self.headlineLabel.textColor = ink;
        UIFont *sampleChineseFont = previewFont != nil
            ? [previewFont fontWithSize:14.5]
            : FMRepresentativeFont(profileID, 14.5, UIFontWeightMedium);
        UIFont *sampleNumberFont = latinPreviewFont != nil
            ? [latinPreviewFont fontWithSize:14.5]
            : sampleChineseFont;
        NSString *sampleText = FMLocalized(@"春风有信 · 0123456789");
        NSMutableAttributedString *sample =
            [[NSMutableAttributedString alloc] initWithString:sampleText
                                                   attributes:@{
                NSFontAttributeName : sampleChineseFont,
            }];
        NSRange numberRange = [sampleText rangeOfString:@"0123456789"];
        [sample addAttribute:NSFontAttributeName
                       value:sampleNumberFont
                       range:numberRange];
        self.sampleLabel.attributedText = sample;
        self.sampleLabel.textColor = ink;
        self.profileLabel.text = name;
        self.profileLabel.textColor = ink;
        NSString *stateText = pending ? FMLocalized(@"等待 Respring")
                                      : (current ? FMLocalized(@"正在使用") : FMLocalized(@"实时预览"));
        if (current && !pending) {
            NSMutableAttributedString *badge =
                [[NSMutableAttributedString alloc] initWithString:
                    [@"●  " stringByAppendingString:stateText]];
            [badge addAttributes:@{
                NSForegroundColorAttributeName : FMSuccessColor(),
                NSFontAttributeName : [UIFont systemFontOfSize:8 weight:UIFontWeightBold],
            }
                           range:NSMakeRange(0, 1)];
            self.previewBadge.attributedText = badge;
        } else {
            self.previewBadge.attributedText = nil;
            self.previewBadge.text = stateText;
        }
        self.accessibilityLabel = [NSString stringWithFormat:@"%@，%@，%@",
                                                              stateText,
                                                              name,
                                                              FMProfileDescription(profileID)];
    };
    if (animated && !UIAccessibilityIsReduceMotionEnabled()) {
        [UIView transitionWithView:self
                          duration:0.22
                           options:UIViewAnimationOptionTransitionCrossDissolve |
                                   UIViewAnimationOptionCurveEaseOut |
                                   UIViewAnimationOptionBeginFromCurrentState
                        animations:updates
                        completion:nil];
    } else {
        updates();
    }
}

@end

@interface FMFontStyleCard : UIControl
@property(nonatomic, copy, nullable) NSString *profileID;
@property(nonatomic, strong) UILabel *glyphLabel;
@property(nonatomic, strong) UILabel *nameLabel;
@property(nonatomic, strong) UILabel *detailLabel;
@property(nonatomic, strong) UILabel *stateLabel;
- (void)configureWithProfileID:(nullable NSString *)profileID
                          name:(NSString *)name
                   previewFont:(nullable UIFont *)previewFont
                       current:(BOOL)current
                       pending:(BOOL)pending
                        chosen:(BOOL)chosen
                      animated:(BOOL)animated;
@end

@implementation FMFontStyleCard

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self == nil) return nil;
    self.backgroundColor = FMCardColor();
    self.layer.cornerRadius = 23;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.layer.borderWidth = 1;
    self.layer.borderColor = FMHairlineColor().CGColor;
    self.accessibilityTraits = UIAccessibilityTraitButton;

    _glyphLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _glyphLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _glyphLabel.text = @"Aa";
    [self addSubview:_glyphLabel];

    _nameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _nameLabel.font = [UIFont systemFontOfSize:15.5 weight:UIFontWeightBold];
    _nameLabel.textColor = UIColor.labelColor;
    _nameLabel.adjustsFontSizeToFitWidth = YES;
    _nameLabel.minimumScaleFactor = 0.75;
    [self addSubview:_nameLabel];

    _detailLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _detailLabel.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightRegular];
    _detailLabel.textColor = UIColor.secondaryLabelColor;
    _detailLabel.text = FMLocalized(@"轻点预览");
    [self addSubview:_detailLabel];

    _stateLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _stateLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _stateLabel.font = [UIFont systemFontOfSize:10.5 weight:UIFontWeightSemibold];
    _stateLabel.textAlignment = NSTextAlignmentCenter;
    _stateLabel.layer.cornerRadius = 10;
    _stateLabel.layer.cornerCurve = kCACornerCurveContinuous;
    _stateLabel.layer.masksToBounds = YES;
    [self addSubview:_stateLabel];

    [NSLayoutConstraint activateConstraints:@[
        [_glyphLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
        [_glyphLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:14],
        [_glyphLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-12],

        [_nameLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
        [_nameLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-14],
        [_nameLabel.topAnchor constraintEqualToAnchor:_glyphLabel.bottomAnchor constant:8],

        [_detailLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
        [_detailLabel.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor constant:2],

        [_stateLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
        [_stateLabel.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-13],
        [_stateLabel.heightAnchor constraintEqualToConstant:21],
        [_stateLabel.widthAnchor constraintGreaterThanOrEqualToConstant:52],
    ]];
    return self;
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    NSTimeInterval duration = UIAccessibilityIsReduceMotionEnabled() ? 0 : 0.14;
    [UIView animateWithDuration:duration
                          delay:0
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionCurveEaseOut |
                                UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        self.transform = highlighted ? CGAffineTransformMakeScale(0.97, 0.97)
                                     : (self.selected ? CGAffineTransformMakeScale(1.025, 1.025)
                                                      : CGAffineTransformIdentity);
    }
                     completion:nil];
}

- (void)configureWithProfileID:(NSString *_Nullable)profileID
                          name:(NSString *)name
                   previewFont:(UIFont *_Nullable)previewFont
                       current:(BOOL)current
                       pending:(BOOL)pending
                        chosen:(BOOL)chosen
                      animated:(BOOL)animated {
    self.profileID = profileID;
    self.selected = chosen;
    self.glyphLabel.font = previewFont != nil
        ? [previewFont fontWithSize:43]
        : FMRepresentativeFont(profileID, 43, UIFontWeightBold);
    self.glyphLabel.textColor = UIColor.labelColor;
    self.nameLabel.text = name;
    self.stateLabel.text = pending ? FMLocalized(@"待完成") : (current ? FMLocalized(@"使用中") : (chosen ? FMLocalized(@"预览中") : FMLocalized(@"可选择")));
    self.stateLabel.textColor = pending ? FMWarnColor()
                                        : (current ? FMSuccessColor()
                                                   : (chosen ? FMAccentColor()
                                                             : UIColor.secondaryLabelColor));
    self.stateLabel.backgroundColor = pending ? FMTintedBackground(FMWarnColor())
                                              : (current ? FMTintedBackground(FMSuccessColor())
                                                         : (chosen ? FMTintedBackground(FMAccentColor())
                                                                   : UIColor.tertiarySystemFillColor));
    self.layer.borderWidth = chosen ? 2 : 1;
    self.layer.borderColor = (chosen ? FMAccentColor() : FMHairlineColor()).CGColor;
    self.accessibilityLabel = name;
    self.accessibilityValue = pending ? FMLocalized(@"等待 Respring")
                                      : (current ? FMLocalized(@"正在使用")
                                                 : (chosen ? FMLocalized(@"正在预览") : FMLocalized(@"轻点预览")));
    self.accessibilityTraits = UIAccessibilityTraitButton |
                               (chosen ? UIAccessibilityTraitSelected : 0);
    void (^animations)(void) = ^{
        self.transform = chosen ? CGAffineTransformMakeScale(1.025, 1.025)
                                : CGAffineTransformIdentity;
    };
    if (animated && !UIAccessibilityIsReduceMotionEnabled()) {
        [UIView animateWithDuration:0.26
                              delay:0
             usingSpringWithDamping:0.82
              initialSpringVelocity:0.35
                            options:UIViewAnimationOptionBeginFromCurrentState |
                                    UIViewAnimationOptionAllowUserInteraction
                         animations:animations
                         completion:nil];
    } else {
        animations();
    }
}

@end

@interface FMActivationSheetViewController : UIViewController
@property(nonatomic, copy) NSString *profileName;
@property(nonatomic, copy) void (^respringHandler)(void);
- (instancetype)initWithProfileName:(NSString *)profileName
                    respringHandler:(void (^)(void))respringHandler;
@end

@implementation FMActivationSheetViewController

- (instancetype)initWithProfileName:(NSString *)profileName
                    respringHandler:(void (^)(void))respringHandler {
    self = [super initWithNibName:nil bundle:nil];
    if (self != nil) {
        _profileName = [profileName copy];
        _respringHandler = [respringHandler copy];
        self.modalPresentationStyle = UIModalPresentationPageSheet;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = FMCanvasColor();
    self.view.accessibilityViewIsModal = YES;

    UIView *iconBackground = [[UIView alloc] initWithFrame:CGRectZero];
    iconBackground.translatesAutoresizingMaskIntoConstraints = NO;
    iconBackground.backgroundColor = FMTintedBackground(FMSuccessColor());
    iconBackground.layer.cornerRadius = 28;
    iconBackground.layer.cornerCurve = kCACornerCurveContinuous;

    UIImageView *icon = [[UIImageView alloc]
        initWithImage:[UIImage systemImageNamed:@"checkmark"
                              withConfiguration:[UIImageSymbolConfiguration
                                                    configurationWithPointSize:24
                                                                      weight:UIImageSymbolWeightSemibold]]];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.tintColor = FMSuccessColor();
    [iconBackground addSubview:icon];

    UILabel *status = FMLabel(UIFontTextStyleSubheadline, UIFontWeightSemibold,
                              FMSuccessColor());
    status.translatesAutoresizingMaskIntoConstraints = NO;
    status.text = FMLocalized(@"字体已准备好");

    UILabel *profile = FMLabel(UIFontTextStyleTitle1, UIFontWeightBold,
                               UIColor.labelColor);
    profile.translatesAutoresizingMaskIntoConstraints = NO;
    profile.text = self.profileName;
    profile.numberOfLines = 1;
    profile.adjustsFontSizeToFitWidth = YES;
    profile.minimumScaleFactor = 0.78;

    UIStackView *titleStack = [[UIStackView alloc]
        initWithArrangedSubviews:@[ status, profile ]];
    titleStack.translatesAutoresizingMaskIntoConstraints = NO;
    titleStack.axis = UILayoutConstraintAxisVertical;
    titleStack.alignment = UIStackViewAlignmentFill;
    titleStack.spacing = 0;

    UIStackView *header = [[UIStackView alloc]
        initWithArrangedSubviews:@[ iconBackground, titleStack ]];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    header.axis = UILayoutConstraintAxisHorizontal;
    header.alignment = UIStackViewAlignmentCenter;
    header.spacing = 16;
    [self.view addSubview:header];

    UIView *step = [[UIView alloc] initWithFrame:CGRectZero];
    step.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:step];

    UIImageView *restartIcon = [[UIImageView alloc]
        initWithImage:[UIImage systemImageNamed:@"arrow.clockwise"]];
    restartIcon.translatesAutoresizingMaskIntoConstraints = NO;
    restartIcon.tintColor = FMAccentColor();
    [step addSubview:restartIcon];

    UILabel *stepTitle = FMLabel(UIFontTextStyleSubheadline, UIFontWeightSemibold,
                                 UIColor.labelColor);
    stepTitle.translatesAutoresizingMaskIntoConstraints = NO;
    stepTitle.text = FMLocalized(@"重新载入后在整个系统中生效");

    UILabel *stepDetail = FMLabel(UIFontTextStyleFootnote, UIFontWeightRegular,
                                  UIColor.secondaryLabelColor);
    stepDetail.translatesAutoresizingMaskIntoConstraints = NO;
    stepDetail.text = FMLocalized(@"当前 App 会关闭，设备不会重启");

    UILabel *stepAdvice = FMLabel(UIFontTextStyleCaption1, UIFontWeightRegular,
                                  UIColor.secondaryLabelColor);
    stepAdvice.translatesAutoresizingMaskIntoConstraints = NO;
    stepAdvice.text = FMLocalized(@"若发现字体覆盖不全，请重启用户空间使字体全局生效。");
    stepAdvice.accessibilityIdentifier = @"profile_userspace_restart_hint";

    UIStackView *stepText = [[UIStackView alloc]
        initWithArrangedSubviews:@[ stepTitle, stepDetail, stepAdvice ]];
    stepText.translatesAutoresizingMaskIntoConstraints = NO;
    stepText.axis = UILayoutConstraintAxisVertical;
    stepText.alignment = UIStackViewAlignmentFill;
    stepText.spacing = 2;
    [step addSubview:stepText];

    FMPressableButton *primary = [FMPressableButton buttonWithType:UIButtonTypeSystem];
    primary.translatesAutoresizingMaskIntoConstraints = NO;
    primary.accessibilityIdentifier = @"profile_respring_and_apply";
    UIButtonConfiguration *primaryConfiguration = [UIButtonConfiguration filledButtonConfiguration];
    primaryConfiguration.title = @"Respring";
    primaryConfiguration.image = [UIImage systemImageNamed:@"arrow.clockwise"];
    primaryConfiguration.imagePadding = 8;
    primaryConfiguration.cornerStyle = UIButtonConfigurationCornerStyleLarge;
    primaryConfiguration.baseBackgroundColor = FMPrimaryActionColor();
    primaryConfiguration.baseForegroundColor = FMPrimaryActionForegroundColor();
    primary.configuration = primaryConfiguration;
    [primary addTarget:self action:@selector(respringNow:)
      forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:primary];

    UIButton *later = [UIButton buttonWithType:UIButtonTypeSystem];
    later.translatesAutoresizingMaskIntoConstraints = NO;
    [later setTitle:FMLocalized(@"稍后 Respring") forState:UIControlStateNormal];
    [later addTarget:self action:@selector(dismissLater:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:later];

    [NSLayoutConstraint activateConstraints:@[
        [header.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor
                                          constant:22],
        [header.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24],
        [header.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-24],
        [iconBackground.widthAnchor constraintEqualToConstant:56],
        [iconBackground.heightAnchor constraintEqualToConstant:56],
        [icon.centerXAnchor constraintEqualToAnchor:iconBackground.centerXAnchor],
        [icon.centerYAnchor constraintEqualToAnchor:iconBackground.centerYAnchor],

        [step.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:16],
        [step.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24],
        [step.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-24],
        [step.heightAnchor constraintGreaterThanOrEqualToConstant:72],
        [restartIcon.leadingAnchor constraintEqualToAnchor:step.leadingAnchor],
        [restartIcon.centerYAnchor constraintEqualToAnchor:step.centerYAnchor],
        [restartIcon.widthAnchor constraintEqualToConstant:18],
        [restartIcon.heightAnchor constraintEqualToConstant:18],
        [stepText.leadingAnchor constraintEqualToAnchor:restartIcon.trailingAnchor constant:12],
        [stepText.trailingAnchor constraintEqualToAnchor:step.trailingAnchor],
        [stepText.centerYAnchor constraintEqualToAnchor:step.centerYAnchor],
        [stepText.topAnchor constraintGreaterThanOrEqualToAnchor:step.topAnchor],
        [stepText.bottomAnchor constraintLessThanOrEqualToAnchor:step.bottomAnchor],

        [primary.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [primary.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        [primary.heightAnchor constraintEqualToConstant:54],
        [primary.bottomAnchor constraintEqualToAnchor:later.topAnchor constant:-5],
        [later.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [later.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        [later.heightAnchor constraintEqualToConstant:38],
        [later.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor
                                            constant:-6],
    ]];
}

- (void)respringNow:(id)sender {
    (void)sender;
    if (self.respringHandler != nil) self.respringHandler();
}

- (void)dismissLater:(id)sender {
    (void)sender;
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

@interface FMProfileLabViewController () <UIAdaptivePresentationControllerDelegate>
@property(nonatomic, strong) id<FMProfileWorkspace> workspace;
@property(nonatomic, copy) NSDictionary<NSString *, id> *state;
@property(nonatomic, copy) NSArray<NSDictionary<NSString *, id> *> *profiles;
@property(nonatomic, copy) NSDictionary<NSString *, UIFont *> *previewFontsByProfileID;
@property(nonatomic, copy) NSDictionary<NSString *, UIFont *> *latinPreviewFontsByProfileID;
@property(nonatomic, strong, nullable) UIFont *stockPreviewFont;
@property(nonatomic, strong, nullable) UIFont *stockLatinPreviewFont;
@property(nonatomic, copy, nullable) NSString *workspaceError;
@property(nonatomic, copy, nullable) NSString *selectedProfileID;
@property(nonatomic) BOOL selectedStock;
@property(nonatomic) BOOL hasAnimatedEntrance;
@property(nonatomic, strong, nullable) NSTimer *workspaceRecoveryTimer;
@property(nonatomic) NSUInteger workspaceRecoveryAttempts;

@property(nonatomic, strong) UIScrollView *scrollView;
@property(nonatomic, strong) UIView *contentView;
@property(nonatomic, strong) UILabel *titleLabel;
@property(nonatomic, strong) UILabel *subtitleLabel;
@property(nonatomic, strong) FMTypefaceHeroView *heroView;
@property(nonatomic, strong) UILabel *countLabel;
@property(nonatomic, strong) UIScrollView *profileScrollView;
@property(nonatomic, strong) UIStackView *profileStack;
@property(nonatomic, copy) NSArray<FMFontStyleCard *> *profileCards;
@property(nonatomic, strong) UIView *actionDock;
@property(nonatomic, strong) FMPressableButton *applyButton;
- (void)reloadPreviewFonts;
- (void)scheduleWorkspaceRecoveryRetry;
- (void)cancelWorkspaceRecoveryRetry;
@end

@implementation FMProfileLabViewController

- (instancetype)initWithWorkspace:(id<FMProfileWorkspace>)workspace {
    self = [super initWithNibName:nil bundle:nil];
    if (self != nil) _workspace = workspace;
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = FMCanvasColor();
    self.navigationItem.title = @"";
    self.navigationController.navigationBar.prefersLargeTitles = NO;

    FMPressableButton *settingsButton = [FMPressableButton buttonWithType:UIButtonTypeSystem];
    settingsButton.accessibilityLabel = FMLocalized(@"设置");
    settingsButton.accessibilityIdentifier = @"open_settings";
    UIButtonConfiguration *settingsConfiguration = [UIButtonConfiguration tintedButtonConfiguration];
    settingsConfiguration.image = [UIImage systemImageNamed:@"gearshape.fill"];
    settingsConfiguration.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    settingsConfiguration.baseForegroundColor = FMAccentColor();
    settingsConfiguration.baseBackgroundColor = FMAccentColor();
    settingsButton.configuration = settingsConfiguration;
    [settingsButton addTarget:self action:@selector(openSettings:)
             forControlEvents:UIControlEventTouchUpInside];
    [NSLayoutConstraint activateConstraints:@[
        [settingsButton.widthAnchor constraintEqualToConstant:36],
        [settingsButton.heightAnchor constraintEqualToConstant:36],
    ]];
    UIBarButtonItem *settingsItem =
        [[UIBarButtonItem alloc] initWithCustomView:settingsButton];

    FMPressableButton *libraryButton = [FMPressableButton buttonWithType:UIButtonTypeSystem];
    libraryButton.accessibilityLabel = FMLocalized(@"字体库");
    libraryButton.accessibilityIdentifier = @"open_library";
    UIButtonConfiguration *libraryConfiguration = [UIButtonConfiguration tintedButtonConfiguration];
    libraryConfiguration.image = [UIImage systemImageNamed:@"books.vertical.fill"];
    libraryConfiguration.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    libraryConfiguration.baseForegroundColor = FMAccentColor();
    libraryConfiguration.baseBackgroundColor = FMAccentColor();
    libraryButton.configuration = libraryConfiguration;
    [libraryButton addTarget:self action:@selector(openLibrary:)
            forControlEvents:UIControlEventTouchUpInside];
    [NSLayoutConstraint activateConstraints:@[
        [libraryButton.widthAnchor constraintEqualToConstant:36],
        [libraryButton.heightAnchor constraintEqualToConstant:36],
    ]];
    UIBarButtonItem *libraryItem =
        [[UIBarButtonItem alloc] initWithCustomView:libraryButton];
    // UIKit places the first right item nearest the trailing edge, so the
    // library icon appears immediately to the left of Settings.
    self.navigationItem.rightBarButtonItems = @[ settingsItem, libraryItem ];

    [self buildInterface];
    if (@available(iOS 17.0, *)) {
        __weak typeof(self) weakSelf = self;
        [self registerForTraitChanges:@[ UITraitUserInterfaceStyle.class ]
                          withHandler:^(__unused id<UITraitEnvironment> environment,
                                        __unused UITraitCollection *previousTraitCollection) {
            [weakSelf updatePresentationAnimated:NO];
        }];
    }
    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(applicationDidBecomeActive:)
               name:UIApplicationDidBecomeActiveNotification
             object:nil];
    [self reloadWorkspacePreservingSelection:NO];
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#pragma clang diagnostic ignored "-Wdeprecated-implementations"
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (@available(iOS 17.0, *)) return;
    if (previousTraitCollection == nil ||
        previousTraitCollection.userInterfaceStyle !=
            self.traitCollection.userInterfaceStyle) {
        [self updatePresentationAnimated:NO];
    }
}
#pragma clang diagnostic pop

- (void)dealloc {
    [self cancelWorkspaceRecoveryRetry];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.navigationController.navigationBar.prefersLargeTitles = NO;
    [self reloadWorkspacePreservingSelection:YES];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self animateEntranceIfNeeded];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    (void)notification;
    [self cancelWorkspaceRecoveryRetry];
    self.workspaceRecoveryAttempts = 0;
    [self reloadWorkspacePreservingSelection:YES];
}

- (void)scheduleWorkspaceRecoveryRetry {
    if (self.workspaceRecoveryTimer != nil ||
        self.workspaceRecoveryAttempts >= FMWorkspaceRecoveryRetryLimit) {
        return;
    }
    __weak typeof(self) weakSelf = self;
    NSTimer *timer =
        [NSTimer timerWithTimeInterval:FMWorkspaceRecoveryRetryDelay
                               repeats:NO
                                 block:^(__unused NSTimer *firedTimer) {
        typeof(self) strongSelf = weakSelf;
        if (strongSelf == nil) return;
        strongSelf.workspaceRecoveryTimer = nil;
        strongSelf.workspaceRecoveryAttempts += 1;
        [strongSelf reloadWorkspacePreservingSelection:YES];
    }];
    self.workspaceRecoveryTimer = timer;
    [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
}

- (void)cancelWorkspaceRecoveryRetry {
    [self.workspaceRecoveryTimer invalidate];
    self.workspaceRecoveryTimer = nil;
}

- (void)buildInterface {
    self.scrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.alwaysBounceVertical = YES;
    self.scrollView.showsVerticalScrollIndicator = NO;
    self.scrollView.accessibilityIdentifier = @"profile_home";
    [self.view addSubview:self.scrollView];

    self.contentView = [[UIView alloc] initWithFrame:CGRectZero];
    self.contentView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.scrollView addSubview:self.contentView];

    self.titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.titleLabel.text = @"MarkFont";
    self.titleLabel.font = [UIFont systemFontOfSize:38 weight:UIFontWeightBold];
    self.titleLabel.textColor = UIColor.labelColor;
    [self.contentView addSubview:self.titleLabel];

    self.subtitleLabel = FMLabel(UIFontTextStyleSubheadline, UIFontWeightRegular,
                                 UIColor.secondaryLabelColor);
    self.subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.subtitleLabel.text = FMLocalized(@"先预览，再把喜欢的样子用到整个系统。");
    [self.contentView addSubview:self.subtitleLabel];

    self.heroView = [[FMTypefaceHeroView alloc] initWithFrame:CGRectZero];
    self.heroView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:self.heroView];

    UILabel *sectionTitle = FMLabel(UIFontTextStyleTitle3, UIFontWeightBold, UIColor.labelColor);
    sectionTitle.translatesAutoresizingMaskIntoConstraints = NO;
    sectionTitle.text = FMLocalized(@"挑一种喜欢的风格");
    [self.contentView addSubview:sectionTitle];

    self.countLabel = FMLabel(UIFontTextStyleCaption1, UIFontWeightSemibold,
                              UIColor.tertiaryLabelColor);
    self.countLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.countLabel.textAlignment = NSTextAlignmentRight;
    [self.contentView addSubview:self.countLabel];

    self.profileScrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
    self.profileScrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.profileScrollView.showsHorizontalScrollIndicator = NO;
    self.profileScrollView.alwaysBounceHorizontal = YES;
    self.profileScrollView.decelerationRate = UIScrollViewDecelerationRateFast;
    self.profileScrollView.accessibilityIdentifier = @"profile_carousel";
    [self.contentView addSubview:self.profileScrollView];

    self.profileStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    self.profileStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.profileStack.axis = UILayoutConstraintAxisHorizontal;
    self.profileStack.spacing = 12;
    [self.profileScrollView addSubview:self.profileStack];

    UILabel *hint = FMLabel(UIFontTextStyleFootnote, UIFontWeightRegular,
                            UIColor.tertiaryLabelColor);
    hint.translatesAutoresizingMaskIntoConstraints = NO;
    hint.text = FMLocalized(@"轻点卡片只会预览，不会立即更改系统字体。");
    hint.textAlignment = NSTextAlignmentCenter;
    [self.contentView addSubview:hint];

    self.actionDock = [[FMFloatingActionDockView alloc] initWithFrame:CGRectZero];
    self.actionDock.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.actionDock];

    self.applyButton = [FMPressableButton buttonWithType:UIButtonTypeSystem];
    self.applyButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.applyButton.accessibilityIdentifier = @"profile_apply";
    [self.applyButton addTarget:self
                         action:@selector(applySelectedProfile:)
               forControlEvents:UIControlEventTouchUpInside];
    [self.actionDock addSubview:self.applyButton];

    UILayoutGuide *contentGuide = self.scrollView.contentLayoutGuide;
    UILayoutGuide *frameGuide = self.scrollView.frameLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.scrollView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.contentView.leadingAnchor constraintEqualToAnchor:contentGuide.leadingAnchor],
        [self.contentView.trailingAnchor constraintEqualToAnchor:contentGuide.trailingAnchor],
        [self.contentView.topAnchor constraintEqualToAnchor:contentGuide.topAnchor],
        [self.contentView.bottomAnchor constraintEqualToAnchor:contentGuide.bottomAnchor],
        [self.contentView.widthAnchor constraintEqualToAnchor:frameGuide.widthAnchor],

        [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:20],
        [self.titleLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:8],
        [self.titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.contentView.trailingAnchor
                                                                 constant:-20],
        [self.subtitleLabel.leadingAnchor constraintEqualToAnchor:self.titleLabel.leadingAnchor],
        [self.subtitleLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor
                                                            constant:-20],
        [self.subtitleLabel.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:2],

        [self.heroView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:20],
        [self.heroView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-20],
        [self.heroView.topAnchor constraintEqualToAnchor:self.subtitleLabel.bottomAnchor constant:18],
        [self.heroView.heightAnchor constraintEqualToConstant:236],

        [sectionTitle.leadingAnchor constraintEqualToAnchor:self.heroView.leadingAnchor],
        [sectionTitle.topAnchor constraintEqualToAnchor:self.heroView.bottomAnchor constant:24],
        [self.countLabel.trailingAnchor constraintEqualToAnchor:self.heroView.trailingAnchor],
        [self.countLabel.centerYAnchor constraintEqualToAnchor:sectionTitle.centerYAnchor],
        [self.countLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:sectionTitle.trailingAnchor
                                                                   constant:8],

        [self.profileScrollView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
        [self.profileScrollView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
        [self.profileScrollView.topAnchor constraintEqualToAnchor:sectionTitle.bottomAnchor constant:13],
        [self.profileScrollView.heightAnchor constraintEqualToConstant:166],
        [self.profileStack.leadingAnchor constraintEqualToAnchor:self.profileScrollView.contentLayoutGuide.leadingAnchor
                                                         constant:20],
        [self.profileStack.trailingAnchor constraintEqualToAnchor:self.profileScrollView.contentLayoutGuide.trailingAnchor
                                                          constant:-20],
        [self.profileStack.topAnchor constraintEqualToAnchor:self.profileScrollView.contentLayoutGuide.topAnchor
                                                     constant:5],
        [self.profileStack.bottomAnchor constraintEqualToAnchor:self.profileScrollView.contentLayoutGuide.bottomAnchor
                                                        constant:-5],
        [self.profileStack.heightAnchor constraintEqualToAnchor:self.profileScrollView.frameLayoutGuide.heightAnchor
                                                        constant:-10],

        [hint.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:20],
        [hint.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-20],
        [hint.topAnchor constraintEqualToAnchor:self.profileScrollView.bottomAnchor constant:2],
        [hint.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-116],

        [self.actionDock.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.actionDock.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.actionDock.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.applyButton.leadingAnchor constraintEqualToAnchor:self.actionDock.leadingAnchor
                                                        constant:20],
        [self.applyButton.trailingAnchor constraintEqualToAnchor:self.actionDock.trailingAnchor
                                                         constant:-20],
        [self.applyButton.topAnchor constraintEqualToAnchor:self.actionDock.topAnchor
                                                    constant:14],
        [self.applyButton.heightAnchor constraintEqualToConstant:56],
        [self.applyButton.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor
                                                       constant:-12],
    ]];
}

- (void)reloadWorkspacePreservingSelection:(BOOL)preserveSelection {
    NSError *error = nil;
    if (![self.workspace prepareIfNeeded:&error]) {
        self.workspaceError = error.localizedDescription ?: FMLocalized(@"暂时无法读取字体库");
        self.state = @{};
        self.profiles = @[];
        self.previewFontsByProfileID = @{};
        self.latinPreviewFontsByProfileID = @{};
        self.stockPreviewFont = nil;
        self.stockLatinPreviewFont = nil;
        [self scheduleWorkspaceRecoveryRetry];
    } else {
        [self cancelWorkspaceRecoveryRetry];
        self.workspaceRecoveryAttempts = 0;
        self.state = [self.workspace currentState:&error] ?: @{};
        NSMutableArray<NSDictionary<NSString *, id> *> *profiles = [NSMutableArray arrayWithObject:@{
            @"id" : NSNull.null,
            @"name" : FMLocalized(@"系统默认"),
        }];
        [profiles addObjectsFromArray:self.workspace.availableProfiles];
        self.profiles = profiles;
        [self reloadPreviewFonts];
        self.workspaceError = error.localizedDescription;
    }

    if (!preserveSelection || ![self selectionStillExists]) {
        NSString *initialID = FMNormalizedProfileID([self.state[@"restartRequired"] boolValue]
                                                        ? self.state[@"workingProfileID"]
                                                        : self.state[@"confirmedProfileID"]);
        self.selectedProfileID = initialID;
        self.selectedStock = initialID == nil;
    }
    [self rebuildProfileCards];
    [self updatePresentationAnimated:NO];
}

- (void)reloadPreviewFonts {
    NSMutableDictionary<NSString *, UIFont *> *fonts = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, UIFont *> *latinFonts = [NSMutableDictionary dictionary];
    self.stockPreviewFont = nil;
    self.stockLatinPreviewFont = nil;
    for (NSDictionary<NSString *, id> *profile in self.profiles) {
        NSString *profileID = FMNormalizedProfileID(profile[@"id"]);
        NSDictionary<NSString *, id> *details =
            [self.workspace detailsForProfileID:profileID error:nil];
        NSString *previewFontPath = [details[@"previewFontPath"] isKindOfClass:NSString.class]
                                        ? details[@"previewFontPath"]
                                        : nil;
        UIFont *font = FMPreviewFontAtPath(previewFontPath, 43);
        NSString *latinPreviewFontPath =
            [details[@"previewLatinFontPath"] isKindOfClass:NSString.class]
                ? details[@"previewLatinFontPath"]
                : previewFontPath;
        UIFont *latinFont = FMPreviewFontAtPath(latinPreviewFontPath, 43);
        if (profileID == nil) {
            self.stockPreviewFont = font;
            self.stockLatinPreviewFont = latinFont ?: font;
        } else {
            if (font != nil) fonts[profileID] = font;
            if (latinFont != nil) latinFonts[profileID] = latinFont;
        }
    }
    self.previewFontsByProfileID = fonts;
    self.latinPreviewFontsByProfileID = latinFonts;
}

- (BOOL)selectionStillExists {
    for (NSDictionary<NSString *, id> *profile in self.profiles) {
        NSString *profileID = FMNormalizedProfileID(profile[@"id"]);
        if ((self.selectedStock && profileID == nil) ||
            (!self.selectedStock && FMProfileIDsEqual(profileID, self.selectedProfileID))) {
            return YES;
        }
    }
    return NO;
}

- (void)rebuildProfileCards {
    for (UIView *view in self.profileStack.arrangedSubviews.copy) {
        [self.profileStack removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    NSMutableArray<FMFontStyleCard *> *cards = [NSMutableArray array];
    NSString *confirmedID = FMNormalizedProfileID(self.state[@"confirmedProfileID"]);
    NSString *workingID = FMNormalizedProfileID(self.state[@"workingProfileID"]);
    BOOL restartRequired = [self.state[@"restartRequired"] boolValue];
    for (NSUInteger index = 0; index < self.profiles.count; index++) {
        NSDictionary<NSString *, id> *profile = self.profiles[index];
        NSString *profileID = FMNormalizedProfileID(profile[@"id"]);
        NSString *name = FMFriendlyProfileName(profileID, profile[@"name"]);
        BOOL current = FMProfileIDsEqual(profileID, confirmedID);
        BOOL pending = restartRequired && FMProfileIDsEqual(profileID, workingID);
        BOOL chosen = profileID == nil ? self.selectedStock
                                       : (!self.selectedStock &&
                                          FMProfileIDsEqual(profileID, self.selectedProfileID));
        FMFontStyleCard *card = [[FMFontStyleCard alloc] initWithFrame:CGRectZero];
        card.tag = (NSInteger)index;
        card.accessibilityIdentifier = profileID == nil
                                           ? @"profile_action_stock"
                                           : [@"profile_action_" stringByAppendingString:profileID];
        [card configureWithProfileID:profileID
                                name:name
                         previewFont:profileID == nil
                                         ? self.stockLatinPreviewFont
                                         : self.latinPreviewFontsByProfileID[profileID]
                             current:current
                             pending:pending
                              chosen:chosen
                            animated:NO];
        [card addTarget:self action:@selector(selectProfileCard:)
       forControlEvents:UIControlEventTouchUpInside];
        [self.profileStack addArrangedSubview:card];
        [card.widthAnchor constraintEqualToConstant:150].active = YES;
        [cards addObject:card];
    }
    self.profileCards = cards;
    self.countLabel.text = [NSString stringWithFormat:FMLocalized(@"%lu 种风格"),
                                                       (unsigned long)self.profiles.count];
}

- (void)selectProfileCard:(FMFontStyleCard *)sender {
    if ((NSUInteger)sender.tag >= self.profiles.count) return;
    NSDictionary<NSString *, id> *profile = self.profiles[(NSUInteger)sender.tag];
    NSString *profileID = FMNormalizedProfileID(profile[@"id"]);
    BOOL same = profileID == nil ? self.selectedStock
                                 : (!self.selectedStock &&
                                    FMProfileIDsEqual(profileID, self.selectedProfileID));
    if (same) {
        [[[UISelectionFeedbackGenerator alloc] init] selectionChanged];
        return;
    }
    self.selectedProfileID = profileID;
    self.selectedStock = profileID == nil;
    [[[UISelectionFeedbackGenerator alloc] init] selectionChanged];
    [self updatePresentationAnimated:YES];
}

- (NSDictionary<NSString *, id> *)selectedProfile {
    for (NSDictionary<NSString *, id> *profile in self.profiles) {
        NSString *profileID = FMNormalizedProfileID(profile[@"id"]);
        if ((profileID == nil && self.selectedStock) ||
            (profileID != nil && !self.selectedStock &&
             FMProfileIDsEqual(profileID, self.selectedProfileID))) return profile;
    }
    return @{ @"id" : NSNull.null, @"name" : FMLocalized(@"系统默认") };
}

- (void)updatePresentationAnimated:(BOOL)animated {
    NSDictionary<NSString *, id> *selected = [self selectedProfile];
    NSString *profileID = FMNormalizedProfileID(selected[@"id"]);
    NSString *name = FMFriendlyProfileName(profileID, selected[@"name"]);
    NSString *confirmedID = FMNormalizedProfileID(self.state[@"confirmedProfileID"]);
    NSString *workingID = FMNormalizedProfileID(self.state[@"workingProfileID"]);
    BOOL restartRequired = [self.state[@"restartRequired"] boolValue];
    BOOL current = self.workspaceError.length == 0 &&
                   FMProfileIDsEqual(profileID, confirmedID) && !restartRequired;

    BOOL selectedIsWorking = FMProfileIDsEqual(profileID, workingID);
    [self.heroView configureWithProfileID:profileID
                                     name:name
                              previewFont:profileID == nil
                                              ? self.stockPreviewFont
                                              : self.previewFontsByProfileID[profileID]
                         latinPreviewFont:profileID == nil
                                              ? self.stockLatinPreviewFont
                                              : self.latinPreviewFontsByProfileID[profileID]
                                  current:current
                                  pending:restartRequired && selectedIsWorking
                                 animated:animated];

    for (FMFontStyleCard *card in self.profileCards) {
        BOOL cardCurrent = FMProfileIDsEqual(card.profileID, confirmedID);
        BOOL cardPending = restartRequired && FMProfileIDsEqual(card.profileID, workingID);
        BOOL chosen = card.profileID == nil ? self.selectedStock
                                            : (!self.selectedStock &&
                                               FMProfileIDsEqual(card.profileID,
                                                                 self.selectedProfileID));
        [card configureWithProfileID:card.profileID
                                name:card.nameLabel.text
                         previewFont:card.profileID == nil
                                         ? self.stockLatinPreviewFont
                                         : self.latinPreviewFontsByProfileID[card.profileID]
                             current:cardCurrent
                             pending:cardPending
                              chosen:chosen
                            animated:animated];
    }

    BOOL selectedIsConfirmed = FMProfileIDsEqual(profileID, confirmedID);
    UIButtonConfiguration *configuration = [UIButtonConfiguration filledButtonConfiguration];
    configuration.cornerStyle = UIButtonConfigurationCornerStyleLarge;
    configuration.imagePadding = 8;
    if (self.workspaceError.length > 0) {
        BOOL recovering = self.workspaceRecoveryTimer != nil;
        configuration.title = recovering ? FMLocalized(@"正在恢复字体连接…") : FMLocalized(@"字体库暂时不可用");
        configuration.image = [UIImage systemImageNamed:
            recovering ? @"arrow.clockwise" : @"exclamationmark.triangle"];
        configuration.baseBackgroundColor = UIColor.tertiarySystemFillColor;
        configuration.baseForegroundColor = UIColor.secondaryLabelColor;
        self.applyButton.enabled = NO;
    } else if (restartRequired && selectedIsWorking) {
        if (self.workspace.allowsRestart) {
            configuration.title = @"Respring";
            configuration.image = [UIImage systemImageNamed:@"arrow.clockwise"];
            configuration.baseBackgroundColor = FMPrimaryActionColor();
            configuration.baseForegroundColor = FMPrimaryActionForegroundColor();
            self.applyButton.enabled = YES;
        } else {
            configuration.title = FMLocalized(@"Respring 暂不可用");
            configuration.image = [UIImage systemImageNamed:@"exclamationmark.triangle"];
            configuration.baseBackgroundColor = UIColor.tertiarySystemFillColor;
            configuration.baseForegroundColor = UIColor.secondaryLabelColor;
            self.applyButton.enabled = NO;
        }
    } else if (!restartRequired && selectedIsConfirmed) {
        configuration.title = [NSString stringWithFormat:FMLocalized(@"正在使用「%@」"), name];
        configuration.image = [UIImage systemImageNamed:@"checkmark.circle.fill"];
        configuration.baseBackgroundColor = UIColor.tertiarySystemFillColor;
        configuration.baseForegroundColor = UIColor.secondaryLabelColor;
        self.applyButton.enabled = NO;
    } else if (!self.workspace.allowsChanges) {
        configuration.title = FMLocalized(@"当前版本仅可查看");
        configuration.image = [UIImage systemImageNamed:@"eye.fill"];
        configuration.baseBackgroundColor = UIColor.tertiarySystemFillColor;
        configuration.baseForegroundColor = UIColor.secondaryLabelColor;
        self.applyButton.enabled = NO;
    } else {
        configuration.title = [NSString stringWithFormat:FMLocalized(@"应用「%@」"), name];
        configuration.image = [UIImage systemImageNamed:@"arrow.right"];
        configuration.imagePlacement = NSDirectionalRectEdgeTrailing;
        configuration.baseBackgroundColor = FMPrimaryActionColor();
        configuration.baseForegroundColor = FMPrimaryActionForegroundColor();
        self.applyButton.enabled = YES;
    }
    self.applyButton.configuration = configuration;
}

- (NSString *)displayNameForProfileID:(NSString *)profileID {
    for (NSDictionary<NSString *, id> *profile in self.profiles) {
        NSString *candidate = FMNormalizedProfileID(profile[@"id"]);
        if (FMProfileIDsEqual(candidate, profileID)) {
            return FMFriendlyProfileName(candidate, profile[@"name"]);
        }
    }
    return profileID == nil ? FMLocalized(@"系统默认") : FMLocalized(@"自定义字体");
}

- (void)applySelectedProfile:(id)sender {
    (void)sender;
    NSString *workingID = FMNormalizedProfileID(self.state[@"workingProfileID"]);
    NSString *profileID = self.selectedStock ? nil : self.selectedProfileID;
    if ([self.state[@"restartRequired"] boolValue] &&
        FMProfileIDsEqual(profileID, workingID)) {
        if (!self.workspace.allowsRestart) return;
        [self presentActivationSheet];
        return;
    }
    if (!self.workspace.allowsChanges) return;

    NSError *error = nil;
    if (![self.workspace stageProfileID:profileID error:&error]) {
        [self presentOperationError:error];
        return;
    }
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium]
        impactOccurred];
    [self reloadWorkspacePreservingSelection:YES];
    [self presentActivationSheet];
}

- (void)presentActivationSheet {
    NSString *name = FMFriendlyProfileName(self.selectedStock ? nil : self.selectedProfileID,
                                           [self selectedProfile][@"name"]);
    __weak typeof(self) weakSelf = self;
    FMActivationSheetViewController *sheet =
        [[FMActivationSheetViewController alloc] initWithProfileName:name
                                                     respringHandler:^{
            [weakSelf performRespringAndApply];
        }];
    UISheetPresentationController *presentation = sheet.sheetPresentationController;
    presentation.detents = @[
        [UISheetPresentationControllerDetent customDetentWithIdentifier:@"activation"
                                                                resolver:^CGFloat(
            id<UISheetPresentationControllerDetentResolutionContext> context) {
            return MIN(325, context.maximumDetentValue);
        }]
    ];
    presentation.prefersGrabberVisible = YES;
    presentation.preferredCornerRadius = 30;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)performRespringAndApply {
    if (!self.workspace.allowsRestart) return;
    NSError *error = nil;
    if (![self.workspace requestRespring:&error]) {
        [self presentOperationError:error];
        return;
    }
    NSString *name = [self displayNameForProfileID:FMNormalizedProfileID(self.state[@"workingProfileID"])];
    [[[UINotificationFeedbackGenerator alloc] init]
        notificationOccurred:UINotificationFeedbackTypeSuccess];
    __weak typeof(self) weakSelf = self;
    [self dismissViewControllerAnimated:YES completion:^{
        [weakSelf reloadWorkspacePreservingSelection:NO];
        [weakSelf showSuccessToastWithName:name];
    }];
}

- (void)showSuccessToastWithName:(NSString *)name {
    UIView *toast = FMCardView();
    toast.translatesAutoresizingMaskIntoConstraints = NO;
    toast.backgroundColor = FMPrimaryActionColor();
    toast.layer.borderWidth = 0;
    toast.accessibilityIdentifier = @"profile_success";

    UIImageView *icon = [[UIImageView alloc]
        initWithImage:[UIImage systemImageNamed:@"checkmark.circle.fill"]];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.tintColor = FMPrimaryActionForegroundColor();
    [toast addSubview:icon];

    UILabel *label = FMLabel(UIFontTextStyleSubheadline, UIFontWeightSemibold,
                             FMPrimaryActionForegroundColor());
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = [NSString stringWithFormat:FMLocalized(@"已切换到 %@"), name];
    label.numberOfLines = 1;
    [toast addSubview:label];
    [self.view addSubview:toast];

    [NSLayoutConstraint activateConstraints:@[
        [toast.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [toast.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [toast.heightAnchor constraintEqualToConstant:48],
        [toast.widthAnchor constraintLessThanOrEqualToAnchor:self.view.widthAnchor constant:-40],
        [icon.leadingAnchor constraintEqualToAnchor:toast.leadingAnchor constant:14],
        [icon.centerYAnchor constraintEqualToAnchor:toast.centerYAnchor],
        [icon.widthAnchor constraintEqualToConstant:21],
        [icon.heightAnchor constraintEqualToConstant:21],
        [label.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:9],
        [label.trailingAnchor constraintEqualToAnchor:toast.trailingAnchor constant:-15],
        [label.centerYAnchor constraintEqualToAnchor:toast.centerYAnchor],
    ]];

    BOOL reduced = UIAccessibilityIsReduceMotionEnabled();
    toast.alpha = 0;
    toast.transform = reduced ? CGAffineTransformIdentity
                              : CGAffineTransformConcat(CGAffineTransformMakeTranslation(0, -10),
                                                        CGAffineTransformMakeScale(0.96, 0.96));
    [UIView animateWithDuration:reduced ? 0.18 : 0.24
                          delay:0
         usingSpringWithDamping:0.86
          initialSpringVelocity:0.3
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        toast.alpha = 1;
        toast.transform = CGAffineTransformIdentity;
    }
                     completion:nil];
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, label.text);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.18
                              delay:0
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{
            toast.alpha = 0;
            if (!reduced) toast.transform = CGAffineTransformMakeTranslation(0, -6);
        }
                         completion:^(__unused BOOL finished) {
            [toast removeFromSuperview];
        }];
    });
}

- (void)animateEntranceIfNeeded {
    if (self.hasAnimatedEntrance || UIAccessibilityIsReduceMotionEnabled()) return;
    self.hasAnimatedEntrance = YES;
    NSArray<UIView *> *views = @[ self.heroView, self.profileScrollView ];
    for (UIView *view in views) {
        view.alpha = 0;
        view.transform = CGAffineTransformMakeTranslation(0, 10);
    }
    [views enumerateObjectsUsingBlock:^(UIView *view, NSUInteger index, __unused BOOL *stop) {
        [UIView animateWithDuration:0.26
                              delay:0.04 * index
                            options:UIViewAnimationOptionCurveEaseOut |
                                    UIViewAnimationOptionAllowUserInteraction
                         animations:^{
            view.alpha = 1;
            view.transform = CGAffineTransformIdentity;
        }
                         completion:nil];
    }];
}

- (void)openSettings:(id)sender {
    (void)sender;
    [[[UISelectionFeedbackGenerator alloc] init] selectionChanged];
    __weak typeof(self) weakSelf = self;
    FMSettingsViewController *settings =
        [[FMSettingsViewController alloc] initWithWorkspace:self.workspace
                                           dismissalHandler:^{
            [weakSelf reloadWorkspacePreservingSelection:YES];
        }];
    UINavigationController *navigation =
        [[UINavigationController alloc] initWithRootViewController:settings];
    FMConfigureNavigationController(navigation);
    navigation.modalPresentationStyle = UIModalPresentationPageSheet;
    navigation.view.accessibilityViewIsModal = YES;
    navigation.presentationController.delegate = self;
    [self presentViewController:navigation animated:YES completion:nil];
}

- (void)openLibrary:(id)sender {
    (void)sender;
    [[[UISelectionFeedbackGenerator alloc] init] selectionChanged];
    __weak typeof(self) weakSelf = self;
    FMFontLibraryViewController *library =
        [[FMFontLibraryViewController alloc] initWithWorkspace:self.workspace
                                                 applyHandler:^(NSString *profileID) {
            [weakSelf reloadWorkspacePreservingSelection:NO];
            weakSelf.selectedProfileID = profileID;
            weakSelf.selectedStock = profileID == nil;
            [weakSelf updatePresentationAnimated:NO];
            [weakSelf presentActivationSheet];
        }
                                             dismissalHandler:^{
            [weakSelf reloadWorkspacePreservingSelection:YES];
        }];
    UINavigationController *navigation =
        [[UINavigationController alloc] initWithRootViewController:library];
    FMConfigureNavigationController(navigation);
    navigation.modalPresentationStyle = UIModalPresentationPageSheet;
    navigation.view.accessibilityViewIsModal = YES;
    UISheetPresentationController *sheet = navigation.sheetPresentationController;
    sheet.detents = @[ UISheetPresentationControllerDetent.largeDetent ];
    sheet.prefersGrabberVisible = NO;
    sheet.preferredCornerRadius = 30;
    navigation.presentationController.delegate = self;
    [self presentViewController:navigation animated:YES completion:nil];
}

- (void)presentationControllerDidDismiss:(UIPresentationController *)presentationController {
    (void)presentationController;
    [self reloadWorkspacePreservingSelection:YES];
}

- (void)presentOperationError:(NSError *)error {
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:FMLocalized(@"暂时无法完成")
                                            message:error.localizedDescription
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:FMLocalized(@"好")
                                             style:UIAlertActionStyleDefault
                                           handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
