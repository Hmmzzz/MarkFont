#import "FMSettingsViewController.h"

#import "FMCompatibilityViewController.h"
#import "FMDesignSystem.h"
#import "FMProfileWorkspace.h"

typedef NS_ENUM(NSInteger, FMSettingsSection) {
    FMSettingsSectionGeneral,
    FMSettingsSectionAutomation,
    FMSettingsSectionDevice,
    FMSettingsSectionAbout,
};

static UIView *FMSettingsSectionHeaderView(NSString *title) {
    UIView *view = [[UIView alloc] initWithFrame:CGRectZero];
    view.backgroundColor = FMCanvasColor();
    UILabel *label = FMLabel(UIFontTextStyleCaption1, UIFontWeightSemibold,
                             UIColor.secondaryLabelColor);
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = title;
    [view addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:view.leadingAnchor constant:22],
        [label.trailingAnchor constraintEqualToAnchor:view.trailingAnchor constant:-20],
        [label.bottomAnchor constraintEqualToAnchor:view.bottomAnchor constant:-5],
    ]];
    return view;
}

@interface FMSettingsActionCell : UITableViewCell
@property(nonatomic, strong) UIView *card;
@property(nonatomic, strong) UIView *iconBackground;
@property(nonatomic, strong) UIImageView *iconView;
@property(nonatomic, strong) UILabel *titleLabel;
@property(nonatomic, strong) UILabel *subtitleLabel;
@property(nonatomic, strong) UIImageView *chevron;
- (void)configureWithTitle:(NSString *)title
                  subtitle:(NSString *)subtitle
                    symbol:(NSString *)symbol
                     color:(UIColor *)color
                disclosure:(BOOL)disclosure
               destructive:(BOOL)destructive;
@end

@implementation FMSettingsActionCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style
               reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self == nil) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    self.isAccessibilityElement = YES;

    _card = FMCardView();
    _card.translatesAutoresizingMaskIntoConstraints = NO;
    _card.layer.cornerRadius = 19;
    [self.contentView addSubview:_card];

    _iconBackground = [[UIView alloc] initWithFrame:CGRectZero];
    _iconBackground.translatesAutoresizingMaskIntoConstraints = NO;
    _iconBackground.layer.cornerRadius = 14;
    _iconBackground.layer.cornerCurve = kCACornerCurveContinuous;
    [_card addSubview:_iconBackground];

    _iconView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _iconView.translatesAutoresizingMaskIntoConstraints = NO;
    _iconView.contentMode = UIViewContentModeScaleAspectFit;
    [_iconBackground addSubview:_iconView];

    _titleLabel = FMLabel(UIFontTextStyleBody, UIFontWeightSemibold, UIColor.labelColor);
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.numberOfLines = 1;
    [_card addSubview:_titleLabel];

    _subtitleLabel = FMLabel(UIFontTextStyleFootnote, UIFontWeightRegular,
                             UIColor.secondaryLabelColor);
    _subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _subtitleLabel.numberOfLines = 2;
    [_card addSubview:_subtitleLabel];

    _chevron = [[UIImageView alloc]
        initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
    _chevron.translatesAutoresizingMaskIntoConstraints = NO;
    _chevron.tintColor = UIColor.tertiaryLabelColor;
    _chevron.contentMode = UIViewContentModeScaleAspectFit;
    [_card addSubview:_chevron];

    [NSLayoutConstraint activateConstraints:@[
        [_card.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:20],
        [_card.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-20],
        [_card.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:4],
        [_card.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-4],

        [_iconBackground.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:14],
        [_iconBackground.centerYAnchor constraintEqualToAnchor:_card.centerYAnchor],
        [_iconBackground.widthAnchor constraintEqualToConstant:42],
        [_iconBackground.heightAnchor constraintEqualToConstant:42],
        [_iconView.centerXAnchor constraintEqualToAnchor:_iconBackground.centerXAnchor],
        [_iconView.centerYAnchor constraintEqualToAnchor:_iconBackground.centerYAnchor],
        [_iconView.widthAnchor constraintEqualToConstant:21],
        [_iconView.heightAnchor constraintEqualToConstant:21],

        [_titleLabel.leadingAnchor constraintEqualToAnchor:_iconBackground.trailingAnchor
                                                   constant:13],
        [_titleLabel.topAnchor constraintEqualToAnchor:_card.topAnchor constant:13],
        [_titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_chevron.leadingAnchor
                                                               constant:-10],
        [_subtitleLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
        [_subtitleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_chevron.leadingAnchor
                                                                  constant:-10],
        [_subtitleLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:2],
        [_subtitleLabel.bottomAnchor constraintEqualToAnchor:_card.bottomAnchor constant:-12],
        [_card.heightAnchor constraintGreaterThanOrEqualToConstant:68],

        [_chevron.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-16],
        [_chevron.centerYAnchor constraintEqualToAnchor:_card.centerYAnchor],
        [_chevron.widthAnchor constraintEqualToConstant:9],
        [_chevron.heightAnchor constraintEqualToConstant:15],
    ]];
    return self;
}

- (void)configureWithTitle:(NSString *)title
                  subtitle:(NSString *)subtitle
                    symbol:(NSString *)symbol
                     color:(UIColor *)color
                disclosure:(BOOL)disclosure
               destructive:(BOOL)destructive {
    self.titleLabel.text = title;
    self.titleLabel.textColor = destructive ? FMDangerColor() : UIColor.labelColor;
    self.subtitleLabel.text = subtitle;
    self.iconView.image = [UIImage systemImageNamed:symbol];
    self.iconView.tintColor = color;
    self.iconBackground.backgroundColor = FMTintedBackground(color);
    self.chevron.hidden = !disclosure;
    self.accessibilityTraits = disclosure ? UIAccessibilityTraitButton
                                          : UIAccessibilityTraitStaticText;
    self.accessibilityLabel = title;
    self.accessibilityValue = subtitle;
}

- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated {
    [super setHighlighted:highlighted animated:animated];
    NSTimeInterval duration = animated && !UIAccessibilityIsReduceMotionEnabled() ? 0.13 : 0.0;
    [UIView animateWithDuration:duration
                          delay:0
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionCurveEaseOut |
                                UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        self.card.transform = highlighted ? CGAffineTransformMakeScale(0.985, 0.985)
                                          : CGAffineTransformIdentity;
        self.card.alpha = highlighted ? 0.86 : 1.0;
    }
                     completion:nil];
}

