#import "FMFontLibraryViewController.h"

// UI only; filesystem behavior is supplied by FMProfileWorkspace.

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "FMDesignSystem.h"
#import "FMFloatingActionDockView.h"
#import "FMFontPackageImportSession.h"
#import "FMProfileWorkspace.h"
#import "FMSystemFontLayout.h"

static NSString *_Nullable FMLibraryNormalizedProfileID(id value) {
    return value == nil || value == NSNull.null ? nil : [value description];
}

static BOOL FMLibraryProfileIDsEqual(NSString *_Nullable left, NSString *_Nullable right) {
    return left == right || [left isEqual:right];
}

static NSString *FMLibraryCompactPackagePath(NSString *path) {
    if (![path isKindOfClass:NSString.class]) return @"";
    NSArray<NSString *> *components = path.pathComponents;
    if (components.count <= 2) return path;
    return [NSString pathWithComponents:
        [components subarrayWithRange:NSMakeRange(components.count - 2, 2)]];
}

static BOOL FMLibraryShouldShowIOS18To26ChineseImportTip(void) {
    return FMCurrentSystemFontLayout(nil, nil) ==
        FMSystemFontLayoutFontServicesCorePrivate;
}

static UIImage *FMCircularDeleteActionImage(UITraitCollection *traits) {
    CGSize size = CGSizeMake(44, 44);
    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:size];
    UIImage *image = [renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *context) {
        UIColor *danger = [FMDangerColor() resolvedColorWithTraitCollection:traits];
        [danger setFill];
        [[UIBezierPath bezierPathWithOvalInRect:CGRectInset((CGRect){ CGPointZero, size }, 2, 2)]
            fill];

        UIImageSymbolConfiguration *symbolConfiguration =
            [UIImageSymbolConfiguration configurationWithPointSize:18
                                                            weight:UIImageSymbolWeightSemibold];
        UIImage *trash = [[UIImage systemImageNamed:@"trash.fill"
                                  withConfiguration:symbolConfiguration]
            imageWithTintColor:UIColor.whiteColor
                 renderingMode:UIImageRenderingModeAlwaysOriginal];
        CGPoint origin = CGPointMake((size.width - trash.size.width) / 2.0,
                                     (size.height - trash.size.height) / 2.0);
        [trash drawAtPoint:origin];
    }];
    image = [image imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    image.accessibilityLabel = FMLocalized(@"删除");
    return image;
}

@interface FMFontLibraryCell : UITableViewCell
@property(nonatomic, strong) UIView *card;
@property(nonatomic, strong) UIView *swatch;
@property(nonatomic, strong) UILabel *glyphLabel;
@property(nonatomic, strong) UILabel *nameLabel;
@property(nonatomic, strong) UILabel *detailLabel;
@property(nonatomic, strong) UILabel *statusLabel;
- (void)configureWithProfileID:(nullable NSString *)profileID
                          name:(NSString *)name
                   previewFont:(nullable UIFont *)previewFont
                        status:(nullable NSString *)status;
@end

