#import "FMCompatibilityViewController.h"

#import "FMDesignSystem.h"

typedef NS_ENUM(NSInteger, FMEnvironmentState) {
    FMEnvironmentStatePending = 0,
    FMEnvironmentStateReady,
    FMEnvironmentStateAttention,
    FMEnvironmentStateUnavailable,
};

static NSString *const FMEnvironmentTitleKey = @"title";
static NSString *const FMEnvironmentDetailKey = @"detail";
static NSString *const FMEnvironmentSymbolKey = @"symbol";
static NSString *const FMEnvironmentStateKey = @"state";
static NSString *const FMEnvironmentIdentifierKey = @"identifier";

static BOOL FMEnvironmentBool(NSDictionary *dictionary, NSString *key) {
    id value = dictionary[key];
    return [value isKindOfClass:NSNumber.class] && [value boolValue];
}

static BOOL FMEnvironmentBoolOrDefault(NSDictionary *dictionary,
                                       NSString *key,
                                       BOOL fallback) {
    id value = dictionary[key];
    return [value isKindOfClass:NSNumber.class] ? [value boolValue] : fallback;
}

static NSString *FMEnvironmentString(id value, NSString *fallback) {
    return [value isKindOfClass:NSString.class] && [value length] > 0
        ? value
        : fallback;
}

static UIColor *FMEnvironmentColor(FMEnvironmentState state) {
    switch (state) {
        case FMEnvironmentStateReady:
            return FMSuccessColor();
        case FMEnvironmentStateAttention:
            return FMWarnColor();
        case FMEnvironmentStateUnavailable:
            return FMDangerColor();
        case FMEnvironmentStatePending:
            return FMAccentColor();
    }
}

static NSString *FMEnvironmentStatusText(FMEnvironmentState state) {
    switch (state) {
        case FMEnvironmentStateReady:
            return FMLocalized(@"可用");
        case FMEnvironmentStateAttention:
            return FMLocalized(@"待完成");
        case FMEnvironmentStateUnavailable:
            return FMLocalized(@"需要处理");
        case FMEnvironmentStatePending:
            return FMLocalized(@"读取中");
    }
}

static NSDictionary<NSString *, id> *FMEnvironmentItem(
    NSString *identifier,
    NSString *title,
    NSString *detail,
    NSString *symbol,
    FMEnvironmentState state) {
    return @{
        FMEnvironmentIdentifierKey : identifier,
        FMEnvironmentTitleKey : title,
        FMEnvironmentDetailKey : detail,
        FMEnvironmentSymbolKey : symbol,
        FMEnvironmentStateKey : @(state),
    };
}

@interface FMEnvironmentHeroView : UIView
@property(nonatomic, strong) UIView *card;
@property(nonatomic, strong) UIView *iconBackground;
@property(nonatomic, strong) UIImageView *iconView;
@property(nonatomic, strong) UILabel *eyebrowLabel;
@property(nonatomic, strong) UILabel *titleLabel;
@property(nonatomic, strong) UILabel *detailLabel;
@property(nonatomic, strong) UILabel *privacyLabel;
- (void)configureWithTitle:(NSString *)title
                    detail:(NSString *)detail
                     state:(FMEnvironmentState)state;
@end