@end

@interface FMSettingsToggleCell : FMSettingsActionCell
@property(nonatomic, strong) UISwitch *toggle;
- (void)configureAutomaticRespringEnabled:(BOOL)enabled
                                  loaded:(BOOL)loaded
                                 updating:(BOOL)updating
                                    target:(id)target
                                    action:(SEL)action;
@end

@implementation FMSettingsToggleCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style
               reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self == nil) return nil;
    self.isAccessibilityElement = NO;
    _toggle = [[UISwitch alloc] initWithFrame:CGRectZero];
    _toggle.translatesAutoresizingMaskIntoConstraints = NO;
    _toggle.onTintColor = FMAccentColor();
    _toggle.accessibilityIdentifier = @"settings_auto_respring_switch";
    _toggle.accessibilityLabel = FMLocalized(@"自动 Respring");
    _toggle.accessibilityHint = FMLocalized(@"下次重新越狱后，字体挂载完成得较晚时自动刷新界面");
    [self.card addSubview:_toggle];
    [NSLayoutConstraint activateConstraints:@[
        [_toggle.trailingAnchor constraintEqualToAnchor:self.card.trailingAnchor
                                                constant:-16],
        [_toggle.centerYAnchor constraintEqualToAnchor:self.card.centerYAnchor],
        [self.titleLabel.trailingAnchor
            constraintLessThanOrEqualToAnchor:_toggle.leadingAnchor constant:-12],
        [self.subtitleLabel.trailingAnchor
            constraintLessThanOrEqualToAnchor:_toggle.leadingAnchor constant:-12],
    ]];
    return self;
}

- (void)configureAutomaticRespringEnabled:(BOOL)enabled
                                  loaded:(BOOL)loaded
                                 updating:(BOOL)updating
                                    target:(id)target
                                    action:(SEL)action {
    [self configureWithTitle:FMLocalized(@"自动 Respring")
                    subtitle:FMLocalized(@"下次重新越狱若字体挂载较晚，自动执行一次 Respring")
                      symbol:@"arrow.clockwise.circle.fill"
                       color:FMAccentColor()
                  disclosure:NO
                 destructive:NO];
    self.chevron.hidden = YES;
    [self.toggle removeTarget:nil action:NULL
              forControlEvents:UIControlEventValueChanged];
    [self.toggle setOn:enabled animated:NO];
    self.toggle.enabled = loaded && !updating;
    [self.toggle addTarget:target action:action
            forControlEvents:UIControlEventValueChanged];
    self.toggle.accessibilityValue = enabled ? FMLocalized(@"已开启") : FMLocalized(@"已关闭");
}

@end

@interface FMLanguageSelectionViewController : UITableViewController
@property(nonatomic, copy) NSArray<NSString *> *languagePreferences;
@end