@implementation FMFontLibraryCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self == nil) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.selectionStyle = UITableViewCellSelectionStyleNone;

    _card = FMCardView();
    _card.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:_card];

    _swatch = [[UIView alloc] initWithFrame:CGRectZero];
    _swatch.translatesAutoresizingMaskIntoConstraints = NO;
    _swatch.layer.cornerRadius = 18;
    _swatch.layer.cornerCurve = kCACornerCurveContinuous;
    [_card addSubview:_swatch];

    _glyphLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _glyphLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _glyphLabel.text = @"Aa";
    _glyphLabel.textAlignment = NSTextAlignmentCenter;
    [_swatch addSubview:_glyphLabel];

    _nameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _nameLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
    _nameLabel.textColor = UIColor.labelColor;
    _nameLabel.adjustsFontSizeToFitWidth = YES;
    _nameLabel.minimumScaleFactor = 0.72;
    [_card addSubview:_nameLabel];

    _detailLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _detailLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightRegular];
    _detailLabel.textColor = UIColor.secondaryLabelColor;
    _detailLabel.numberOfLines = 2;
    [_card addSubview:_detailLabel];

    _statusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _statusLabel.font = [UIFont systemFontOfSize:10.5 weight:UIFontWeightSemibold];
    _statusLabel.textAlignment = NSTextAlignmentCenter;
    _statusLabel.layer.cornerRadius = 10;
    _statusLabel.layer.cornerCurve = kCACornerCurveContinuous;
    _statusLabel.layer.masksToBounds = YES;
    [_card addSubview:_statusLabel];

    UIImageView *chevron = [[UIImageView alloc]
        initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
    chevron.translatesAutoresizingMaskIntoConstraints = NO;
    chevron.tintColor = UIColor.tertiaryLabelColor;
    chevron.contentMode = UIViewContentModeScaleAspectFit;
    [_card addSubview:chevron];

    [NSLayoutConstraint activateConstraints:@[
        [_card.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:20],
        [_card.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-20],
        [_card.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:5],
        [_card.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-5],

        [_swatch.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:13],
        [_swatch.centerYAnchor constraintEqualToAnchor:_card.centerYAnchor],
        [_swatch.widthAnchor constraintEqualToConstant:68],
        [_swatch.heightAnchor constraintEqualToConstant:68],
        [_glyphLabel.centerXAnchor constraintEqualToAnchor:_swatch.centerXAnchor],
        [_glyphLabel.centerYAnchor constraintEqualToAnchor:_swatch.centerYAnchor],

        [_nameLabel.leadingAnchor constraintEqualToAnchor:_swatch.trailingAnchor constant:14],
        [_nameLabel.topAnchor constraintEqualToAnchor:_card.topAnchor constant:17],
        [_nameLabel.trailingAnchor constraintLessThanOrEqualToAnchor:chevron.leadingAnchor constant:-8],
        [_detailLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
        [_detailLabel.trailingAnchor constraintLessThanOrEqualToAnchor:chevron.leadingAnchor constant:-8],
        [_detailLabel.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor constant:3],
        [_statusLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
        [_statusLabel.topAnchor constraintEqualToAnchor:_detailLabel.bottomAnchor constant:5],
        [_statusLabel.heightAnchor constraintEqualToConstant:20],
        [_statusLabel.widthAnchor constraintGreaterThanOrEqualToConstant:50],
        [_statusLabel.bottomAnchor constraintLessThanOrEqualToAnchor:_card.bottomAnchor constant:-11],

        [chevron.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-15],
        [chevron.centerYAnchor constraintEqualToAnchor:_card.centerYAnchor],
        [chevron.widthAnchor constraintEqualToConstant:10],
        [chevron.heightAnchor constraintEqualToConstant:18],
    ]];
    return self;
}

- (void)configureWithProfileID:(NSString *)profileID
                          name:(NSString *)name
                   previewFont:(UIFont *)previewFont
                        status:(NSString *)status {
    self.nameLabel.text = name;
    self.detailLabel.text = FMProfileDescription(profileID);
    self.glyphLabel.font = previewFont != nil
        ? [previewFont fontWithSize:31]
        : FMRepresentativeFont(profileID, 31, UIFontWeightBold);
    self.glyphLabel.textColor = FMProfileInkColor(profileID, self.traitCollection);
    NSArray<UIColor *> *colors = FMProfileGradientColors(profileID, self.traitCollection);
    self.swatch.backgroundColor = colors.firstObject;
    self.statusLabel.hidden = status.length == 0;
    self.statusLabel.text = status;
    BOOL pending = [status isEqual:FMLocalized(@"等待 Respring")];
    UIColor *statusColor = pending ? FMWarnColor() : FMSuccessColor();
    self.statusLabel.textColor = statusColor;
    self.statusLabel.backgroundColor = FMTintedBackground(statusColor);
    self.accessibilityLabel = name;
    self.accessibilityValue = status.length > 0 ? status : FMLocalized(@"轻点查看方案详情");
    self.isAccessibilityElement = YES;
    self.accessibilityTraits = UIAccessibilityTraitButton;
}

@end

static NSString *FMFriendlyMirrorRole(NSString *relativePath) {
    if ([relativePath isEqual:@"Core/A.ttf"]) return FMLocalized(@"常规文字");
    if ([relativePath isEqual:@"Core/B.ttf"]) return FMLocalized(@"粗体与强调");
    if ([relativePath isEqual:@"LanguageSupport/C.ttc"]) return FMLocalized(@"多语言文字");
    return FMLocalized(@"字体文件");
}

@interface FMFontSchemeDetailViewController : UITableViewController
@property(nonatomic, strong) id<FMProfileWorkspace> workspace;
@property(nonatomic, copy) NSDictionary<NSString *, id> *profile;
@property(nonatomic, copy, nullable) NSDictionary<NSString *, id> *details;
@property(nonatomic, copy, nullable) NSString *loadError;
@property(nonatomic, copy, nullable) NSString *status;
@property(nonatomic, copy) FMFontLibraryApplyHandler applyHandler;
@property(nonatomic, strong) FMFloatingActionDockView *actionDock;
@property(nonatomic, strong) UIButton *applyButton;
- (instancetype)initWithWorkspace:(id<FMProfileWorkspace>)workspace
                           profile:(NSDictionary<NSString *, id> *)profile
                            status:(nullable NSString *)status
                      applyHandler:(FMFontLibraryApplyHandler)applyHandler;
@end

@implementation FMFontSchemeDetailViewController

- (instancetype)initWithWorkspace:(id<FMProfileWorkspace>)workspace
                           profile:(NSDictionary<NSString *, id> *)profile
                            status:(NSString *)status
                      applyHandler:(FMFontLibraryApplyHandler)applyHandler {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self != nil) {
        _workspace = workspace;
        _profile = [profile copy];
        _status = [status copy];
        _applyHandler = [applyHandler copy];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    NSString *profileID = FMLibraryNormalizedProfileID(self.profile[@"id"]);
    NSString *name = FMFriendlyProfileName(profileID, self.profile[@"name"]);
    self.title = name;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.tableView.backgroundColor = FMCanvasColor();
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 64;
    self.tableView.accessibilityIdentifier = @"font_scheme_details";
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"FileCell"];

    NSError *error = nil;
    self.details = [self.workspace detailsForProfileID:profileID error:&error];
    self.loadError = error.localizedDescription;
    self.tableView.tableHeaderView = [self makeSpecimenHeader];
    [self installFloatingActionDock];
}

- (UIView *)makeSpecimenHeader {
    NSString *profileID = FMLibraryNormalizedProfileID(self.profile[@"id"]);
    NSString *name = FMFriendlyProfileName(profileID, self.profile[@"name"]);
    NSString *previewFontPath = [self.details[@"previewFontPath"] isKindOfClass:NSString.class]
                                    ? self.details[@"previewFontPath"]
                                    : nil;
    NSString *previewLatinFontPath =
        [self.details[@"previewLatinFontPath"] isKindOfClass:NSString.class]
            ? self.details[@"previewLatinFontPath"]
            : previewFontPath;
    UIFont *previewFont = FMPreviewFontAtPath(previewFontPath, 34);
    UIFont *previewLatinFont = FMPreviewFontAtPath(previewLatinFontPath, 19);
    UIFont *specimenFont = previewFont ?: FMRepresentativeFont(profileID, 34, UIFontWeightBold);
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 260)];
    UIView *card = [[UIView alloc] initWithFrame:CGRectZero];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = FMProfileGradientColors(profileID, self.traitCollection).firstObject;
    card.layer.cornerRadius = 25;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    [header addSubview:card];

    UILabel *eyebrow = [[UILabel alloc] initWithFrame:CGRectZero];
    eyebrow.translatesAutoresizingMaskIntoConstraints = NO;
    eyebrow.text = FMLocalized(@"字体样张");
    eyebrow.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    eyebrow.textColor = [FMProfileInkColor(profileID, self.traitCollection)
        colorWithAlphaComponent:0.62];
    [card addSubview:eyebrow];

    UILabel *specimen = [[UILabel alloc] initWithFrame:CGRectZero];
    specimen.translatesAutoresizingMaskIntoConstraints = NO;
    specimen.text = FMLocalized(@"春风有信，花开有期。");
    specimen.font = specimenFont;
    specimen.textColor = FMProfileInkColor(profileID, self.traitCollection);
    specimen.adjustsFontSizeToFitWidth = YES;
    specimen.minimumScaleFactor = 0.72;
    specimen.accessibilityIdentifier = @"scheme_specimen_sample";
    specimen.accessibilityLabel = [NSString stringWithFormat:FMLocalized(@"字体样张：%@"), specimen.text];
    specimen.accessibilityHint = previewFont != nil ? FMLocalized(@"使用导入的字体显示") : FMLocalized(@"方案样张预览");
    [card addSubview:specimen];

    UILabel *latin = [[UILabel alloc] initWithFrame:CGRectZero];
    latin.translatesAutoresizingMaskIntoConstraints = NO;
    latin.text = @"Aa 0123456789 · The quick brown fox";
    latin.font = previewLatinFont ?: FMRepresentativeFont(profileID, 19,
                                                           UIFontWeightSemibold);
    latin.textColor = [FMProfileInkColor(profileID, self.traitCollection)
        colorWithAlphaComponent:0.74];
    latin.adjustsFontSizeToFitWidth = YES;
    latin.minimumScaleFactor = 0.72;
    latin.accessibilityIdentifier = @"scheme_specimen_latin";
    [card addSubview:latin];

    UIView *divider = [[UIView alloc] initWithFrame:CGRectZero];
    divider.translatesAutoresizingMaskIntoConstraints = NO;
    divider.backgroundColor = [FMProfileInkColor(profileID, self.traitCollection)
        colorWithAlphaComponent:0.12];
    [card addSubview:divider];

    UILabel *nameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    nameLabel.text = name;
    nameLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
    nameLabel.textColor = FMProfileInkColor(profileID, self.traitCollection);
    [card addSubview:nameLabel];

    UILabel *description = [[UILabel alloc] initWithFrame:CGRectZero];
    description.translatesAutoresizingMaskIntoConstraints = NO;
    description.text = FMProfileDescription(profileID);
    description.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightMedium];
    description.textColor = [FMProfileInkColor(profileID, self.traitCollection)
        colorWithAlphaComponent:0.68];
    description.numberOfLines = 2;
    [card addSubview:description];

    UILabel *status = [[UILabel alloc] initWithFrame:CGRectZero];
    status.translatesAutoresizingMaskIntoConstraints = NO;
    status.text = self.status.length > 0 ? self.status : FMLocalized(@"样张");
    status.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    status.textAlignment = NSTextAlignmentCenter;
    status.textColor = FMProfileInkColor(profileID, self.traitCollection);
    status.backgroundColor = [UIColor.whiteColor colorWithAlphaComponent:0.42];
    status.layer.cornerRadius = 11;
    status.layer.cornerCurve = kCACornerCurveContinuous;
    status.layer.masksToBounds = YES;
    [card addSubview:status];
    card.accessibilityIdentifier = @"scheme_specimen";

    [NSLayoutConstraint activateConstraints:@[
        [card.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:20],
        [card.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-20],
        [card.topAnchor constraintEqualToAnchor:header.topAnchor constant:10],
        [card.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-10],
        [eyebrow.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20],
        [eyebrow.topAnchor constraintEqualToAnchor:card.topAnchor constant:18],
        [eyebrow.trailingAnchor constraintLessThanOrEqualToAnchor:status.leadingAnchor constant:-8],
        [status.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [status.topAnchor constraintEqualToAnchor:card.topAnchor constant:16],
        [status.heightAnchor constraintEqualToConstant:24],
        [status.widthAnchor constraintGreaterThanOrEqualToConstant:64],
        [specimen.leadingAnchor constraintEqualToAnchor:eyebrow.leadingAnchor],
        [specimen.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20],
        [specimen.topAnchor constraintEqualToAnchor:eyebrow.bottomAnchor constant:14],
        [latin.leadingAnchor constraintEqualToAnchor:eyebrow.leadingAnchor],
        [latin.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20],
        [latin.topAnchor constraintEqualToAnchor:specimen.bottomAnchor constant:4],
        [divider.leadingAnchor constraintEqualToAnchor:eyebrow.leadingAnchor],
        [divider.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20],
        [divider.topAnchor constraintEqualToAnchor:latin.bottomAnchor constant:14],
        [divider.heightAnchor constraintEqualToConstant:1],
        [nameLabel.leadingAnchor constraintEqualToAnchor:eyebrow.leadingAnchor],
        [nameLabel.topAnchor constraintEqualToAnchor:divider.bottomAnchor constant:12],
        [nameLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20],
        [description.leadingAnchor constraintEqualToAnchor:eyebrow.leadingAnchor],
        [description.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20],
        [description.topAnchor constraintEqualToAnchor:nameLabel.bottomAnchor constant:2],
        [description.bottomAnchor constraintLessThanOrEqualToAnchor:card.bottomAnchor constant:-14],
    ]];
    return header;
}