@implementation FMEnvironmentHeroView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self == nil) return nil;

    _card = FMCardView();
    _card.translatesAutoresizingMaskIntoConstraints = NO;
    _card.layer.cornerRadius = 28;
    [self addSubview:_card];

    _iconBackground = [[UIView alloc] initWithFrame:CGRectZero];
    _iconBackground.translatesAutoresizingMaskIntoConstraints = NO;
    _iconBackground.layer.cornerRadius = 22;
    _iconBackground.layer.cornerCurve = kCACornerCurveContinuous;
    [_card addSubview:_iconBackground];

    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:27
                                                        weight:UIImageSymbolWeightSemibold];
    _iconView = [[UIImageView alloc]
        initWithImage:[UIImage systemImageNamed:@"checkmark.shield.fill"
                              withConfiguration:configuration]];
    _iconView.translatesAutoresizingMaskIntoConstraints = NO;
    _iconView.contentMode = UIViewContentModeScaleAspectFit;
    [_iconBackground addSubview:_iconView];

    _eyebrowLabel = FMLabel(UIFontTextStyleCaption1, UIFontWeightSemibold,
                            UIColor.secondaryLabelColor);
    _eyebrowLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _eyebrowLabel.text = FMLocalized(@"运行环境");
    [_card addSubview:_eyebrowLabel];

    _titleLabel = FMLabel(UIFontTextStyleTitle2, UIFontWeightBold, UIColor.labelColor);
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.numberOfLines = 2;
    [_card addSubview:_titleLabel];

    _detailLabel = FMLabel(UIFontTextStyleSubheadline, UIFontWeightRegular,
                           UIColor.secondaryLabelColor);
    _detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _detailLabel.numberOfLines = 3;
    [_card addSubview:_detailLabel];

    _privacyLabel = FMLabel(UIFontTextStyleCaption1, UIFontWeightRegular,
                            UIColor.tertiaryLabelColor);
    _privacyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _privacyLabel.text = FMLocalized(@"只检查组件与连接状态，不扫描字体文件内容");
    _privacyLabel.numberOfLines = 2;
    [_card addSubview:_privacyLabel];

    [NSLayoutConstraint activateConstraints:@[
        [_card.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
        [_card.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
        [_card.topAnchor constraintEqualToAnchor:self.topAnchor constant:8],
        [_card.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-10],

        [_iconBackground.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:20],
        [_iconBackground.topAnchor constraintEqualToAnchor:_card.topAnchor constant:20],
        [_iconBackground.widthAnchor constraintEqualToConstant:62],
        [_iconBackground.heightAnchor constraintEqualToConstant:62],
        [_iconView.centerXAnchor constraintEqualToAnchor:_iconBackground.centerXAnchor],
        [_iconView.centerYAnchor constraintEqualToAnchor:_iconBackground.centerYAnchor],
        [_iconView.widthAnchor constraintEqualToConstant:31],
        [_iconView.heightAnchor constraintEqualToConstant:31],

        [_eyebrowLabel.leadingAnchor constraintEqualToAnchor:_iconBackground.trailingAnchor
                                                      constant:15],
        [_eyebrowLabel.topAnchor constraintEqualToAnchor:_iconBackground.topAnchor constant:2],
        [_eyebrowLabel.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-20],
        [_titleLabel.leadingAnchor constraintEqualToAnchor:_eyebrowLabel.leadingAnchor],
        [_titleLabel.trailingAnchor constraintEqualToAnchor:_eyebrowLabel.trailingAnchor],
        [_titleLabel.topAnchor constraintEqualToAnchor:_eyebrowLabel.bottomAnchor constant:4],

        [_detailLabel.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:20],
        [_detailLabel.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-20],
        [_detailLabel.topAnchor constraintEqualToAnchor:_iconBackground.bottomAnchor constant:16],
        [_privacyLabel.leadingAnchor constraintEqualToAnchor:_detailLabel.leadingAnchor],
        [_privacyLabel.trailingAnchor constraintEqualToAnchor:_detailLabel.trailingAnchor],
        [_privacyLabel.topAnchor constraintEqualToAnchor:_detailLabel.bottomAnchor constant:13],
        [_privacyLabel.bottomAnchor constraintEqualToAnchor:_card.bottomAnchor constant:-18],
    ]];
    self.accessibilityIdentifier = @"environment_summary";
    return self;
}

- (void)configureWithTitle:(NSString *)title
                    detail:(NSString *)detail
                     state:(FMEnvironmentState)state {
    UIColor *color = FMEnvironmentColor(state);
    self.titleLabel.text = title;
    self.detailLabel.text = detail;
    self.iconBackground.backgroundColor = FMTintedBackground(color);
    self.iconView.tintColor = color;
    NSString *symbol = state == FMEnvironmentStateReady
        ? @"checkmark.shield.fill"
        : state == FMEnvironmentStateUnavailable
            ? @"xmark.shield.fill"
            : state == FMEnvironmentStateAttention
                ? @"exclamationmark.shield.fill"
                : @"ellipsis.circle.fill";
    self.iconView.image = [UIImage systemImageNamed:symbol];
    self.isAccessibilityElement = YES;
    self.accessibilityLabel = title;
    self.accessibilityValue = detail;
}

@end


@interface FMEnvironmentStatusCell : UITableViewCell
@property(nonatomic, strong) UIView *card;
@property(nonatomic, strong) UIView *iconBackground;
@property(nonatomic, strong) UIImageView *iconView;
@property(nonatomic, strong) UILabel *titleLabel;
@property(nonatomic, strong) UILabel *detailLabel;
@property(nonatomic, strong) UIView *statusDot;
@property(nonatomic, strong) UILabel *statusLabel;
- (void)configureWithItem:(NSDictionary<NSString *, id> *)item;
@end

@implementation FMEnvironmentStatusCell

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

    _detailLabel = FMLabel(UIFontTextStyleFootnote, UIFontWeightRegular,
                           UIColor.secondaryLabelColor);
    _detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _detailLabel.numberOfLines = 2;
    [_card addSubview:_detailLabel];

    _statusDot = [[UIView alloc] initWithFrame:CGRectZero];
    _statusDot.translatesAutoresizingMaskIntoConstraints = NO;
    _statusDot.layer.cornerRadius = 3.5;
    [_card addSubview:_statusDot];

    _statusLabel = FMLabel(UIFontTextStyleCaption1, UIFontWeightSemibold,
                           UIColor.secondaryLabelColor);
    _statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _statusLabel.numberOfLines = 1;
    [_card addSubview:_statusLabel];

    [NSLayoutConstraint activateConstraints:@[
        [_card.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:20],
        [_card.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-20],
        [_card.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:4],
        [_card.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-4],
        [_card.heightAnchor constraintGreaterThanOrEqualToConstant:76],

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
        [_titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_statusDot.leadingAnchor
                                                               constant:-10],
        [_detailLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
        [_detailLabel.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-14],
        [_detailLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:3],
        [_detailLabel.bottomAnchor constraintEqualToAnchor:_card.bottomAnchor constant:-12],

        [_statusLabel.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-15],
        [_statusLabel.centerYAnchor constraintEqualToAnchor:_titleLabel.centerYAnchor],
        [_statusDot.trailingAnchor constraintEqualToAnchor:_statusLabel.leadingAnchor constant:-6],
        [_statusDot.centerYAnchor constraintEqualToAnchor:_statusLabel.centerYAnchor],
        [_statusDot.widthAnchor constraintEqualToConstant:7],
        [_statusDot.heightAnchor constraintEqualToConstant:7],
    ]];
    return self;
}

- (void)configureWithItem:(NSDictionary<NSString *, id> *)item {
    FMEnvironmentState state = [item[FMEnvironmentStateKey] integerValue];
    UIColor *color = FMEnvironmentColor(state);
    self.titleLabel.text = item[FMEnvironmentTitleKey];
    self.detailLabel.text = item[FMEnvironmentDetailKey];
    self.iconView.image = [UIImage systemImageNamed:item[FMEnvironmentSymbolKey]];
    self.iconView.tintColor = color;
    self.iconBackground.backgroundColor = FMTintedBackground(color);
    self.statusDot.backgroundColor = color;
    self.statusLabel.text = FMEnvironmentStatusText(state);
    self.statusLabel.textColor = color;
    self.accessibilityIdentifier = item[FMEnvironmentIdentifierKey];
    self.accessibilityLabel = item[FMEnvironmentTitleKey];
    self.accessibilityValue = [NSString stringWithFormat:@"%@，%@",
        FMEnvironmentStatusText(state), item[FMEnvironmentDetailKey]];
}

@end


@interface FMCompatibilityViewController ()
@property(nonatomic, copy, nullable) FMCompatibilityStatusLoader statusLoader;
@property(nonatomic, copy, nullable) NSDictionary<NSString *, id> *status;
@property(nonatomic, strong, nullable) NSError *loadError;
@property(nonatomic, copy) NSArray<NSDictionary<NSString *, id> *> *items;
@property(nonatomic, strong) FMEnvironmentHeroView *heroView;
@property(nonatomic, strong) UILabel *footerLabel;
@property(nonatomic) BOOL hasAnimatedEntrance;
@end

@implementation FMCompatibilityViewController

- (instancetype)initWithEnvironmentStatus:(NSDictionary<NSString *, id> *)status
                              statusLoader:(FMCompatibilityStatusLoader)statusLoader {
    self = [super initWithStyle:UITableViewStylePlain];
    if (self != nil) {
        _status = [status copy];
        _statusLoader = [statusLoader copy];
        _items = @[];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = FMLocalized(@"运行环境");
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.view.backgroundColor = FMCanvasColor();
    self.tableView.backgroundColor = FMCanvasColor();
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 84;
    self.tableView.sectionHeaderHeight = 24;
    self.tableView.sectionFooterHeight = 4;
    self.tableView.contentInset = UIEdgeInsetsMake(0, 0, 18, 0);
    self.tableView.accessibilityIdentifier = @"environment_status";
    [self.tableView registerClass:FMEnvironmentStatusCell.class
           forCellReuseIdentifier:@"EnvironmentStatusCell"];

    UIBarButtonItem *refresh = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"arrow.clockwise"]
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(refreshStatus:)];
    refresh.accessibilityLabel = FMLocalized(@"重新检查运行环境");
    refresh.accessibilityIdentifier = @"environment_refresh";
    refresh.tintColor = FMAccentColor();
    self.navigationItem.rightBarButtonItem = refresh;

    UIRefreshControl *refreshControl = [[UIRefreshControl alloc] init];
    refreshControl.tintColor = FMAccentColor();
    [refreshControl addTarget:self action:@selector(refreshStatus:)
             forControlEvents:UIControlEventValueChanged];
    self.refreshControl = refreshControl;

    self.heroView = [[FMEnvironmentHeroView alloc]
        initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 212)];
    self.tableView.tableHeaderView = self.heroView;

    UIView *footer = [[UIView alloc]
        initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 74)];
    self.footerLabel = FMLabel(UIFontTextStyleCaption1, UIFontWeightRegular,
                               UIColor.tertiaryLabelColor);
    self.footerLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.footerLabel.textAlignment = NSTextAlignmentCenter;
    self.footerLabel.numberOfLines = 3;
    [footer addSubview:self.footerLabel];
    [NSLayoutConstraint activateConstraints:@[
        [self.footerLabel.leadingAnchor constraintEqualToAnchor:footer.leadingAnchor constant:24],
        [self.footerLabel.trailingAnchor constraintEqualToAnchor:footer.trailingAnchor constant:-24],
        [self.footerLabel.topAnchor constraintEqualToAnchor:footer.topAnchor constant:14],
    ]];
    self.tableView.tableFooterView = footer;

    [self rebuildPresentation];
    if (self.status == nil && self.statusLoader != nil) {
        [self refreshStatus:nil];
    }
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self animateEntranceIfNeeded];
}