@implementation FMLanguageSelectionViewController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStylePlain];
    if (self != nil) {
        _languagePreferences = @[ @"system", @"zh-Hans", @"en" ];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = FMLocalized(@"语言");
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.tableView.backgroundColor = FMCanvasColor();
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 78;
    self.tableView.sectionHeaderHeight = 18;
    self.tableView.sectionFooterHeight = 8;
    self.tableView.accessibilityIdentifier = @"settings_language_options";
    [self.tableView registerClass:FMSettingsActionCell.class
           forCellReuseIdentifier:@"LanguageOptionCell"];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return self.languagePreferences.count;
}

- (FMSettingsActionCell *)tableView:(UITableView *)tableView
              cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *preference = self.languagePreferences[indexPath.row];
    BOOL selected = [preference isEqualToString:FMLanguagePreference()];
    NSString *subtitle = [preference isEqualToString:@"system"]
        ? FMLocalized(@"跟随设备的语言设置")
        : ([preference isEqualToString:@"zh-Hans"]
            ? FMLocalized(@"始终使用简体中文")
            : FMLocalized(@"始终使用英文"));
    NSString *symbol = [preference isEqualToString:@"system"]
        ? @"globe" : ([preference isEqualToString:@"zh-Hans"]
            ? @"character.book.closed.fill" : @"textformat");
    FMSettingsActionCell *cell =
        [tableView dequeueReusableCellWithIdentifier:@"LanguageOptionCell"
                                        forIndexPath:indexPath];
    [cell configureWithTitle:FMLanguagePreferenceDisplayName(preference)
                    subtitle:subtitle
                      symbol:symbol
                       color:FMAccentColor()
                  disclosure:YES
                 destructive:NO];
    cell.chevron.image = [UIImage systemImageNamed:@"checkmark"];
    cell.chevron.hidden = !selected;
    cell.accessibilityTraits = UIAccessibilityTraitButton |
        (selected ? UIAccessibilityTraitSelected : 0);
    cell.accessibilityHint = selected ? nil : FMLocalized(@"切换到此语言");
    cell.accessibilityIdentifier =
        [@"settings_language_" stringByAppendingString:preference];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
    NSString *preference = self.languagePreferences[indexPath.row];
    if (!FMSetLanguagePreference(preference)) {
        [self.navigationController popViewControllerAnimated:YES];
        return;
    }
    [[[UISelectionFeedbackGenerator alloc] init] selectionChanged];
}

@end

static NSAttributedString *FMSettingsDisclaimerBodyText(
    NSArray<NSString *> *paragraphs) {
    NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
    style.lineSpacing = 4;
    style.paragraphSpacing = 10;
    style.lineBreakMode = NSLineBreakByWordWrapping;
    return [[NSAttributedString alloc]
        initWithString:[paragraphs componentsJoinedByString:@"\n"]
            attributes:@{
                NSFontAttributeName :
                    [UIFont preferredFontForTextStyle:UIFontTextStyleBody],
                NSForegroundColorAttributeName : UIColor.secondaryLabelColor,
                NSParagraphStyleAttributeName : style,
            }];
}

static UIView *FMSettingsDisclaimerHeroView(void) {
    UIView *hero = FMCardView();
    hero.backgroundColor = [FMAccentColor() colorWithAlphaComponent:0.10];
    hero.layer.borderColor =
        [FMAccentColor() colorWithAlphaComponent:0.20].CGColor;

    UIView *iconBackground = [[UIView alloc] initWithFrame:CGRectZero];
    iconBackground.translatesAutoresizingMaskIntoConstraints = NO;
    iconBackground.backgroundColor = FMAccentColor();
    iconBackground.layer.cornerRadius = 16;
    iconBackground.layer.cornerCurve = kCACornerCurveContinuous;

    UIImageView *icon = [[UIImageView alloc]
        initWithImage:[UIImage systemImageNamed:@"hand.raised.fill"]];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.tintColor = UIColor.whiteColor;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    [iconBackground addSubview:icon];

    UILabel *eyebrow = FMLabel(UIFontTextStyleCaption1, UIFontWeightSemibold,
                               FMAccentColor());
    eyebrow.text = FMLocalized(@"使用须知");

    UILabel *title = FMLabel(UIFontTextStyleTitle2, UIFontWeightBold,
                             UIColor.labelColor);
    title.text = FMLocalized(@"请确认字体授权");

    UILabel *subtitle = FMLabel(UIFontTextStyleSubheadline, UIFontWeightRegular,
                                UIColor.secondaryLabelColor);
    subtitle.text = FMLocalized(@"导入字体前，请先了解授权责任与使用风险。");

    UIStackView *labels = [[UIStackView alloc]
        initWithArrangedSubviews:@[ eyebrow, title, subtitle ]];
    labels.axis = UILayoutConstraintAxisVertical;
    labels.alignment = UIStackViewAlignmentFill;
    labels.spacing = 4;

    UIStackView *content = [[UIStackView alloc]
        initWithArrangedSubviews:@[ iconBackground, labels ]];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    content.axis = UILayoutConstraintAxisHorizontal;
    content.alignment = UIStackViewAlignmentTop;
    content.spacing = 14;
    [hero addSubview:content];

    [NSLayoutConstraint activateConstraints:@[
        [iconBackground.widthAnchor constraintEqualToConstant:48],
        [iconBackground.heightAnchor constraintEqualToConstant:48],
        [icon.centerXAnchor constraintEqualToAnchor:iconBackground.centerXAnchor],
        [icon.centerYAnchor constraintEqualToAnchor:iconBackground.centerYAnchor],
        [icon.widthAnchor constraintEqualToConstant:22],
        [icon.heightAnchor constraintEqualToConstant:22],
        [content.leadingAnchor constraintEqualToAnchor:hero.leadingAnchor constant:20],
        [content.trailingAnchor constraintEqualToAnchor:hero.trailingAnchor constant:-20],
        [content.topAnchor constraintEqualToAnchor:hero.topAnchor constant:20],
        [content.bottomAnchor constraintEqualToAnchor:hero.bottomAnchor constant:-20],
    ]];
    return hero;
}