- (void)installFloatingActionDock {
    self.actionDock = [[FMFloatingActionDockView alloc] initWithFrame:CGRectZero];
    self.actionDock.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.actionDock];

    self.applyButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.applyButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.applyButton.accessibilityIdentifier = @"scheme_apply";
    UIButtonConfiguration *configuration = [UIButtonConfiguration filledButtonConfiguration];
    configuration.imagePadding = 8;
    configuration.cornerStyle = UIButtonConfigurationCornerStyleLarge;
    NSString *profileID = FMLibraryNormalizedProfileID(self.profile[@"id"]);
    NSString *name = FMFriendlyProfileName(profileID, self.profile[@"name"]);
    if (self.loadError.length > 0) {
        configuration.title = FMLocalized(@"方案暂不可用");
        configuration.image = [UIImage systemImageNamed:@"exclamationmark.triangle"];
        configuration.baseBackgroundColor = UIColor.tertiarySystemFillColor;
        configuration.baseForegroundColor = UIColor.secondaryLabelColor;
        self.applyButton.enabled = NO;
    } else if ([self.status isEqual:FMLocalized(@"使用中")]) {
        configuration.title = [NSString stringWithFormat:FMLocalized(@"正在使用「%@」"), name];
        configuration.image = [UIImage systemImageNamed:@"checkmark.circle.fill"];
        configuration.baseBackgroundColor = UIColor.tertiarySystemFillColor;
        configuration.baseForegroundColor = UIColor.secondaryLabelColor;
        self.applyButton.enabled = NO;
    } else if ([self.status isEqual:FMLocalized(@"等待 Respring")]) {
        if (self.workspace.allowsRestart) {
            configuration.title = @"Respring";
            configuration.image = [UIImage systemImageNamed:@"arrow.clockwise"];
            configuration.baseBackgroundColor = FMPrimaryActionColor();
            configuration.baseForegroundColor = FMPrimaryActionForegroundColor();
        } else {
            configuration.title = FMLocalized(@"Respring 暂不可用");
            configuration.image = [UIImage systemImageNamed:@"exclamationmark.triangle"];
            configuration.baseBackgroundColor = UIColor.tertiarySystemFillColor;
            configuration.baseForegroundColor = UIColor.secondaryLabelColor;
            self.applyButton.enabled = NO;
        }
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
    }
    self.applyButton.configuration = configuration;
    [self.applyButton addTarget:self action:@selector(applyScheme:)
              forControlEvents:UIControlEventTouchUpInside];
    [self.actionDock addSubview:self.applyButton];

    UIEdgeInsets contentInset = self.tableView.contentInset;
    contentInset.bottom = MAX(contentInset.bottom, 92);
    self.tableView.contentInset = contentInset;
    UIEdgeInsets indicatorInsets = self.tableView.verticalScrollIndicatorInsets;
    indicatorInsets.bottom = MAX(indicatorInsets.bottom, 92);
    self.tableView.verticalScrollIndicatorInsets = indicatorInsets;

    [NSLayoutConstraint activateConstraints:@[
        [self.actionDock.leadingAnchor
            constraintEqualToAnchor:self.tableView.frameLayoutGuide.leadingAnchor],
        [self.actionDock.trailingAnchor
            constraintEqualToAnchor:self.tableView.frameLayoutGuide.trailingAnchor],
        [self.actionDock.bottomAnchor
            constraintEqualToAnchor:self.tableView.frameLayoutGuide.bottomAnchor],
        [self.applyButton.leadingAnchor constraintEqualToAnchor:self.actionDock.leadingAnchor
                                                        constant:20],
        [self.applyButton.trailingAnchor constraintEqualToAnchor:self.actionDock.trailingAnchor
                                                         constant:-20],
        [self.applyButton.topAnchor constraintEqualToAnchor:self.actionDock.topAnchor constant:14],
        [self.applyButton.heightAnchor constraintEqualToConstant:54],
        [self.applyButton.bottomAnchor
            constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-12],
    ]];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self.view bringSubviewToFront:self.actionDock];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    if (self.loadError.length > 0) return 1;
    return (NSInteger)[self.details[@"relativePaths"] count];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    NSUInteger count = [self.details[@"relativePaths"] count];
    return self.loadError.length > 0
               ? FMLocalized(@"方案详情")
               : [NSString stringWithFormat:FMLocalized(@"涉及的镜像文件 · %lu"), (unsigned long)count];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    if (self.loadError.length > 0) return nil;
    NSString *profileID = FMLibraryNormalizedProfileID(self.profile[@"id"]);
    if (profileID == nil) {
        return FMLocalized(@"恢复系统默认时，这些受管理文件会使用本机原始内容。");
    }
    return FMLocalized(@"未列出的镜像文件保持原样；切换方案时，旧方案多出的差异会恢复为系统内容。");
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"FileCell"
                                                            forIndexPath:indexPath];
    UIListContentConfiguration *content = [UIListContentConfiguration subtitleCellConfiguration];
    if (self.loadError.length > 0) {
        content.text = FMLocalized(@"无法读取方案文件");
        content.secondaryText = self.loadError;
        content.image = [UIImage systemImageNamed:@"exclamationmark.triangle.fill"];
        content.imageProperties.tintColor = FMDangerColor();
    } else {
        NSArray<NSString *> *paths = self.details[@"relativePaths"];
        NSString *relativePath = paths[(NSUInteger)indexPath.row];
        content.text = FMFriendlyMirrorRole(relativePath);
        content.secondaryText = relativePath;
        content.secondaryTextProperties.font = [UIFont monospacedSystemFontOfSize:12
                                                                           weight:UIFontWeightRegular];
        content.image = [UIImage systemImageNamed:@"doc.text.fill"];
        content.imageProperties.tintColor = FMAccentColor();
        cell.accessibilityIdentifier = [@"scheme_file_" stringByAppendingString:
            [relativePath stringByReplacingOccurrencesOfString:@"/" withString:@"_"]];
    }
    content.textProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    content.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    cell.contentConfiguration = content;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.isAccessibilityElement = YES;
    cell.accessibilityLabel = content.text;
    cell.accessibilityValue = content.secondaryText;
    return cell;
}

- (void)applyScheme:(id)sender {
    (void)sender;
    NSString *profileID = FMLibraryNormalizedProfileID(self.profile[@"id"]);
    if ([self.status isEqual:FMLocalized(@"等待 Respring")]) {
        if (!self.workspace.allowsRestart) return;
    } else {
        if (!self.workspace.allowsChanges) return;
        NSError *error = nil;
        if (![self.workspace stageProfileID:profileID error:&error]) {
            UIAlertController *alert =
                [UIAlertController alertControllerWithTitle:FMLocalized(@"暂时无法应用")
                                                    message:error.localizedDescription
                                             preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:FMLocalized(@"好")
                                                     style:UIAlertActionStyleDefault
                                                   handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
            return;
        }
        [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium]
            impactOccurred];
    }
    FMFontLibraryApplyHandler applyHandler = self.applyHandler;
    [self.navigationController dismissViewControllerAnimated:YES completion:^{
        if (applyHandler != nil) applyHandler(profileID);
    }];
}

@end

typedef NS_ENUM(NSInteger, FMFontPackagePreviewSection) {
    FMFontPackagePreviewSectionMatches = 0,
    FMFontPackagePreviewSectionConflicts,
    FMFontPackagePreviewSectionOtherSystemVersions,
    FMFontPackagePreviewSectionUnmatched,
    FMFontPackagePreviewSectionInvalid,
    FMFontPackagePreviewSectionCount,
};

typedef void (^FMFontPackageSavedHandler)(NSDictionary<NSString *, id> *profile);

@interface FMFontPackagePreviewViewController : UITableViewController
@property(nonatomic, copy) NSDictionary<NSString *, id> *preview;
@property(nonatomic, strong, nullable) id<FMProfileWorkspace> workspace;
@property(nonatomic, strong, nullable) FMFontPackageImportSession *importSession;
@property(nonatomic, copy, nullable) FMFontPackageSavedHandler savedHandler;
@property(nonatomic, strong) FMFloatingActionDockView *actionDock;
@property(nonatomic, strong) UIButton *saveButton;
@property(nonatomic) BOOL saving;
- (instancetype)initWithPreview:(NSDictionary<NSString *, id> *)preview;
- (instancetype)initWithPreview:(NSDictionary<NSString *, id> *)preview
                        workspace:(id<FMProfileWorkspace>)workspace
                    importSession:(FMFontPackageImportSession *)importSession
                     savedHandler:(FMFontPackageSavedHandler)savedHandler;
- (void)discardImportSession;
@end

@implementation FMFontPackagePreviewViewController

- (instancetype)initWithPreview:(NSDictionary<NSString *, id> *)preview {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self != nil) _preview = [preview copy];
    return self;
}

- (instancetype)initWithPreview:(NSDictionary<NSString *, id> *)preview
                        workspace:(id<FMProfileWorkspace>)workspace
                    importSession:(FMFontPackageImportSession *)importSession
                     savedHandler:(FMFontPackageSavedHandler)savedHandler {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self != nil) {
        _preview = [preview copy];
        _workspace = workspace;
        _importSession = importSession;
        _savedHandler = [savedHandler copy];
    }
    return self;
}