- (void)refreshStatus:(id)sender {
    (void)sender;
    if (self.statusLoader == nil) {
        [self.refreshControl endRefreshing];
        return;
    }
    self.navigationItem.rightBarButtonItem.enabled = NO;
    __weak typeof(self) weakSelf = self;
    self.statusLoader(^(NSDictionary<NSString *, id> *status, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf updateWithEnvironmentStatus:status error:error];
        });
    });
}

- (void)updateWithEnvironmentStatus:(NSDictionary<NSString *, id> *)status
                               error:(NSError *)error {
    self.status = [status copy];
    self.loadError = error;
    self.navigationItem.rightBarButtonItem.enabled = YES;
    [self.refreshControl endRefreshing];
    [self rebuildPresentation];
    [self.tableView reloadData];
}

- (void)rebuildPresentation {
    if (self.status == nil) {
        FMEnvironmentState state = self.loadError == nil
            ? FMEnvironmentStatePending
            : FMEnvironmentStateUnavailable;
        NSString *detail = self.loadError == nil
            ? FMLocalized(@"正在读取这台设备的基础组件和字体连接状态。")
            : FMLocalized(@"暂时无法读取设备状态。字体操作不会在状态未知时继续。");
        [self.heroView configureWithTitle:
            self.loadError == nil ? FMLocalized(@"正在检查运行环境") : FMLocalized(@"无法读取运行环境")
                                      detail:detail
                                       state:state];
        self.items = @[
            FMEnvironmentItem(@"environment_mount_backend", FMLocalized(@"内置挂载后端"),
                              FMLocalized(@"等待设备返回内置挂载后端状态"),
                              @"shippingbox.fill", state),
            FMEnvironmentItem(@"environment_mapping", FMLocalized(@"字体连接"),
                              FMLocalized(@"等待设备返回字体镜像连接状态"),
                              @"link", state),
            FMEnvironmentItem(@"environment_recovery", FMLocalized(@"恢复准备"),
                              FMLocalized(@"等待设备返回系统字体恢复状态"),
                              @"arrow.uturn.backward.circle.fill", state),
        ];
        self.footerLabel.text = FMLocalized(@"本页只读取状态，不会挂载、替换字体或重启设备");
        return;
    }

    NSDictionary *system = [self.status[@"system"] isKindOfClass:NSDictionary.class]
        ? self.status[@"system"] : @{};
    NSDictionary *mountBackend = [self.status[@"mountBackend"] isKindOfClass:NSDictionary.class]
        ? self.status[@"mountBackend"] : @{};
    NSDictionary *fonts = [self.status[@"fonts"] isKindOfClass:NSDictionary.class]
        ? self.status[@"fonts"] : @{};
    NSDictionary *state = [self.status[@"state"] isKindOfClass:NSDictionary.class]
        ? self.status[@"state"] : @{};
    NSString *engineState = FMEnvironmentString(self.status[@"engineState"], @"unavailable");

    BOOL executablePresent = FMEnvironmentBool(
        mountBackend, @"executablePresent");
    BOOL runtimePresent = FMEnvironmentBool(
        mountBackend, @"runtimeLibraryPresent");
    BOOL runtimeSecure = FMEnvironmentBool(
        mountBackend, @"runtimeLibrarySecure");
    BOOL storageSupported = FMEnvironmentBoolOrDefault(
        fonts, @"mountStorageSupported", NO);
    BOOL backendCompatible = FMEnvironmentBoolOrDefault(
        mountBackend, @"compatible", NO);
    BOOL backendReady = executablePresent && runtimePresent && runtimeSecure &&
        storageSupported && backendCompatible;
    BOOL versionKnown = [mountBackend[@"recognition"] isEqual:@"known"];
    NSString *backendDetail = backendReady
        ? (versionKnown
            ? FMLocalized(@"内置挂载后端已验证")
            : FMLocalized(@"内置挂载后端已通过能力检查"))
        : (!executablePresent
            ? FMLocalized(@"内置挂载后端缺失或安全属性异常")
            : (!runtimePresent || !runtimeSecure
                ? FMLocalized(@"当前越狱环境未提供可用的挂载能力")
                : (!storageSupported
                    ? FMLocalized(@"字体镜像存储位置不可用")
                    : FMLocalized(@"内置挂载后端与当前环境不兼容"))));

    BOOL sourceReady = FMEnvironmentBool(fonts, @"systemDirectoryReadable") &&
                       FMEnvironmentBool(fonts, @"rootfsDirectoryReadable");
    BOOL stateReady = FMEnvironmentBool(state, @"present") &&
                      FMEnvironmentBool(state, @"valid") &&
                      [state[@"mirrorState"] isEqual:@"clean"];
    BOOL mirrorReady = FMEnvironmentBool(fonts, @"mirrorPresent");
    BOOL mappingReady = FMEnvironmentBoolOrDefault(
        fonts, @"mappingManaged", FMEnvironmentBool(fonts, @"mappingActive"));
    BOOL connectionReady = [engineState isEqual:@"ready"] && sourceReady &&
                           stateReady && mirrorReady && mappingReady;
    BOOL waitingForSetup = [engineState isEqual:@"notInitialized"];
    NSString *connectionDetail = connectionReady
        ? FMLocalized(@"字体镜像已通过只读连接生效")
        : (waitingForSetup
            ? FMLocalized(@"首次设置完成后会自动建立字体连接")
            : (!sourceReady
                ? FMLocalized(@"当前无法读取系统字体来源")
                : (!mirrorReady
                    ? FMLocalized(@"字体镜像尚未准备好")
                    : FMLocalized(@"字体连接需要重新建立或修复"))));

    BOOL recoveryReady = FMEnvironmentBool(fonts, @"stockSnapshotPresent");
    NSString *recoveryDetail = recoveryReady
        ? FMLocalized(@"当前系统的原始字体恢复副本已准备")
        : FMLocalized(@"首次设置完成后会生成恢复副本");

    FMEnvironmentState backendState = backendReady
        ? FMEnvironmentStateReady : FMEnvironmentStateUnavailable;
    FMEnvironmentState connectionState = connectionReady
        ? FMEnvironmentStateReady
        : waitingForSetup ? FMEnvironmentStateAttention : FMEnvironmentStateUnavailable;
    FMEnvironmentState recoveryState = recoveryReady
        ? FMEnvironmentStateReady : FMEnvironmentStateAttention;
    self.items = @[
        FMEnvironmentItem(@"environment_mount_backend", FMLocalized(@"内置挂载后端"), backendDetail,
                          @"shippingbox.fill", backendState),
        FMEnvironmentItem(@"environment_mapping", FMLocalized(@"字体连接"), connectionDetail,
                          @"link", connectionState),
        FMEnvironmentItem(@"environment_recovery", FMLocalized(@"恢复准备"), recoveryDetail,
                          @"arrow.uturn.backward.circle.fill", recoveryState),
    ];

    if (!backendReady || !sourceReady ||
        ([engineState isEqual:@"unavailable"] ||
         [engineState isEqual:@"attentionRequired"])) {
        [self.heroView configureWithTitle:FMLocalized(@"运行环境需要处理")
                                    detail:FMLocalized(@"部分基础条件尚未满足，字体操作会保持停用。")
                                     state:FMEnvironmentStateUnavailable];
    } else if (!connectionReady) {
        [self.heroView configureWithTitle:FMLocalized(@"等待首次设置")
                                    detail:FMLocalized(@"基础组件可用，完成首次设置后即可管理系统字体。")
                                     state:FMEnvironmentStateAttention];
    } else if (!recoveryReady) {
        [self.heroView configureWithTitle:FMLocalized(@"还需完成恢复准备")
                                    detail:FMLocalized(@"字体连接正常；建立系统字体恢复副本后即可开放切换与重启。")
                                     state:FMEnvironmentStateAttention];
    } else {
        [self.heroView configureWithTitle:FMLocalized(@"字体环境已就绪")
                                    detail:FMLocalized(@"组件、字体连接和恢复准备均可用。")
                                     state:FMEnvironmentStateReady];
    }

    NSString *productType = FMEnvironmentString(system[@"productType"], FMLocalized(@"当前设备"));
    NSString *version = FMEnvironmentString(system[@"productVersion"], FMLocalized(@"未知版本"));
    NSString *build = FMEnvironmentString(system[@"productBuildVersion"], FMLocalized(@"未知构建"));
    self.footerLabel.text = [NSString stringWithFormat:
        FMLocalized(@"%@ · iOS %@ (%@)\n本页不会挂载、替换字体或重启设备"),
        productType, version, build];
}