static UIView *FMSettingsDisclaimerSectionView(
    NSString *title,
    NSString *symbol,
    NSArray<NSString *> *paragraphs) {
    UIView *card = FMCardView();

    UIView *iconBackground = [[UIView alloc] initWithFrame:CGRectZero];
    iconBackground.translatesAutoresizingMaskIntoConstraints = NO;
    iconBackground.backgroundColor = FMTintedBackground(FMAccentColor());
    iconBackground.layer.cornerRadius = 11;
    iconBackground.layer.cornerCurve = kCACornerCurveContinuous;

    UIImageView *icon = [[UIImageView alloc]
        initWithImage:[UIImage systemImageNamed:symbol]];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.tintColor = FMAccentColor();
    icon.contentMode = UIViewContentModeScaleAspectFit;
    [iconBackground addSubview:icon];

    UILabel *heading = FMLabel(UIFontTextStyleHeadline, UIFontWeightSemibold,
                               UIColor.labelColor);
    heading.text = title;

    UIStackView *header = [[UIStackView alloc]
        initWithArrangedSubviews:@[ iconBackground, heading ]];
    header.axis = UILayoutConstraintAxisHorizontal;
    header.alignment = UIStackViewAlignmentCenter;
    header.spacing = 11;

    UIView *separator = [[UIView alloc] initWithFrame:CGRectZero];
    separator.backgroundColor = FMHairlineColor();

    UILabel *body = FMLabel(UIFontTextStyleBody, UIFontWeightRegular,
                            UIColor.secondaryLabelColor);
    body.attributedText = FMSettingsDisclaimerBodyText(paragraphs);

    UIStackView *content = [[UIStackView alloc]
        initWithArrangedSubviews:@[ header, separator, body ]];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    content.axis = UILayoutConstraintAxisVertical;
    content.alignment = UIStackViewAlignmentFill;
    content.spacing = 14;
    [card addSubview:content];

    [NSLayoutConstraint activateConstraints:@[
        [iconBackground.widthAnchor constraintEqualToConstant:36],
        [iconBackground.heightAnchor constraintEqualToConstant:36],
        [icon.centerXAnchor constraintEqualToAnchor:iconBackground.centerXAnchor],
        [icon.centerYAnchor constraintEqualToAnchor:iconBackground.centerYAnchor],
        [icon.widthAnchor constraintEqualToConstant:17],
        [icon.heightAnchor constraintEqualToConstant:17],
        [separator.heightAnchor constraintEqualToConstant:
            1.0 / UIScreen.mainScreen.scale],
        [content.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20],
        [content.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20],
        [content.topAnchor constraintEqualToAnchor:card.topAnchor constant:18],
        [content.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-20],
    ]];
    return card;
}

static UIView *FMSettingsDisclaimerReminderView(void) {
    UIView *view = [[UIView alloc] initWithFrame:CGRectZero];
    view.backgroundColor = [FMSuccessColor() colorWithAlphaComponent:0.10];
    view.layer.cornerRadius = 16;
    view.layer.cornerCurve = kCACornerCurveContinuous;

    UIImageView *icon = [[UIImageView alloc]
        initWithImage:[UIImage systemImageNamed:@"checkmark.shield.fill"]];
    icon.tintColor = FMSuccessColor();
    icon.contentMode = UIViewContentModeScaleAspectFit;

    UILabel *label = FMLabel(UIFontTextStyleFootnote, UIFontWeightSemibold,
                             UIColor.secondaryLabelColor);
    label.text = FMLocalized(@"请仅导入和使用已获得必要授权的字体");

    UIStackView *content = [[UIStackView alloc]
        initWithArrangedSubviews:@[ icon, label ]];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    content.axis = UILayoutConstraintAxisHorizontal;
    content.alignment = UIStackViewAlignmentCenter;
    content.spacing = 10;
    [view addSubview:content];

    [NSLayoutConstraint activateConstraints:@[
        [icon.widthAnchor constraintEqualToConstant:20],
        [icon.heightAnchor constraintEqualToConstant:20],
        [content.leadingAnchor constraintEqualToAnchor:view.leadingAnchor constant:16],
        [content.trailingAnchor constraintEqualToAnchor:view.trailingAnchor constant:-16],
        [content.topAnchor constraintEqualToAnchor:view.topAnchor constant:14],
        [content.bottomAnchor constraintEqualToAnchor:view.bottomAnchor constant:-14],
    ]];
    return view;
}