- (BOOL)canSaveProfile {
    return self.workspace != nil && self.importSession.packageURL != nil &&
        [self.workspace respondsToSelector:@selector(saveFontPackageAtPath:profileName:error:)] &&
        [self.preview[@"matchedTargetCount"] unsignedIntegerValue] > 0 &&
        [self.preview[@"conflictTargetCount"] unsignedIntegerValue] == 0;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = FMLocalized(@"匹配结果");
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.tableView.backgroundColor = FMCanvasColor();
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 66;
    self.tableView.accessibilityIdentifier = @"font_package_preview";
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"PreviewCell"];
    self.tableView.tableHeaderView = [self makeSummaryHeader];
    self.tableView.tableFooterView = [self makeSafetyFooter];
    [self installFloatingSaveDock];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:FMLocalized(@"完成")
                                        style:UIBarButtonItemStyleDone
                                       target:self
                                        action:@selector(finishPreview:)];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    BOOL leavingPreview = self.isMovingFromParentViewController ||
                          self.navigationController.isBeingDismissed;
    if (leavingPreview && !self.saving) [self discardImportSession];
}

- (void)discardImportSession {
    FMFontPackageImportSession *session = self.importSession;
    if (session == nil) return;
    if ([session discard:nil]) self.importSession = nil;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self.view bringSubviewToFront:self.actionDock];
    UIView *header = self.tableView.tableHeaderView;
    CGFloat width = self.tableView.bounds.size.width;
    if (header == nil || width <= 0) return;
    CGRect frame = header.frame;
    frame.size.width = width;
    header.frame = frame;
    [header setNeedsLayout];
    [header layoutIfNeeded];
    CGFloat height = [header
        systemLayoutSizeFittingSize:CGSizeMake(width, UILayoutFittingCompressedSize.height)
        withHorizontalFittingPriority:UILayoutPriorityRequired
              verticalFittingPriority:UILayoutPriorityFittingSizeLevel].height;
    if (height > 0 && fabs(frame.size.height - height) > 0.5) {
        frame.size.height = height;
        header.frame = frame;
        self.tableView.tableHeaderView = header;
    }
}

- (NSArray<NSDictionary<NSString *, id> *> *)itemsForSection:(NSInteger)section {
    switch ((FMFontPackagePreviewSection)section) {
        case FMFontPackagePreviewSectionMatches:
            return [self.preview[@"matches"] isKindOfClass:NSArray.class]
                ? self.preview[@"matches"] : @[];
        case FMFontPackagePreviewSectionConflicts:
            return [self.preview[@"conflicts"] isKindOfClass:NSArray.class]
                ? self.preview[@"conflicts"] : @[];
        case FMFontPackagePreviewSectionOtherSystemVersions:
            return [self.preview[@"otherSystemVersionSources"] isKindOfClass:NSArray.class]
                ? self.preview[@"otherSystemVersionSources"] : @[];
        case FMFontPackagePreviewSectionUnmatched:
            return [self.preview[@"unmatched"] isKindOfClass:NSArray.class]
                ? self.preview[@"unmatched"] : @[];
        case FMFontPackagePreviewSectionInvalid:
            return [self.preview[@"invalidFontEntries"] isKindOfClass:NSArray.class]
                ? self.preview[@"invalidFontEntries"] : @[];
        case FMFontPackagePreviewSectionCount:
            return @[];
    }
}