- (void)animateEntranceIfNeeded {
    if (self.hasAnimatedEntrance || UIAccessibilityIsReduceMotionEnabled()) return;
    self.hasAnimatedEntrance = YES;
    self.heroView.alpha = 0;
    self.heroView.transform = CGAffineTransformMakeTranslation(0, 8);
    [UIView animateWithDuration:0.24
                          delay:0
                        options:UIViewAnimationOptionCurveEaseOut |
                                UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        self.heroView.alpha = 1;
        self.heroView.transform = CGAffineTransformIdentity;
    }
                     completion:nil];
    [self.tableView.visibleCells enumerateObjectsUsingBlock:^(
        UITableViewCell *cell, NSUInteger index, BOOL *stop) {
        (void)stop;
        cell.alpha = 0;
        cell.transform = CGAffineTransformMakeTranslation(0, 6);
        [UIView animateWithDuration:0.2
                              delay:0.025 * index
                            options:UIViewAnimationOptionCurveEaseOut |
                                    UIViewAnimationOptionAllowUserInteraction
                         animations:^{
            cell.alpha = 1;
            cell.transform = CGAffineTransformIdentity;
        }
                         completion:nil];
    }];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return (NSInteger)self.items.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return FMLocalized(@"字体切换所需条件");
}

- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view
        forSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    if (![view isKindOfClass:UITableViewHeaderFooterView.class]) return;
    UITableViewHeaderFooterView *header = (UITableViewHeaderFooterView *)view;
    header.textLabel.textColor = UIColor.secondaryLabelColor;
    header.textLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    FMEnvironmentStatusCell *cell =
        [tableView dequeueReusableCellWithIdentifier:@"EnvironmentStatusCell"
                                        forIndexPath:indexPath];
    [cell configureWithItem:self.items[(NSUInteger)indexPath.row]];
    return cell;
}

@end