@interface FMSettingsDisclaimerViewController : UIViewController
@end

@implementation FMSettingsDisclaimerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = FMLocalized(@"免责声明");
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.view.backgroundColor = FMCanvasColor();

    UIScrollView *scrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.alwaysBounceVertical = YES;
    scrollView.accessibilityIdentifier = @"settings_disclaimer_page";
    [self.view addSubview:scrollView];

    UIView *fontRights = FMSettingsDisclaimerSectionView(
        FMLocalized(@"字体来源与授权"), @"textformat",
        @[
            FMLocalized(@"MarkFont 仅提供字体管理功能，不提供、销售、授权或分发任何第三方字体文件。"),
            FMLocalized(@"字体文件、字形设计、字体名称及相关内容可能受到版权、商标、字体许可或其他权利保护。"),
            FMLocalized(@"用户在导入、安装、使用、复制或分发任何字体前，应自行确认已取得必要授权，并遵守字体许可与适用法律。"),
        ]);
    UIView *responsibility = FMSettingsDisclaimerSectionView(
        FMLocalized(@"责任与风险"), @"shield.lefthalf.filled",
        @[
            FMLocalized(@"用户导入的字体由用户自行选择和获取，项目维护者与贡献者不审核其来源或授权状态。"),
            FMLocalized(@"在适用法律允许的最大范围内，项目维护者与贡献者不对用户未经授权或违法使用字体所引起的侵权主张、损失或其他责任负责，也不对字体兼容性或不当操作造成的设备异常、数据丢失或系统不稳定负责。"),
        ]);

    UIStackView *content = [[UIStackView alloc]
        initWithArrangedSubviews:@[
            FMSettingsDisclaimerHeroView(),
            fontRights,
            responsibility,
            FMSettingsDisclaimerReminderView(),
        ]];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    content.axis = UILayoutConstraintAxisVertical;
    content.alignment = UIStackViewAlignmentFill;
    content.spacing = 14;
    [scrollView addSubview:content];

    [NSLayoutConstraint activateConstraints:@[
        [scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scrollView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [content.leadingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.leadingAnchor
                                              constant:16],
        [content.trailingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.trailingAnchor
                                               constant:-16],
        [content.topAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.topAnchor
                                          constant:16],
        [content.bottomAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.bottomAnchor
                                             constant:-28],
        [content.widthAnchor constraintEqualToAnchor:scrollView.frameLayoutGuide.widthAnchor
                                            constant:-32],
    ]];
}

@end

@interface FMSettingsCreditsViewController : UITableViewController
@property(nonatomic, copy) NSArray<NSDictionary<NSString *, NSString *> *> *credits;
@end

@implementation FMSettingsCreditsViewController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStylePlain];
    if (self != nil) {
        _credits = @[
            @{
                @"title" : @"RootHide",
                @"subtitle" : FMLocalized(@"提供 RootHide 架构与兼容基础"),
                @"symbol" : @"shield.lefthalf.filled",
                @"url" : @"https://github.com/roothide/Developer",
            },
            @{
                @"title" : @"Theos",
                @"subtitle" : FMLocalized(@"提供 iOS 越狱开发与打包工具链"),
                @"symbol" : @"hammer.fill",
                @"url" : @"https://theos.dev/",
            },
            @{
                @"title" : @"Dopamine / libjailbreak",
                @"subtitle" : FMLocalized(@"提供挂载能力接口设计参考"),
                @"symbol" : @"arrow.triangle.2.circlepath",
                @"url" : @"https://github.com/opa334/Dopamine",
            },
            @{
                @"title" : @"Relaxin",
                @"subtitle" : FMLocalized(@"提供本项目当前适配与测试的越狱环境"),
                @"symbol" : @"sparkles",
                @"url" : @"https://relaxin.owngoal.dev/",
            },
        ];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = FMLocalized(@"致谢");
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.tableView.backgroundColor = FMCanvasColor();
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 78;
    self.tableView.sectionHeaderHeight = 34;
    self.tableView.sectionHeaderTopPadding = 0;
    self.tableView.sectionFooterHeight = 8;
    self.tableView.contentInset = UIEdgeInsetsZero;
    self.tableView.accessibilityIdentifier = @"settings_credits";
    [self.tableView registerClass:FMSettingsActionCell.class
           forCellReuseIdentifier:@"SettingsCreditCell"];

    UIView *footer = [[UIView alloc]
        initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 88)];
    UILabel *label = FMLabel(UIFontTextStyleCaption1, UIFontWeightMedium,
                             UIColor.tertiaryLabelColor);
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = FMLocalized(@"感谢这些项目及其贡献者\n让 MarkFont 得以构建与运行");
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 0;
    [footer addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:footer.leadingAnchor constant:24],
        [label.trailingAnchor constraintEqualToAnchor:footer.trailingAnchor constant:-24],
        [label.topAnchor constraintEqualToAnchor:footer.topAnchor constant:14],
    ]];
    self.tableView.tableFooterView = footer;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return self.credits.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return FMLocalized(@"特别感谢");
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    return FMSettingsSectionHeaderView(
        [self tableView:tableView titleForHeaderInSection:section]);
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return 34;
}