- (UIView *)makeSummaryHeader {
    NSUInteger matched = [self.preview[@"matchedTargetCount"] unsignedIntegerValue];
    NSUInteger unmatched = [self.preview[@"unmatchedSourceCount"] unsignedIntegerValue];
    NSUInteger conflicts = [self.preview[@"conflictTargetCount"] unsignedIntegerValue];
    NSUInteger invalid = [self.preview[@"invalidFontEntryCount"] unsignedIntegerValue];
    NSUInteger deduplicated = [self.preview[@"deduplicatedSourceCount"] unsignedIntegerValue];
    NSUInteger otherSystemVersions =
        [self.preview[@"otherSystemVersionSourceCount"] unsignedIntegerValue];
    UIColor *color = conflicts > 0 || matched == 0 ? FMWarnColor() : FMSuccessColor();

    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0,
                                                               self.view.bounds.size.width, 196)];
    UIView *card = FMCardView();
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = FMTintedBackground(color);
    card.layer.borderColor = [color colorWithAlphaComponent:0.14].CGColor;
    [header addSubview:card];

    UIView *iconBackground = [[UIView alloc] initWithFrame:CGRectZero];
    iconBackground.translatesAutoresizingMaskIntoConstraints = NO;
    iconBackground.backgroundColor = [color colorWithAlphaComponent:0.12];
    iconBackground.layer.cornerRadius = 19;
    iconBackground.layer.cornerCurve = kCACornerCurveContinuous;
    [card addSubview:iconBackground];

    UIImageView *icon = [[UIImageView alloc]
        initWithImage:[UIImage systemImageNamed:conflicts > 0 ? @"exclamationmark.triangle.fill"
                                                               : @"doc.text.magnifyingglass"]];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.tintColor = color;
    [iconBackground addSubview:icon];

    UILabel *eyebrow = FMLabel(UIFontTextStyleCaption1, UIFontWeightSemibold,
                               UIColor.secondaryLabelColor);
    eyebrow.translatesAutoresizingMaskIntoConstraints = NO;
    eyebrow.text = self.preview[@"packageName"] ?: FMLocalized(@"字体包");
    eyebrow.numberOfLines = 1;
    [card addSubview:eyebrow];

    UILabel *title = FMLabel(UIFontTextStyleTitle2, UIFontWeightBold, UIColor.labelColor);
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = conflicts > 0
        ? [NSString stringWithFormat:FMLocalized(@"发现 %lu 个同名冲突"), (unsigned long)conflicts]
        : (matched > 0
               ? [NSString stringWithFormat:FMLocalized(@"匹配到 %lu 个系统字体"), (unsigned long)matched]
               : FMLocalized(@"没有匹配到本机系统字体"));
    title.numberOfLines = 2;
    [card addSubview:title];

    UILabel *detail = FMLabel(UIFontTextStyleFootnote, UIFontWeightRegular,
                              UIColor.secondaryLabelColor);
    detail.translatesAutoresizingMaskIntoConstraints = NO;
    NSMutableArray<NSString *> *notes = [NSMutableArray array];
    if (unmatched > 0) {
        [notes addObject:[NSString stringWithFormat:FMLocalized(@"%lu 个文件在本机没有同名目标"),
                                                        (unsigned long)unmatched]];
    }
    if (invalid > 0) {
        [notes addObject:[NSString stringWithFormat:FMLocalized(@"%lu 个文件不是有效字体"),
                                                        (unsigned long)invalid]];
    }
    if (deduplicated > 0) {
        [notes addObject:[NSString stringWithFormat:FMLocalized(@"%lu 个相同副本已自动合并"),
                                                        (unsigned long)deduplicated]];
    }
    if (otherSystemVersions > 0) {
        [notes addObject:[NSString stringWithFormat:FMLocalized(@"%lu 个其他系统版本文件已自动忽略"),
                                                        (unsigned long)otherSystemVersions]];
    }
    detail.text = notes.count > 0
        ? [notes componentsJoinedByString:@" · "]
        : FMLocalized(@"字体包中的文件都能按本机原版文件名对应。");
    detail.numberOfLines = 3;
    [card addSubview:detail];

    UILabel *badge = FMLabel(UIFontTextStyleCaption2, UIFontWeightSemibold, color);
    badge.translatesAutoresizingMaskIntoConstraints = NO;
    badge.text = [self canSaveProfile] ? FMLocalized(@"可以保存") : FMLocalized(@"匹配预览");
    badge.textAlignment = NSTextAlignmentCenter;
    badge.backgroundColor = [color colorWithAlphaComponent:0.12];
    badge.layer.cornerRadius = 11;
    badge.layer.cornerCurve = kCACornerCurveContinuous;
    badge.layer.masksToBounds = YES;
    [card addSubview:badge];

    [NSLayoutConstraint activateConstraints:@[
        [card.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:20],
        [card.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-20],
        [card.topAnchor constraintEqualToAnchor:header.topAnchor constant:12],
        [card.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-12],
        [iconBackground.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [iconBackground.topAnchor constraintEqualToAnchor:card.topAnchor constant:18],
        [iconBackground.widthAnchor constraintEqualToConstant:38],
        [iconBackground.heightAnchor constraintEqualToConstant:38],
        [icon.centerXAnchor constraintEqualToAnchor:iconBackground.centerXAnchor],
        [icon.centerYAnchor constraintEqualToAnchor:iconBackground.centerYAnchor],
        [icon.widthAnchor constraintEqualToConstant:20],
        [icon.heightAnchor constraintEqualToConstant:20],
        [badge.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [badge.centerYAnchor constraintEqualToAnchor:iconBackground.centerYAnchor],
        [badge.widthAnchor constraintGreaterThanOrEqualToConstant:70],
        [badge.heightAnchor constraintEqualToConstant:24],
        [eyebrow.leadingAnchor constraintEqualToAnchor:iconBackground.trailingAnchor constant:11],
        [eyebrow.trailingAnchor constraintLessThanOrEqualToAnchor:badge.leadingAnchor constant:-8],
        [eyebrow.centerYAnchor constraintEqualToAnchor:iconBackground.centerYAnchor],
        [title.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [title.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [title.topAnchor constraintEqualToAnchor:iconBackground.bottomAnchor constant:17],
        [detail.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [detail.trailingAnchor constraintEqualToAnchor:title.trailingAnchor],
        [detail.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:8],
        [detail.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-17],
    ]];
    card.isAccessibilityElement = YES;
    card.accessibilityLabel = [NSString stringWithFormat:@"%@，%@，%@",
                                                        eyebrow.text, title.text, detail.text];
    return header;
}

- (UIView *)makeSafetyFooter {
    UIView *footer = [[UIView alloc] initWithFrame:CGRectMake(0, 0,
                                                               self.view.bounds.size.width, 82)];
    UILabel *label = FMLabel(UIFontTextStyleCaption1, UIFontWeightRegular,
                             UIColor.tertiaryLabelColor);
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 3;
    NSUInteger conflicts = [self.preview[@"conflictTargetCount"] unsignedIntegerValue];
    NSUInteger matched = [self.preview[@"matchedTargetCount"] unsignedIntegerValue];
    if (conflicts > 0) {
        label.text = FMLocalized(@"存在同名冲突，暂时不能保存。请整理字体包后重新选择；当前字体不会改变。");
    } else if (matched == 0) {
        label.text = FMLocalized(@"没有可保存的本机匹配项；当前字体和字体镜像都不会改变。");
    } else if ([self canSaveProfile]) {
        label.text = FMLocalized(@"保存只会把已匹配文件复制进字体库，不会替换镜像、切换字体、调用挂载组件或重启设备。");
    } else {
        label.text = FMLocalized(@"本页只检查匹配关系，不会保存字体方案、替换镜像、调用挂载组件或重启设备。");
    }
    [footer addSubview:label];

    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:footer.leadingAnchor constant:28],
        [label.trailingAnchor constraintEqualToAnchor:footer.trailingAnchor constant:-28],
        [label.topAnchor constraintEqualToAnchor:footer.topAnchor constant:12],
        [label.bottomAnchor constraintLessThanOrEqualToAnchor:footer.bottomAnchor constant:-12],
    ]];
    return footer;
}

- (void)installFloatingSaveDock {
    self.actionDock = [[FMFloatingActionDockView alloc] initWithFrame:CGRectZero];
    self.actionDock.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.actionDock];

    self.saveButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.saveButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.saveButton.accessibilityIdentifier = @"package_save_profile";
    UIButtonConfiguration *configuration = [UIButtonConfiguration filledButtonConfiguration];
    configuration.cornerStyle = UIButtonConfigurationCornerStyleLarge;
    configuration.imagePadding = 7;
    configuration.baseBackgroundColor = FMAccentColor();
    configuration.baseForegroundColor = UIColor.whiteColor;
    NSUInteger conflicts = [self.preview[@"conflictTargetCount"] unsignedIntegerValue];
    NSUInteger matched = [self.preview[@"matchedTargetCount"] unsignedIntegerValue];
    if ([self canSaveProfile]) {
        configuration.title = FMLocalized(@"存入字体库");
        configuration.image = [UIImage systemImageNamed:@"tray.and.arrow.down.fill"];
    } else if (conflicts > 0) {
        configuration.title = FMLocalized(@"请先处理同名冲突");
        configuration.image = [UIImage systemImageNamed:@"exclamationmark.triangle.fill"];
        configuration.baseBackgroundColor = UIColor.tertiarySystemFillColor;
        configuration.baseForegroundColor = UIColor.secondaryLabelColor;
        self.saveButton.enabled = NO;
    } else {
        configuration.title = matched == 0 ? FMLocalized(@"没有可保存的字体") : FMLocalized(@"当前仅可预览");
        configuration.image = [UIImage systemImageNamed:@"eye.fill"];
        configuration.baseBackgroundColor = UIColor.tertiarySystemFillColor;
        configuration.baseForegroundColor = UIColor.secondaryLabelColor;
        self.saveButton.enabled = NO;
    }
    self.saveButton.configuration = configuration;
    [self.saveButton addTarget:self
                        action:@selector(requestSaveProfile:)
              forControlEvents:UIControlEventTouchUpInside];
    [self.actionDock addSubview:self.saveButton];

    UIEdgeInsets contentInset = self.tableView.contentInset;
    contentInset.bottom = MAX(contentInset.bottom, 92);
    self.tableView.contentInset = contentInset;
    UIEdgeInsets indicatorInsets = self.tableView.verticalScrollIndicatorInsets;
    indicatorInsets.bottom = MAX(indicatorInsets.bottom, 92);
    self.tableView.verticalScrollIndicatorInsets = indicatorInsets;

    [NSLayoutConstraint activateConstraints:@[
        [self.actionDock.leadingAnchor
            constraintEqualToAnchor:self.tableView.frameLayoutGuide.leadingAnchor],
        [self.actionDock.trailingAnchor
            constraintEqualToAnchor:self.tableView.frameLayoutGuide.trailingAnchor],
        [self.actionDock.bottomAnchor
            constraintEqualToAnchor:self.tableView.frameLayoutGuide.bottomAnchor],
        [self.saveButton.leadingAnchor constraintEqualToAnchor:self.actionDock.leadingAnchor
                                                        constant:20],
        [self.saveButton.trailingAnchor constraintEqualToAnchor:self.actionDock.trailingAnchor
                                                         constant:-20],
        [self.saveButton.topAnchor constraintEqualToAnchor:self.actionDock.topAnchor constant:14],
        [self.saveButton.heightAnchor constraintEqualToConstant:54],
        [self.saveButton.bottomAnchor
            constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-12],
    ]];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return FMFontPackagePreviewSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    return (NSInteger)[self itemsForSection:section].count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    NSUInteger count = [self itemsForSection:section].count;
    if (count == 0) return nil;
    switch ((FMFontPackagePreviewSection)section) {
        case FMFontPackagePreviewSectionMatches:
            return [NSString stringWithFormat:FMLocalized(@"会涉及的镜像文件 · %lu"), (unsigned long)count];
        case FMFontPackagePreviewSectionConflicts:
            return [NSString stringWithFormat:FMLocalized(@"需要处理的同名冲突 · %lu"), (unsigned long)count];
        case FMFontPackagePreviewSectionOtherSystemVersions:
            return [NSString stringWithFormat:FMLocalized(@"其他系统版本 · %lu"), (unsigned long)count];
        case FMFontPackagePreviewSectionUnmatched:
            return [NSString stringWithFormat:FMLocalized(@"本机没有同名目标 · %lu"), (unsigned long)count];
        case FMFontPackagePreviewSectionInvalid:
            return [NSString stringWithFormat:FMLocalized(@"无法识别的文件 · %lu"), (unsigned long)count];
        case FMFontPackagePreviewSectionCount:
            return nil;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"PreviewCell"
                                                            forIndexPath:indexPath];
    NSDictionary<NSString *, id> *item = [self itemsForSection:indexPath.section]
                                                  [(NSUInteger)indexPath.row];
    UIListContentConfiguration *content = [UIListContentConfiguration subtitleCellConfiguration];
    NSString *symbol = @"doc.text.fill";
    UIColor *color = FMAccentColor();
    switch ((FMFontPackagePreviewSection)indexPath.section) {
        case FMFontPackagePreviewSectionMatches: {
            content.text = item[@"fileName"];
            content.secondaryText = [NSString stringWithFormat:FMLocalized(@"镜像  %@\n包内  %@"),
                                                               item[@"targetRelativePath"],
                                                               FMLibraryCompactPackagePath(
                                                                   item[@"selectedSourceRelativePath"])];
            symbol = @"checkmark.circle.fill";
            color = FMSuccessColor();
            break;
        }
        case FMFontPackagePreviewSectionConflicts:
            content.text = item[@"fileName"];
            content.secondaryText = [NSString stringWithFormat:FMLocalized(@"%lu 份同名文件内容不同，当前不会选择任何一份"),
                                                               (unsigned long)[item[@"alternatives"] count]];
            symbol = @"exclamationmark.triangle.fill";
            color = FMWarnColor();
            break;
        case FMFontPackagePreviewSectionOtherSystemVersions:
            content.text = item[@"fileName"];
            content.secondaryText = [NSString stringWithFormat:FMLocalized(@"包内  %@\n此文件属于其他系统版本，不参与匹配或写入"),
                                                               FMLibraryCompactPackagePath(
                                                                   item[@"sourceRelativePath"])];
            symbol = @"arrow.triangle.branch";
            color = UIColor.secondaryLabelColor;
            break;
        case FMFontPackagePreviewSectionUnmatched:
            content.text = item[@"fileName"];
            content.secondaryText = [NSString stringWithFormat:FMLocalized(@"包内  %@\n本机原版字体中没有同名文件，保持忽略"),
                                                               FMLibraryCompactPackagePath(
                                                                   item[@"sourceRelativePath"])];
            symbol = @"minus.circle.fill";
            color = UIColor.secondaryLabelColor;
            break;
        case FMFontPackagePreviewSectionInvalid:
            content.text = item[@"fileName"];
            content.secondaryText = [NSString stringWithFormat:FMLocalized(@"包内  %@\n%@"),
                                                               FMLibraryCompactPackagePath(
                                                                   item[@"sourceRelativePath"]),
                                                               item[@"reason"] ?: FMLocalized(@"无法识别为字体")];
            symbol = @"xmark.circle.fill";
            color = FMDangerColor();
            break;
        case FMFontPackagePreviewSectionCount:
            break;
    }
    content.image = [UIImage systemImageNamed:symbol];
    content.imageProperties.tintColor = color;
    content.textProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    content.secondaryTextProperties.font = [UIFont monospacedSystemFontOfSize:11.5
                                                                       weight:UIFontWeightRegular];
    content.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    content.secondaryTextProperties.numberOfLines = 4;
    cell.contentConfiguration = content;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.isAccessibilityElement = YES;
    cell.accessibilityLabel = content.text;
    cell.accessibilityValue = content.secondaryText;
    cell.accessibilityIdentifier = [NSString stringWithFormat:@"package_preview_%ld_%ld",
                                                               (long)indexPath.section,
                                                               (long)indexPath.row];
    return cell;
}