- (FMSettingsActionCell *)tableView:(UITableView *)tableView
              cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    FMSettingsActionCell *cell =
        [tableView dequeueReusableCellWithIdentifier:@"SettingsCreditCell"
                                        forIndexPath:indexPath];
    NSDictionary<NSString *, NSString *> *credit = self.credits[indexPath.row];
    [cell configureWithTitle:credit[@"title"]
                    subtitle:credit[@"subtitle"]
                      symbol:credit[@"symbol"]
                       color:FMAccentColor()
                  disclosure:YES
                 destructive:NO];
    cell.chevron.image = [UIImage systemImageNamed:@"arrow.up.right"];
    cell.accessibilityTraits = UIAccessibilityTraitLink;
    cell.accessibilityHint = FMLocalized(@"打开项目链接");
    cell.accessibilityIdentifier =
        [@"settings_credit_" stringByAppendingString:credit[@"title"].lowercaseString];
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView shouldHighlightRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    (void)indexPath;
    return YES;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
    NSString *address = self.credits[indexPath.row][@"url"];
    NSURL *url = [NSURL URLWithString:address];
    if (url == nil) return;
    [[[UISelectionFeedbackGenerator alloc] init] selectionChanged];
    [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
}

@end

@interface FMSettingsViewController ()
@property(nonatomic, strong) id<FMProfileWorkspace> workspace;
@property(nonatomic, copy) dispatch_block_t dismissalHandler;
@property(nonatomic) BOOL automaticRespringEnabled;
@property(nonatomic) BOOL automaticRespringPolicyLoaded;
@property(nonatomic) BOOL automaticRespringUpdateInFlight;
- (void)refreshAutomaticRespringCellIfVisible;
@end

@implementation FMSettingsViewController

- (instancetype)initWithWorkspace:(id<FMProfileWorkspace>)workspace
                  dismissalHandler:(dispatch_block_t)dismissalHandler {
    self = [super initWithStyle:UITableViewStylePlain];
    if (self != nil) {
        _workspace = workspace;
        _dismissalHandler = [dismissalHandler copy];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = FMLocalized(@"设置");
    self.navigationItem.backButtonDisplayMode = UINavigationItemBackButtonDisplayModeMinimal;
    self.navigationController.navigationBar.prefersLargeTitles = NO;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    UIBarButtonItem *close =
        [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"xmark"]
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(closeSettings:)];
    close.accessibilityLabel = FMLocalized(@"关闭设置");
    close.tintColor = FMAccentColor();
    self.navigationItem.rightBarButtonItem = close;

    self.tableView.backgroundColor = FMCanvasColor();
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 78;
    self.tableView.sectionHeaderHeight = 34;
    self.tableView.sectionHeaderTopPadding = 0;
    self.tableView.sectionFooterHeight = 8;
    self.tableView.contentInset = UIEdgeInsetsZero;
    self.tableView.accessibilityIdentifier = @"settings";
    [self.tableView registerClass:FMSettingsActionCell.class
           forCellReuseIdentifier:@"SettingsActionCell"];
    [self.tableView registerClass:FMSettingsToggleCell.class
           forCellReuseIdentifier:@"SettingsToggleCell"];
    self.tableView.tableFooterView = [self makeAboutFooter];
    [self reloadAutomaticRespringPolicy];
}

- (void)refreshAutomaticRespringCellIfVisible {
    NSIndexPath *indexPath =
        [NSIndexPath indexPathForRow:0 inSection:FMSettingsSectionAutomation];
    FMSettingsToggleCell *cell = (FMSettingsToggleCell *)
        [self.tableView cellForRowAtIndexPath:indexPath];
    if (![cell isKindOfClass:FMSettingsToggleCell.class]) return;
    [cell configureAutomaticRespringEnabled:self.automaticRespringEnabled
                                     loaded:self.automaticRespringPolicyLoaded
                                   updating:self.automaticRespringUpdateInFlight
                                      target:self
                                      action:@selector(automaticRespringSwitchChanged:)];
}