- (void)finishPreview:(id)sender {
    (void)sender;
    if (self.saving) return;
    [self discardImportSession];
    [self.navigationController popViewControllerAnimated:YES];
}

- (void)requestSaveProfile:(id)sender {
    (void)sender;
    if (![self canSaveProfile] || self.saving) return;
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:FMLocalized(@"存入字体库")
                                            message:FMLocalized(@"给这套字体取一个容易辨认的名称。保存后不会立即应用。")
                                     preferredStyle:UIAlertControllerStyleAlert];
    NSString *suggestedName = [self.preview[@"packageName"] isKindOfClass:NSString.class]
        ? self.preview[@"packageName"] : FMLocalized(@"我的字体");
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.text = suggestedName;
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
        textField.returnKeyType = UIReturnKeyDone;
        textField.accessibilityIdentifier = @"package_profile_name";
    }];
    [alert addAction:[UIAlertAction actionWithTitle:FMLocalized(@"取消")
                                             style:UIAlertActionStyleCancel
                                           handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:FMLocalized(@"保存")
                                             style:UIAlertActionStyleDefault
                                           handler:^(__unused UIAlertAction *action) {
        NSString *name = [alert.textFields.firstObject.text
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        [weakSelf saveProfileWithName:name];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)saveProfileWithName:(NSString *)name {
    if (name.length == 0 || name.length > 80) {
        UIAlertController *invalid =
            [UIAlertController alertControllerWithTitle:FMLocalized(@"名称不可用")
                                                message:FMLocalized(@"请输入 1–80 个字符的字体名称。")
                                         preferredStyle:UIAlertControllerStyleAlert];
        [invalid addAction:[UIAlertAction actionWithTitle:FMLocalized(@"好")
                                                   style:UIAlertActionStyleDefault
                                                 handler:nil]];
        [self presentViewController:invalid animated:YES completion:nil];
        return;
    }
    if (![self canSaveProfile] || self.saving) return;
    self.saving = YES;
    self.saveButton.enabled = NO;
    self.navigationItem.rightBarButtonItem.enabled = NO;

    UIAlertController *progress =
        [UIAlertController alertControllerWithTitle:FMLocalized(@"正在存入字体库")
                                            message:FMLocalized(@"正在重新验证并复制已匹配的字体…\n\n")
                                     preferredStyle:UIAlertControllerStyleAlert];
    UIActivityIndicatorView *indicator = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    indicator.translatesAutoresizingMaskIntoConstraints = NO;
    [indicator startAnimating];
    [progress.view addSubview:indicator];
    [NSLayoutConstraint activateConstraints:@[
        [indicator.centerXAnchor constraintEqualToAnchor:progress.view.centerXAnchor],
        [indicator.bottomAnchor constraintEqualToAnchor:progress.view.bottomAnchor constant:-19],
    ]];

    id<FMProfileWorkspace> workspace = self.workspace;
    FMFontPackageImportSession *importSession = self.importSession;
    NSURL *sourceURL = importSession.packageURL;
    __weak typeof(self) weakSelf = self;
    [self presentViewController:progress animated:YES completion:^{
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSError *error = nil;
            NSDictionary<NSString *, id> *saved =
                [workspace saveFontPackageAtPath:sourceURL.path
                                      profileName:name
                                            error:&error];
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) strongSelf = weakSelf;
                if (strongSelf == nil) {
                    [importSession discard:nil];
                    return;
                }
                strongSelf.saving = NO;
                if (saved != nil) [strongSelf discardImportSession];
                strongSelf.saveButton.enabled = saved == nil && [strongSelf canSaveProfile];
                strongSelf.navigationItem.rightBarButtonItem.enabled = YES;
                [progress dismissViewControllerAnimated:YES completion:^{
                    if (saved == nil) {
                        UIAlertController *failure =
                            [UIAlertController alertControllerWithTitle:FMLocalized(@"暂时无法保存")
                                                                message:error.localizedDescription ?: FMLocalized(@"字体方案没有写入字体库。")
                                                         preferredStyle:UIAlertControllerStyleAlert];
                        [failure addAction:[UIAlertAction actionWithTitle:FMLocalized(@"好")
                                                                   style:UIAlertActionStyleDefault
                                                                 handler:nil]];
                        [strongSelf presentViewController:failure animated:YES completion:nil];
                        return;
                    }
                    [[[UINotificationFeedbackGenerator alloc] init]
                        notificationOccurred:UINotificationFeedbackTypeSuccess];
                    NSUInteger count = [saved[@"replacementCount"] unsignedIntegerValue];
                    UIAlertController *done =
                        [UIAlertController alertControllerWithTitle:FMLocalized(@"已存入字体库")
                                                            message:[NSString stringWithFormat:FMLocalized(@"已保存 %lu 个匹配字体文件。当前字体和镜像没有变化。"), (unsigned long)count]
                                                     preferredStyle:UIAlertControllerStyleAlert];
                    [done addAction:[UIAlertAction actionWithTitle:FMLocalized(@"查看字体库")
                                                             style:UIAlertActionStyleDefault
                                                           handler:^(__unused UIAlertAction *action) {
                        if (strongSelf.savedHandler != nil) strongSelf.savedHandler(saved);
                        [strongSelf.navigationController popViewControllerAnimated:YES];
                    }]];
                    [strongSelf presentViewController:done animated:YES completion:nil];
                }];
            });
        });
    }];
}

@end

@interface FMFontLibraryViewController () <UITableViewDataSource, UITableViewDelegate,
                                                    UIDocumentPickerDelegate>
@property(nonatomic, strong) id<FMProfileWorkspace> workspace;
@property(nonatomic, strong) UITableView *tableView;
@property(nonatomic, copy) NSArray<NSArray<NSDictionary<NSString *, id> *> *> *sections;
@property(nonatomic, copy) NSDictionary<NSString *, id> *state;
@property(nonatomic, copy) NSDictionary<NSString *, UIFont *> *previewFontsByProfileID;
@property(nonatomic, strong, nullable) UIFont *stockPreviewFont;
@property(nonatomic, copy, nullable) NSString *workspaceError;
@property(nonatomic, copy) FMFontLibraryApplyHandler applyHandler;
@property(nonatomic, copy) dispatch_block_t dismissalHandler;
@property(nonatomic) BOOL packagePreviewInProgress;
@end

@implementation FMFontLibraryViewController

- (instancetype)initWithWorkspace:(id<FMProfileWorkspace>)workspace
                      applyHandler:(FMFontLibraryApplyHandler)applyHandler
                  dismissalHandler:(dispatch_block_t)dismissalHandler {
    self = [super initWithNibName:nil bundle:nil];
    if (self != nil) {
        _workspace = workspace;
        _applyHandler = [applyHandler copy];
        _dismissalHandler = [dismissalHandler copy];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = FMCanvasColor();
    self.title = FMLocalized(@"字体库");
    self.navigationController.navigationBar.prefersLargeTitles = NO;
    UIBarButtonItem *close =
        [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"xmark"]
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(closeLibrary:)];
    close.accessibilityLabel = FMLocalized(@"关闭字体库");
    self.navigationItem.rightBarButtonItem = close;

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.backgroundColor = FMCanvasColor();
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = 110;
    self.tableView.estimatedRowHeight = 110;
    self.tableView.contentInset = UIEdgeInsetsMake(0, 0, 24, 0);
    self.tableView.accessibilityIdentifier = @"font_library";
    [self.tableView registerClass:FMFontLibraryCell.class forCellReuseIdentifier:@"FontCell"];
    [self.view addSubview:self.tableView];
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
    self.tableView.tableHeaderView = [self makeImportHeader];
    [self reloadLibrary];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.navigationController.navigationBar.prefersLargeTitles = NO;
    [self reloadLibrary];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UIView *header = self.tableView.tableHeaderView;
    CGFloat width = self.tableView.bounds.size.width;
    if (header == nil || width <= 0) return;

    CGRect frame = header.frame;
    frame.size.width = width;
    header.frame = frame;
    [header setNeedsLayout];
    [header layoutIfNeeded];
    CGFloat height = [header
        systemLayoutSizeFittingSize:CGSizeMake(width, UILayoutFittingCompressedSize.height)
        withHorizontalFittingPriority:UILayoutPriorityRequired
              verticalFittingPriority:UILayoutPriorityFittingSizeLevel].height;
    if (height > 0 && fabs(frame.size.height - height) > 0.5) {
        frame.size.height = height;
        header.frame = frame;
        self.tableView.tableHeaderView = header;
    }
}