- (void)reloadAutomaticRespringPolicy {
    id<FMProfileWorkspace> workspace = self.workspace;
    if (![workspace respondsToSelector:@selector(setAutomaticRespringEnabled:error:)]) {
        self.automaticRespringEnabled = NO;
        self.automaticRespringPolicyLoaded = NO;
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSDictionary<NSString *, id> *state = nil;
        if ([workspace respondsToSelector:@selector(environmentStatus:)]) {
            NSDictionary<NSString *, id> *status =
                [workspace environmentStatus:&error];
            state = [status[@"state"] isKindOfClass:NSDictionary.class]
                ? status[@"state"] : nil;
            if (![state[@"present"] boolValue] ||
                ![state[@"valid"] boolValue]) {
                state = nil;
            }
        } else if ([workspace prepareIfNeeded:&error]) {
            state = [workspace currentState:&error];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (state != nil) {
                self.automaticRespringEnabled =
                    [state[@"autoRespring"] boolValue];
                self.automaticRespringPolicyLoaded = YES;
            }
            [self refreshAutomaticRespringCellIfVisible];
        });
    });
}

- (void)automaticRespringSwitchChanged:(UISwitch *)sender {
    if (!self.automaticRespringPolicyLoaded ||
        self.automaticRespringUpdateInFlight ||
        ![self.workspace respondsToSelector:
            @selector(setAutomaticRespringEnabled:error:)]) {
        [sender setOn:self.automaticRespringEnabled animated:YES];
        return;
    }

    BOOL requestedEnabled = sender.isOn;
    self.automaticRespringUpdateInFlight = YES;
    sender.enabled = NO;
    id<FMProfileWorkspace> workspace = self.workspace;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        BOOL saved = [workspace setAutomaticRespringEnabled:requestedEnabled
                                                      error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.automaticRespringUpdateInFlight = NO;
            if (saved) {
                self.automaticRespringEnabled = requestedEnabled;
                [[[UISelectionFeedbackGenerator alloc] init] selectionChanged];
            } else {
                [sender setOn:self.automaticRespringEnabled animated:YES];
                UIAlertController *alert = [UIAlertController
                    alertControllerWithTitle:FMLocalized(@"设置没有保存")
                                     message:error.localizedDescription ?:
                                         FMLocalized(@"请稍后重试。")
                              preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:FMLocalized(@"好")
                                                          style:UIAlertActionStyleDefault
                                                        handler:nil]];
                [self presentViewController:alert animated:YES completion:nil];
            }
            sender.enabled = self.automaticRespringPolicyLoaded;
            sender.accessibilityValue = self.automaticRespringEnabled
                ? FMLocalized(@"已开启") : FMLocalized(@"已关闭");
        });
    });
}

- (UIView *)makeAboutFooter {
    UIView *footer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 82)];
    UILabel *label = FMLabel(UIFontTextStyleCaption1, UIFontWeightMedium,
                             UIColor.tertiaryLabelColor);
    label.translatesAutoresizingMaskIntoConstraints = NO;
    NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    if (version.length == 0) version = @"0.3.6";
    label.text = [NSString stringWithFormat:FMLocalized(@"MarkFont · 版本 %@\n由 Hmmzzz 设计与开发"),
                                            version];
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 0;
    [footer addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:footer.leadingAnchor constant:24],
        [label.trailingAnchor constraintEqualToAnchor:footer.trailingAnchor constant:-24],
        [label.topAnchor constraintEqualToAnchor:footer.topAnchor constant:14],
    ]];
    return footer;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return 4;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    return section == FMSettingsSectionAbout ? 3 : 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    return @[ FMLocalized(@"通用"), FMLocalized(@"自动化"),
              FMLocalized(@"设备"), FMLocalized(@"关于") ][section];
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    return FMSettingsSectionHeaderView(
        [self tableView:tableView titleForHeaderInSection:section]);
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return 34;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == FMSettingsSectionAutomation) {
        FMSettingsToggleCell *cell =
            [tableView dequeueReusableCellWithIdentifier:@"SettingsToggleCell"
                                            forIndexPath:indexPath];
        [cell configureAutomaticRespringEnabled:self.automaticRespringEnabled
                                         loaded:self.automaticRespringPolicyLoaded
                                        updating:self.automaticRespringUpdateInFlight
                                           target:self
                                           action:@selector(automaticRespringSwitchChanged:)];
        cell.accessibilityIdentifier = @"settings_auto_respring";
        return cell;
    }

    FMSettingsActionCell *cell =
        [tableView dequeueReusableCellWithIdentifier:@"SettingsActionCell"
                                        forIndexPath:indexPath];
    cell.chevron.image = [UIImage systemImageNamed:@"chevron.right"];
    cell.accessibilityHint = nil;
    if (indexPath.section == FMSettingsSectionGeneral) {
        [cell configureWithTitle:FMLocalized(@"语言")
                        subtitle:FMLanguagePreferenceDisplayName(FMLanguagePreference())
                          symbol:@"globe"
                           color:FMAccentColor()
                      disclosure:YES
                     destructive:NO];
        cell.accessibilityHint = FMLocalized(@"选择 App 的显示语言");
        cell.accessibilityIdentifier = @"settings_language";
    } else if (indexPath.section == FMSettingsSectionDevice) {
        [cell configureWithTitle:FMLocalized(@"运行环境")
                        subtitle:FMLocalized(@"查看组件、字体连接与恢复准备")
                          symbol:@"checkmark.shield.fill"
                           color:FMAccentColor()
                      disclosure:YES
                     destructive:NO];
        cell.accessibilityIdentifier = @"settings_environment";
    } else if (indexPath.row == 0) {
        [cell configureWithTitle:FMLocalized(@"作者")
                        subtitle:@"Hmmzzz"
                          symbol:@"person.crop.circle.fill"
                           color:FMAccentColor()
                      disclosure:NO
                     destructive:NO];
        cell.accessibilityIdentifier = @"settings_author";
    } else if (indexPath.row == 1) {
        [cell configureWithTitle:FMLocalized(@"免责声明")
                        subtitle:FMLocalized(@"字体授权、使用责任与风险说明")
                          symbol:@"hand.raised.fill"
                           color:FMAccentColor()
                      disclosure:YES
                     destructive:NO];
        cell.accessibilityHint = FMLocalized(@"查看免责声明");
        cell.accessibilityIdentifier = @"settings_disclaimer";
    } else {
        [cell configureWithTitle:FMLocalized(@"致谢")
                        subtitle:FMLocalized(@"感谢开源项目与社区贡献者")
                          symbol:@"heart.fill"
                           color:FMAccentColor()
                      disclosure:YES
                     destructive:NO];
        cell.accessibilityIdentifier = @"settings_acknowledgements";
    }
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView shouldHighlightRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    return indexPath.section == FMSettingsSectionGeneral ||
        indexPath.section == FMSettingsSectionDevice ||
        (indexPath.section == FMSettingsSectionAbout && indexPath.row != 0);
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
    if (indexPath.section == FMSettingsSectionAutomation) return;
    if (indexPath.section == FMSettingsSectionGeneral) {
        [[[UISelectionFeedbackGenerator alloc] init] selectionChanged];
        FMLanguageSelectionViewController *languages =
            [[FMLanguageSelectionViewController alloc] init];
        [self.navigationController pushViewController:languages animated:YES];
        return;
    }
    if (indexPath.section == FMSettingsSectionAbout) {
        if (indexPath.row == 1) {
            [[[UISelectionFeedbackGenerator alloc] init] selectionChanged];
            FMSettingsDisclaimerViewController *disclaimer =
                [[FMSettingsDisclaimerViewController alloc] init];
            [self.navigationController pushViewController:disclaimer animated:YES];
        } else if (indexPath.row == 2) {
            [[[UISelectionFeedbackGenerator alloc] init] selectionChanged];
            FMSettingsCreditsViewController *credits = [[FMSettingsCreditsViewController alloc] init];
            [self.navigationController pushViewController:credits animated:YES];
        }
        return;
    }
    [[[UISelectionFeedbackGenerator alloc] init] selectionChanged];
    id<FMProfileWorkspace> workspace = self.workspace;
    FMCompatibilityStatusLoader loader = ^(FMCompatibilityLoadCompletion completion) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSError *error = nil;
            NSDictionary *status = nil;
            if ([workspace respondsToSelector:@selector(environmentStatus:)]) {
                status = [workspace environmentStatus:&error];
            } else {
                error = [NSError errorWithDomain:@"com.hmmzzz.fontmanager.environment-ui"
                                             code:1
                                         userInfo:@{
                    NSLocalizedDescriptionKey : FMLocalized(@"当前版本无法读取运行环境。")
                }];
            }
            completion(status, error);
        });
    };
    FMCompatibilityViewController *environment =
        [[FMCompatibilityViewController alloc] initWithEnvironmentStatus:nil
                                                              statusLoader:loader];
    [self.navigationController pushViewController:environment animated:YES];
}

- (void)closeSettings:(id)sender {
    (void)sender;
    if (self.dismissalHandler != nil) self.dismissalHandler();
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end