- (BOOL)canPreviewFontPackages {
    return [self.workspace respondsToSelector:@selector(previewFontPackageAtPath:error:)];
}

- (BOOL)canSaveFontPackages {
    return [self.workspace respondsToSelector:
        @selector(saveFontPackageAtPath:profileName:error:)];
}

- (UIView *)makeImportHeader {
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 1)];
    UIView *card = FMCardView();
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = FMTintedBackground(FMAccentColor());
    card.layer.borderColor = [FMAccentColor() colorWithAlphaComponent:0.14].CGColor;
    [header addSubview:card];

    UIImageView *icon = [[UIImageView alloc]
        initWithImage:[UIImage systemImageNamed:@"plus"
                              withConfiguration:[UIImageSymbolConfiguration
                                                    configurationWithPointSize:20
                                                                      weight:UIImageSymbolWeightSemibold]]];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.tintColor = FMAccentColor();
    [card addSubview:icon];

    UILabel *title = FMLabel(UIFontTextStyleTitle3, UIFontWeightBold, UIColor.labelColor);
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = FMLocalized(@"加入新的字体");
    [card addSubview:title];

    UILabel *detail = FMLabel(UIFontTextStyleFootnote, UIFontWeightRegular,
                              UIColor.secondaryLabelColor);
    detail.translatesAutoresizingMaskIntoConstraints = NO;
    BOOL canPreviewPackages = [self canPreviewFontPackages];
    BOOL canSavePackages = [self canSaveFontPackages];
    detail.text = canPreviewPackages
        ? (canSavePackages
               ? FMLocalized(@"选择 ZIP 或字体文件，检查匹配后存入字体库。")
               : FMLocalized(@"选择 ZIP 或字体文件，先查看会对应到哪些本机系统字体。"))
        : FMLocalized(@"已连接本机字体目录；字体包导入将在写入链路完成后开放。");
    detail.numberOfLines = 2;
    [card addSubview:detail];

    UILabel *importTip = FMLabel(UIFontTextStyleCaption1, UIFontWeightRegular,
                                 UIColor.secondaryLabelColor);
    importTip.translatesAutoresizingMaskIntoConstraints = NO;
    importTip.text = [@"· " stringByAppendingString:
        FMLocalized(@"导入闪退：请关闭“设置”中 MarkFont 的“粗体文本”。")];
    importTip.textAlignment = NSTextAlignmentCenter;
    importTip.accessibilityIdentifier = @"profile_import_crash_hint";
    [header addSubview:importTip];

    UILabel *chineseImportTip = nil;
    if (FMLibraryShouldShowIOS18To26ChineseImportTip()) {
        chineseImportTip = FMLabel(UIFontTextStyleCaption1, UIFontWeightSemibold,
                                   FMAccentColor());
        chineseImportTip.translatesAutoresizingMaskIntoConstraints = NO;
        chineseImportTip.text = [@"· " stringByAppendingString:
            FMLocalized(@"iOS 18–26 中文：请导入专用 PingFangUI.ttc。")];
        chineseImportTip.textAlignment = NSTextAlignmentCenter;
        chineseImportTip.accessibilityIdentifier = @"profile_import_ios18_chinese_hint";
        [header addSubview:chineseImportTip];
    }

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.accessibilityIdentifier = @"profile_import";
    UIButtonConfiguration *configuration = [UIButtonConfiguration filledButtonConfiguration];
    configuration.title = FMLocalized(@"选择字体包");
    configuration.image = [UIImage systemImageNamed:@"doc.badge.plus"];
    configuration.imagePadding = 7;
    configuration.cornerStyle = UIButtonConfigurationCornerStyleLarge;
    configuration.baseBackgroundColor = FMAccentColor();
    configuration.baseForegroundColor = UIColor.whiteColor;
    if (!canPreviewPackages) {
        configuration.title = FMLocalized(@"字体包导入尚未开放");
        configuration.image = [UIImage systemImageNamed:@"lock.fill"];
        configuration.baseBackgroundColor = UIColor.tertiarySystemFillColor;
        configuration.baseForegroundColor = UIColor.secondaryLabelColor;
        button.enabled = NO;
    }
    button.configuration = configuration;
    [button addTarget:self action:@selector(importFont:) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:button];

    [NSLayoutConstraint activateConstraints:@[
        [card.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:20],
        [card.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-20],
        [card.topAnchor constraintEqualToAnchor:header.topAnchor constant:8],
        [icon.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [icon.topAnchor constraintEqualToAnchor:card.topAnchor constant:16],
        [icon.widthAnchor constraintEqualToConstant:25],
        [icon.heightAnchor constraintEqualToConstant:25],
        [title.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:11],
        [title.centerYAnchor constraintEqualToAnchor:icon.centerYAnchor],
        [title.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [detail.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [detail.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [detail.topAnchor constraintEqualToAnchor:icon.bottomAnchor constant:8],
        [button.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [button.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
        [button.topAnchor constraintEqualToAnchor:detail.bottomAnchor constant:12],
        [button.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-12],
        [button.heightAnchor constraintEqualToConstant:44],
        [importTip.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:24],
        [importTip.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-24],
        [importTip.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-8],
    ]];
    if (chineseImportTip != nil) {
        [NSLayoutConstraint activateConstraints:@[
            [chineseImportTip.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:24],
            [chineseImportTip.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-24],
            [chineseImportTip.topAnchor constraintEqualToAnchor:card.bottomAnchor constant:8],
            [importTip.topAnchor constraintEqualToAnchor:chineseImportTip.bottomAnchor constant:3],
        ]];
    } else {
        [importTip.topAnchor constraintEqualToAnchor:card.bottomAnchor constant:8].active = YES;
    }
    return header;
}

- (void)reloadLibrary {
    NSError *error = nil;
    if (![self.workspace prepareIfNeeded:&error]) {
        self.workspaceError = error.localizedDescription ?: FMLocalized(@"暂时无法读取字体库");
        self.state = @{};
        self.sections = @[ @[], @[] ];
        self.previewFontsByProfileID = @{};
        self.stockPreviewFont = nil;
    } else {
        self.state = [self.workspace currentState:&error] ?: @{};
        NSMutableArray<NSDictionary<NSString *, id> *> *builtIn = [NSMutableArray arrayWithObject:@{
            @"id" : NSNull.null,
            @"name" : FMLocalized(@"系统默认"),
        }];
        NSMutableArray<NSDictionary<NSString *, id> *> *imported = [NSMutableArray array];
        for (NSDictionary<NSString *, NSString *> *profile in self.workspace.availableProfiles) {
            if ([profile[@"id"] hasPrefix:@"import-"]) [imported addObject:profile];
            else [builtIn addObject:profile];
        }
        self.sections = @[ builtIn, imported ];
        NSMutableDictionary<NSString *, UIFont *> *previewFonts =
            [NSMutableDictionary dictionary];
        NSDictionary<NSString *, id> *stockDetails =
            [self.workspace detailsForProfileID:nil error:nil];
        NSString *stockPath =
            [stockDetails[@"previewLatinFontPath"] isKindOfClass:NSString.class]
                ? stockDetails[@"previewLatinFontPath"]
                : stockDetails[@"previewFontPath"];
        self.stockPreviewFont = FMPreviewFontAtPath(stockPath, 31);
        for (NSDictionary<NSString *, id> *profile in self.workspace.availableProfiles) {
            NSString *profileID = FMLibraryNormalizedProfileID(profile[@"id"]);
            if (profileID == nil) continue;
            NSDictionary<NSString *, id> *details =
                [self.workspace detailsForProfileID:profileID error:nil];
            NSString *path = [details[@"previewLatinFontPath"] isKindOfClass:NSString.class]
                                 ? details[@"previewLatinFontPath"]
                                 : details[@"previewFontPath"];
            UIFont *font = FMPreviewFontAtPath(path, 31);
            if (font != nil) previewFonts[profileID] = font;
        }
        self.previewFontsByProfileID = previewFonts;
        self.workspaceError = error.localizedDescription;
    }
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    return (NSInteger)self.sections[(NSUInteger)section].count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) return FMLocalized(@"内置风格");
    return self.sections[1].count > 0 ? FMLocalized(@"我的字体") : nil;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    NSString *title = [self tableView:tableView titleForHeaderInSection:section];
    if (title == nil) return nil;
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

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return [self tableView:tableView titleForHeaderInSection:section] == nil ? 0 : 34;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    FMFontLibraryCell *cell = [tableView dequeueReusableCellWithIdentifier:@"FontCell"
                                                              forIndexPath:indexPath];
    NSDictionary<NSString *, id> *profile = self.sections[(NSUInteger)indexPath.section]
                                                       [(NSUInteger)indexPath.row];
    NSString *profileID = FMLibraryNormalizedProfileID(profile[@"id"]);
    NSString *confirmedID = FMLibraryNormalizedProfileID(self.state[@"confirmedProfileID"]);
    NSString *workingID = FMLibraryNormalizedProfileID(self.state[@"workingProfileID"]);
    NSString *status = nil;
    if ([self.state[@"restartRequired"] boolValue] &&
        FMLibraryProfileIDsEqual(profileID, workingID)) {
        status = FMLocalized(@"等待 Respring");
    }
    else if (FMLibraryProfileIDsEqual(profileID, confirmedID)) status = FMLocalized(@"使用中");
    NSString *name = FMFriendlyProfileName(profileID, profile[@"name"]);
    [cell configureWithProfileID:profileID
                            name:name
                     previewFont:profileID == nil
                                     ? self.stockPreviewFont
                                     : self.previewFontsByProfileID[profileID]
                          status:status];
    cell.accessibilityIdentifier = profileID == nil
                                       ? @"library_stock"
                                       : [@"library_" stringByAppendingString:profileID];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary<NSString *, id> *profile = self.sections[(NSUInteger)indexPath.section]
                                                       [(NSUInteger)indexPath.row];
    NSString *profileID = FMLibraryNormalizedProfileID(profile[@"id"]);
    [[[UISelectionFeedbackGenerator alloc] init] selectionChanged];
    FMFontSchemeDetailViewController *detail =
        [[FMFontSchemeDetailViewController alloc] initWithWorkspace:self.workspace
                                                            profile:profile
                                                             status:[self statusForProfileID:profileID]
                                                       applyHandler:self.applyHandler];
    [self.navigationController pushViewController:detail animated:YES];
}

- (NSString *)statusForProfileID:(NSString *)profileID {
    NSString *confirmedID = FMLibraryNormalizedProfileID(self.state[@"confirmedProfileID"]);
    NSString *workingID = FMLibraryNormalizedProfileID(self.state[@"workingProfileID"]);
    if ([self.state[@"restartRequired"] boolValue] &&
        FMLibraryProfileIDsEqual(profileID, workingID)) {
        return FMLocalized(@"等待 Respring");
    }
    if (FMLibraryProfileIDsEqual(profileID, confirmedID)) return FMLocalized(@"使用中");
    return nil;
}

- (void)closeLibrary:(id)sender {
    (void)sender;
    if (self.dismissalHandler != nil) self.dismissalHandler();
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    if (!self.workspace.allowsChanges && ![self canSaveFontPackages]) return NO;
    if (indexPath.section != 1) return NO;
    NSDictionary<NSString *, id> *profile = self.sections[1][(NSUInteger)indexPath.row];
    return [FMLibraryNormalizedProfileID(profile[@"id"]) hasPrefix:@"import-"];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    if (indexPath.section != 1) return nil;
    NSDictionary<NSString *, id> *profile = self.sections[1][(NSUInteger)indexPath.row];
    __weak typeof(self) weakSelf = self;
    UIContextualAction *deleteAction =
        [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                                                title:nil
                                              handler:^(__unused UIContextualAction *action,
                                                        __unused UIView *source,
                                                        void (^completion)(BOOL)) {
        [weakSelf confirmDeleteProfile:profile completion:completion];
    }];
    deleteAction.backgroundColor =
        [FMCanvasColor() resolvedColorWithTraitCollection:tableView.traitCollection];
    deleteAction.image = FMCircularDeleteActionImage(tableView.traitCollection);
    UISwipeActionsConfiguration *configuration =
        [UISwipeActionsConfiguration configurationWithActions:@[ deleteAction ]];
    configuration.performsFirstActionWithFullSwipe = NO;
    return configuration;
}

- (void)confirmDeleteProfile:(NSDictionary<NSString *, id> *)profile
                  completion:(void (^)(BOOL))completion {
    NSString *profileID = FMLibraryNormalizedProfileID(profile[@"id"]);
    NSString *confirmedID = FMLibraryNormalizedProfileID(self.state[@"confirmedProfileID"]);
    NSString *workingID = FMLibraryNormalizedProfileID(self.state[@"workingProfileID"]);
    NSString *name = FMFriendlyProfileName(profileID, profile[@"name"]);
    if (FMLibraryProfileIDsEqual(profileID, confirmedID) ||
        FMLibraryProfileIDsEqual(profileID, workingID)) {
        UIAlertController *inUse =
            [UIAlertController alertControllerWithTitle:FMLocalized(@"这款字体正在使用")
                                                message:FMLocalized(@"请先切换到另一款字体并完成切换，再回来删除。")
                                         preferredStyle:UIAlertControllerStyleAlert];
        [inUse addAction:[UIAlertAction actionWithTitle:FMLocalized(@"知道了")
                                                 style:UIAlertActionStyleDefault
                                               handler:^(__unused UIAlertAction *action) {
            completion(NO);
        }]];
        [self presentViewController:inUse animated:YES completion:nil];
        return;
    }
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:FMLocalized(@"删除“%@”？"), name]
                                            message:FMLocalized(@"删除后不能恢复；需要再次使用时，请重新导入字体文件。")
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:FMLocalized(@"取消")
                                             style:UIAlertActionStyleCancel
                                           handler:^(__unused UIAlertAction *action) {
        completion(NO);
    }]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:FMLocalized(@"删除")
                                             style:UIAlertActionStyleDestructive
                                           handler:^(__unused UIAlertAction *action) {
        NSError *error = nil;
        BOOL success = [weakSelf.workspace deleteProfileID:profileID error:&error];
        if (!success) [weakSelf presentOperationError:error];
        else [[[UINotificationFeedbackGenerator alloc] init]
                  notificationOccurred:UINotificationFeedbackTypeSuccess];
        [weakSelf reloadLibrary];
        completion(success);
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)importFont:(id)sender {
    (void)sender;
    if (![self canPreviewFontPackages]) return;
    NSError *cleanupError = nil;
    if (![FMFontPackageImportSession discardAbandonedSessions:&cleanupError]) {
        [self presentOperationError:cleanupError];
        return;
    }
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc]
            initForOpeningContentTypes:@[ UTTypeZIP, UTTypeFont ]
                                asCopy:NO];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    picker.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
    didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    (void)controller;
    NSURL *sourceURL = urls.firstObject;
    if (sourceURL == nil) return;
    [self previewFontPackageURL:sourceURL];
}

- (void)previewFontPackageURL:(NSURL *)sourceURL {
    if (self.packagePreviewInProgress) return;
    self.packagePreviewInProgress = YES;

    UIAlertController *progress =
        [UIAlertController alertControllerWithTitle:FMLocalized(@"正在检查字体包")
                                            message:FMLocalized(@"正在创建临时副本并按本机原版文件名匹配…\n\n")
                                     preferredStyle:UIAlertControllerStyleAlert];
    UIActivityIndicatorView *indicator = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    indicator.translatesAutoresizingMaskIntoConstraints = NO;
    [indicator startAnimating];
    [progress.view addSubview:indicator];
    [NSLayoutConstraint activateConstraints:@[
        [indicator.centerXAnchor constraintEqualToAnchor:progress.view.centerXAnchor],
        [indicator.bottomAnchor constraintEqualToAnchor:progress.view.bottomAnchor constant:-19],
    ]];
    [self presentViewController:progress animated:YES completion:nil];

    id<FMProfileWorkspace> workspace = self.workspace;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        FMFontPackageImportSession *importSession =
            [FMFontPackageImportSession sessionByImportingURL:sourceURL error:&error];
        NSDictionary<NSString *, id> *preview = importSession == nil ? nil :
            [workspace previewFontPackageAtPath:importSession.packageURL.path error:&error];
        if (preview == nil) [importSession discard:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (strongSelf == nil) {
                [importSession discard:nil];
                return;
            }
            strongSelf.packagePreviewInProgress = NO;
            [progress dismissViewControllerAnimated:YES completion:^{
                if (preview == nil) {
                    [strongSelf presentOperationError:error];
                    return;
                }
                [[[UISelectionFeedbackGenerator alloc] init] selectionChanged];
                __weak typeof(strongSelf) weakLibrary = strongSelf;
                FMFontPackagePreviewViewController *result =
                    [[FMFontPackagePreviewViewController alloc]
                        initWithPreview:preview
                              workspace:workspace
                         importSession:importSession
                           savedHandler:^(__unused NSDictionary<NSString *, id> *profile) {
                    [weakLibrary reloadLibrary];
                }];
                [strongSelf.navigationController pushViewController:result animated:YES];
            }];
        });
    });
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
