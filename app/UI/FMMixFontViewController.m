#import "FMMixFontViewController.h"

#import "FMDesignSystem.h"
#import "FMFloatingActionDockView.h"
#import "FMFontSlotCatalog.h"
#import "FMProfileWorkspace.h"

typedef void (^FMMixSelectionHandler)(NSString *_Nullable profileID);

static NSString *FMMixSlotSymbolName(NSString *slotID) {
    if ([slotID isEqual:FMFontSlotIdentifierChinese]) return @"character.book.closed.fill";
    if ([slotID isEqual:FMFontSlotIdentifierLatin]) return @"textformat.abc";
    if ([slotID isEqual:FMFontSlotIdentifierLockScreen]) return @"lock.fill";
    return @"doc.text.fill";
}

static NSUInteger FMMixCoveredPathCount(
    NSDictionary<NSString *, id> *scheme, NSArray<NSString *> *relativePaths) {
    NSSet<NSString *> *schemePaths = [scheme[@"paths"] isKindOfClass:NSSet.class]
        ? scheme[@"paths"]
        : nil;
    if (schemePaths == nil ||
        ![relativePaths isKindOfClass:NSArray.class]) {
        return 0;
    }
    NSUInteger covered = 0;
    for (NSString *relativePath in relativePaths) {
        if ([schemePaths containsObject:relativePath]) covered++;
    }
    return covered;
}

// One saved scheme with everything the composer needs: which catalog files it
// replaces, its preview fonts, and where each replacement file lives.
@interface FMMixSchemePickerViewController : UITableViewController
@property(nonatomic, copy) NSArray<NSDictionary<NSString *, id> *> *schemes;
@property(nonatomic, copy, nullable) NSDictionary<NSString *, id> *slot;
@property(nonatomic, copy, nullable) NSString *currentSelection;
@property(nonatomic, copy) FMMixSelectionHandler selectionHandler;
- (instancetype)initWithSlot:(nullable NSDictionary<NSString *, id> *)slot
                    schemes:(NSArray<NSDictionary<NSString *, id> *> *)schemes
              currentSelection:(nullable NSString *)currentSelection;
@end

@interface FMMixFontViewController ()
@property(nonatomic, strong) id<FMProfileWorkspace> workspace;
@property(nonatomic, copy, nullable) NSDictionary<NSString *, id> *mixRecipe;
@property(nonatomic, copy, nullable) NSString *replacingProfileID;
@property(nonatomic, copy) NSArray<NSDictionary<NSString *, id> *> *slots;
@property(nonatomic, copy) NSArray<NSDictionary<NSString *, id> *> *schemes;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *slotAssignments;
@property(nonatomic, copy, nullable) NSString *fallbackProfileID;
@property(nonatomic, copy, nullable) NSString *workspaceError;
@property(nonatomic, strong) FMFloatingActionDockView *actionDock;
@property(nonatomic, strong) UIButton *saveButton;
@property(nonatomic) BOOL saving;
@end

@implementation FMMixFontViewController

- (instancetype)initWithWorkspace:(id<FMProfileWorkspace>)workspace
                         mixRecipe:(nullable NSDictionary<NSString *, id> *)mixRecipe
                replacingProfileID:(nullable NSString *)replacingProfileID {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self != nil) {
        _workspace = workspace;
        _mixRecipe = [mixRecipe copy];
        _replacingProfileID = [replacingProfileID copy];
        _slots = @[];
        _schemes = @[];
        _slotAssignments = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = FMCanvasColor();
    self.title = FMLocalized(@"混搭字体");
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.tableView.backgroundColor = FMCanvasColor();
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 64;
    self.tableView.accessibilityIdentifier = @"mix_font_slots";
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"SlotCell"];
    [self reloadMixWorkspace];
    [self installFloatingActionDock];
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

#pragma mark - Data

- (void)reloadMixWorkspace {
    self.workspaceError = nil;
    NSError *error = nil;
    if (![self.workspace prepareIfNeeded:&error]) {
        self.workspaceError = error.localizedDescription ?: FMLocalized(@"暂时无法读取字体库");
        self.slots = @[];
        self.schemes = @[];
        [self refreshInterface];
        return;
    }
    self.slots = FMResolvedFontSlotsForRelativePaths(self.workspace.managedRelativePaths);
    [self reloadSchemes];
    [self applyRecipeIfNeeded];
    [self refreshInterface];
}

- (void)reloadSchemes {
    NSMutableArray<NSDictionary<NSString *, id> *> *schemes = [NSMutableArray array];
    for (NSDictionary<NSString *, NSString *> *profile in self.workspace.availableProfiles) {
        NSString *profileID = profile[@"id"];
        if (![profileID isKindOfClass:NSString.class] ||
            ![profileID hasPrefix:@"import-"]) {
            continue;
        }
        // An edited mix may be used as a source only after this edit round has
        // produced a new self-contained Profile. Excluding it here prevents a
        // recipe from pointing back to the Profile that this flow may delete.
        if ([profileID isEqual:self.replacingProfileID]) continue;
        NSDictionary<NSString *, id> *details =
            [self.workspace detailsForProfileID:profileID error:nil];
        if (details == nil) continue;
        NSDictionary<NSString *, NSString *> *filePathByRelativePath =
            [details[@"filePathByRelativePath"] isKindOfClass:NSDictionary.class]
                ? details[@"filePathByRelativePath"]
                : @{};
        [schemes addObject:@{
            @"id" : profileID,
            @"name" : profile[@"name"] ?: FMLocalized(@"自定义字体"),
            @"isMix" : @([details[@"isMix"] boolValue]),
            @"paths" : [NSSet setWithArray:(details[@"relativePaths"] ?: @[])],
            @"previewFontPath" : details[@"previewFontPath"] ?: NSNull.null,
            @"previewLatinFontPath" : details[@"previewLatinFontPath"] ?: NSNull.null,
            @"filePathByRelativePath" : filePathByRelativePath,
        }];
    }
    self.schemes = schemes;

    // Drop assignments whose source scheme no longer exists.
    NSMutableSet<NSString *> *availableIDs = [NSMutableSet set];
    for (NSDictionary<NSString *, id> *scheme in schemes) {
        [availableIDs addObject:scheme[@"id"]];
    }
    if (self.fallbackProfileID != nil &&
        ![availableIDs containsObject:self.fallbackProfileID]) {
        self.fallbackProfileID = nil;
    }
    NSMutableArray<NSString *> *staleSlotIDs = [NSMutableArray array];
    for (NSString *slotID in self.slotAssignments) {
        if (![availableIDs containsObject:self.slotAssignments[slotID]]) {
            [staleSlotIDs addObject:slotID];
        }
    }
    for (NSString *slotID in staleSlotIDs) {
        [self.slotAssignments removeObjectForKey:slotID];
    }
}

- (void)applyRecipeIfNeeded {
    if (self.mixRecipe == nil || self.slotAssignments.count > 0) return;
    NSDictionary<NSString *, id> *recipeSlots =
        [self.mixRecipe[@"slots"] isKindOfClass:NSDictionary.class]
            ? self.mixRecipe[@"slots"]
            : @{};
    for (NSString *slotID in recipeSlots.allKeys) {
        NSDictionary<NSString *, id> *source = recipeSlots[slotID];
        NSString *profileID = [source isKindOfClass:NSDictionary.class]
            ? source[@"profileID"]
            : nil;
        if (![profileID isKindOfClass:NSString.class]) continue;
        NSDictionary<NSString *, id> *slot = [self slotForIdentifier:slotID];
        NSDictionary<NSString *, id> *scheme = [self schemeForProfileID:profileID];
        if (scheme.count > 0 &&
            FMMixCoveredPathCount(scheme, slot[@"relativePaths"]) > 0) {
            self.slotAssignments[slotID] = profileID;
        }
    }
    NSDictionary<NSString *, id> *fallback = self.mixRecipe[@"fallback"];
    NSString *fallbackID = [fallback isKindOfClass:NSDictionary.class]
        ? fallback[@"profileID"]
        : nil;
    if ([fallbackID isKindOfClass:NSString.class] &&
        [self schemeForProfileID:fallbackID].count > 0) {
        self.fallbackProfileID = fallbackID;
    }
}

- (NSDictionary<NSString *, id> *)schemeForProfileID:(NSString *)profileID {
    for (NSDictionary<NSString *, id> *scheme in self.schemes) {
        if ([scheme[@"id"] isEqual:profileID]) return scheme;
    }
    return @{};
}

- (NSDictionary<NSString *, id> *)schemeAssignedToSlot:(NSDictionary<NSString *, id> *)slot {
    NSString *slotID = [slot isKindOfClass:NSDictionary.class] ? slot[@"slotID"] : nil;
    if (slotID == nil) return @{};
    NSString *profileID = self.slotAssignments[slotID];
    if (profileID == nil) return @{};
    return [self schemeForProfileID:profileID];
}

- (NSDictionary<NSString *, id> *)fallbackScheme {
    if (self.fallbackProfileID == nil) return @{};
    return [self schemeForProfileID:self.fallbackProfileID];
}

// How many files inside the slot the assigned scheme actually replaces.
- (NSUInteger)coveredPathCountForSlot:(NSDictionary<NSString *, id> *)slot {
    if (![slot isKindOfClass:NSDictionary.class]) return 0;
    return FMMixCoveredPathCount([self schemeAssignedToSlot:slot],
                                 slot[@"relativePaths"]);
}

- (NSUInteger)sharedStylePathCountForSlot:(NSDictionary<NSString *, id> *)slot {
    if (![slot isKindOfClass:NSDictionary.class]) return 0;
    return FMMixCoveredPathCount([self schemeAssignedToSlot:slot],
                                 slot[@"sharedStyleRelativePaths"]);
}

- (BOOL)hasAnyReplacement {
    if ([self fallbackScheme].count > 0) return YES;
    for (NSDictionary<NSString *, id> *slot in self.slots) {
        if ([self coveredPathCountForSlot:slot] > 0) return YES;
    }
    return NO;
}

- (void)refreshInterface {
    self.tableView.tableHeaderView = [self makePreviewHeader];
    [self.tableView reloadData];
    [self updateSaveButton];
}

- (void)updateSaveButton {
    self.saveButton.enabled = !self.saving && [self hasAnyReplacement] &&
        self.workspaceError == nil;
}

#pragma mark - Preview header

- (UIFont *)effectivePreviewFontForSlot:(NSDictionary<NSString *, id> *)slot
                                   latin:(BOOL)latin {
    if (![slot isKindOfClass:NSDictionary.class]) return nil;
    for (NSDictionary<NSString *, id> *scheme in
             @[ [self schemeAssignedToSlot:slot], [self fallbackScheme] ]) {
        NSDictionary<NSString *, NSString *> *paths =
            [scheme[@"filePathByRelativePath"] isKindOfClass:NSDictionary.class]
                ? scheme[@"filePathByRelativePath"]
                : @{};
        for (NSString *relativePath in slot[@"relativePaths"]) {
            UIFont *font = FMPreviewFontAtPath(paths[relativePath], latin ? 19 : 28);
            if (font != nil) return font;
        }
    }
    return nil;
}

- (UIFont *)effectiveClockPreviewFontForSlot:(NSDictionary<NSString *, id> *)slot {
    if (![slot isKindOfClass:NSDictionary.class]) return nil;
    for (NSDictionary<NSString *, id> *scheme in
             @[ [self schemeAssignedToSlot:slot], [self fallbackScheme] ]) {
        NSDictionary<NSString *, NSString *> *paths =
            [scheme[@"filePathByRelativePath"] isKindOfClass:NSDictionary.class]
                ? scheme[@"filePathByRelativePath"]
                : @{};
        for (NSString *relativePath in slot[@"relativePaths"]) {
            UIFont *font = FMPreviewFontAtPath(paths[relativePath], 38);
            if (font != nil) return font;
        }
    }
    return nil;
}

- (NSString *)effectiveSchemeNameForSlot:(NSDictionary<NSString *, id> *)slot {
    if (![slot isKindOfClass:NSDictionary.class]) return FMLocalized(@"系统默认");
    for (NSDictionary<NSString *, id> *scheme in
             @[ [self schemeAssignedToSlot:slot], [self fallbackScheme] ]) {
        if (FMMixCoveredPathCount(scheme, slot[@"relativePaths"]) > 0) {
            return scheme[@"name"];
        }
    }
    return FMLocalized(@"系统默认");
}

- (UIView *)makePreviewHeader {
    UIView *header = [[UIView alloc]
        initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 1)];
    UIView *card = FMCardView();
    card.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:card];

    UILabel *eyebrow = FMLabel(UIFontTextStyleCaption1, UIFontWeightSemibold,
                               UIColor.secondaryLabelColor);
    eyebrow.translatesAutoresizingMaskIntoConstraints = NO;
    eyebrow.text = FMLocalized(@"混搭预览");
    [card addSubview:eyebrow];

    NSDictionary<NSString *, id> *chineseSlot = [self slotForIdentifier:FMFontSlotIdentifierChinese];
    NSDictionary<NSString *, id> *latinSlot = [self slotForIdentifier:FMFontSlotIdentifierLatin];
    NSDictionary<NSString *, id> *lockSlot = [self slotForIdentifier:FMFontSlotIdentifierLockScreen];

    UILabel *chineseSample = FMLabel(UIFontTextStyleTitle2, UIFontWeightRegular,
                                     UIColor.labelColor);
    chineseSample.translatesAutoresizingMaskIntoConstraints = NO;
    chineseSample.text = @"春风有信，花开有期";
    chineseSample.adjustsFontForContentSizeCategory = NO;
    [card addSubview:chineseSample];

    UILabel *chineseCaption = FMLabel(UIFontTextStyleCaption2, UIFontWeightRegular,
                                      UIColor.secondaryLabelColor);
    chineseCaption.translatesAutoresizingMaskIntoConstraints = NO;
    chineseCaption.text = [NSString stringWithFormat:FMLocalized(@"中文 · %@"),
                           [self effectiveSchemeNameForSlot:chineseSlot]];
    [card addSubview:chineseCaption];

    UILabel *latinSample = FMLabel(UIFontTextStyleBody, UIFontWeightRegular,
                                   UIColor.labelColor);
    latinSample.translatesAutoresizingMaskIntoConstraints = NO;
    latinSample.text = @"Aa 0123456789 · The quick brown fox";
    [card addSubview:latinSample];

    UILabel *latinCaption = FMLabel(UIFontTextStyleCaption2, UIFontWeightRegular,
                                    UIColor.secondaryLabelColor);
    latinCaption.translatesAutoresizingMaskIntoConstraints = NO;
    latinCaption.text = [NSString stringWithFormat:FMLocalized(@"英文 · %@"),
                         [self effectiveSchemeNameForSlot:latinSlot]];
    [card addSubview:latinCaption];

    UILabel *clockSample = FMLabel(UIFontTextStyleTitle1, UIFontWeightBold,
                                   UIColor.labelColor);
    clockSample.translatesAutoresizingMaskIntoConstraints = NO;
    clockSample.text = @"9:41";
    clockSample.adjustsFontForContentSizeCategory = NO;
    [card addSubview:clockSample];

    UILabel *clockCaption = FMLabel(UIFontTextStyleCaption2, UIFontWeightRegular,
                                    UIColor.secondaryLabelColor);
    clockCaption.translatesAutoresizingMaskIntoConstraints = NO;
    clockCaption.text = [NSString stringWithFormat:FMLocalized(@"锁屏 · %@"),
                         [self effectiveSchemeNameForSlot:lockSlot]];
    [card addSubview:clockCaption];

    UIFont *chineseFont = chineseSlot != nil
        ? [self effectivePreviewFontForSlot:chineseSlot latin:NO]
        : nil;
    if (chineseFont != nil) chineseSample.font = chineseFont;
    UIFont *latinFont = latinSlot != nil
        ? [self effectivePreviewFontForSlot:latinSlot latin:YES]
        : nil;
    if (latinFont != nil) latinSample.font = latinFont;
    UIFont *clockFont = lockSlot != nil
        ? [self effectiveClockPreviewFontForSlot:lockSlot]
        : nil;
    if (clockFont != nil) clockSample.font = clockFont;

    [NSLayoutConstraint activateConstraints:@[
        [card.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:20],
        [card.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-20],
        [card.topAnchor constraintEqualToAnchor:header.topAnchor constant:8],
        [card.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-8],
        [eyebrow.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [eyebrow.topAnchor constraintEqualToAnchor:card.topAnchor constant:14],
        [chineseSample.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [chineseSample.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [chineseSample.topAnchor constraintEqualToAnchor:eyebrow.bottomAnchor constant:10],
        [chineseCaption.leadingAnchor constraintEqualToAnchor:chineseSample.leadingAnchor],
        [chineseCaption.trailingAnchor constraintEqualToAnchor:chineseSample.trailingAnchor],
        [chineseCaption.topAnchor constraintEqualToAnchor:chineseSample.bottomAnchor constant:2],
        [latinSample.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [latinSample.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [latinSample.topAnchor constraintEqualToAnchor:chineseCaption.bottomAnchor constant:12],
        [latinCaption.leadingAnchor constraintEqualToAnchor:latinSample.leadingAnchor],
        [latinCaption.trailingAnchor constraintEqualToAnchor:latinSample.trailingAnchor],
        [latinCaption.topAnchor constraintEqualToAnchor:latinSample.bottomAnchor constant:2],
        [clockSample.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [clockSample.topAnchor constraintEqualToAnchor:latinCaption.bottomAnchor constant:12],
        [clockCaption.leadingAnchor constraintEqualToAnchor:clockSample.leadingAnchor],
        [clockCaption.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [clockCaption.topAnchor constraintEqualToAnchor:clockSample.bottomAnchor constant:2],
        [clockCaption.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-14],
    ]];
    return header;
}

- (NSDictionary<NSString *, id> *)slotForIdentifier:(NSString *)slotID {
    for (NSDictionary<NSString *, id> *slot in self.slots) {
        if ([slot[@"slotID"] isEqual:slotID]) return slot;
    }
    return nil;
}

#pragma mark - Action dock

- (void)installFloatingActionDock {
    self.actionDock = [[FMFloatingActionDockView alloc] initWithFrame:CGRectZero];
    self.actionDock.translatesAutoresizingMaskIntoConstraints = NO;
    self.actionDock.userInteractionEnabled = YES;
    [self.view addSubview:self.actionDock];

    self.saveButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.saveButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.saveButton.accessibilityIdentifier = @"mix_save";
    UIButtonConfiguration *configuration =
        [UIButtonConfiguration filledButtonConfiguration];
    configuration.title = FMLocalized(@"保存混搭方案");
    configuration.image = [UIImage systemImageNamed:@"sparkles"];
    configuration.imagePadding = 7;
    configuration.cornerStyle = UIButtonConfigurationCornerStyleLarge;
    configuration.baseBackgroundColor = FMPrimaryActionColor();
    configuration.baseForegroundColor = FMPrimaryActionForegroundColor();
    self.saveButton.configuration = configuration;
    [self.saveButton addTarget:self action:@selector(saveMixTapped:)
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
        [self.saveButton.topAnchor constraintEqualToAnchor:self.actionDock.topAnchor
                                                  constant:14],
        [self.saveButton.heightAnchor constraintEqualToConstant:54],
        [self.saveButton.bottomAnchor
            constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-12],
    ]];
}

#pragma mark - Saving

- (void)saveMixTapped:(id)sender {
    (void)sender;
    if (self.saving || ![self hasAnyReplacement]) return;
    if (![self.workspace respondsToSelector:
            @selector(saveMixedProfileWithSlotAssignments:fallbackProfileID:profileName:error:)]) {
        return;
    }

    UIAlertController *nameAlert =
        [UIAlertController alertControllerWithTitle:FMLocalized(@"保存混搭方案")
                                            message:FMLocalized(@"为这次混搭起一个名字。")
                                     preferredStyle:UIAlertControllerStyleAlert];
    [nameAlert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = FMLocalized(@"混搭方案名称");
        textField.text = FMLocalized(@"我的混搭");
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    __weak typeof(self) weakSelf = self;
    [nameAlert addAction:[UIAlertAction actionWithTitle:FMLocalized(@"取消")
                                                  style:UIAlertActionStyleCancel
                                                handler:nil]];
    [nameAlert addAction:[UIAlertAction actionWithTitle:FMLocalized(@"保存")
                                                  style:UIAlertActionStyleDefault
                                                handler:^(__unused UIAlertAction *action) {
        [weakSelf saveMixNamed:nameAlert.textFields.firstObject.text];
    }]];
    [self presentViewController:nameAlert animated:YES completion:nil];
}

- (void)saveMixNamed:(NSString *)name {
    NSString *trimmed = [name stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length == 0 || trimmed.length > 80) {
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
    self.saving = YES;
    [self updateSaveButton];

    UIAlertController *progress =
        [UIAlertController alertControllerWithTitle:FMLocalized(@"正在保存混搭方案")
                                            message:FMLocalized(@"正在合并所选方案的字体文件…\n\n")
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

    NSDictionary<NSString *, NSString *> *slotAssignments = [self.slotAssignments copy];
    NSString *fallbackProfileID = self.fallbackProfileID;
    NSString *replacingProfileID = self.replacingProfileID;
    id<FMProfileWorkspace> workspace = self.workspace;
    __weak typeof(self) weakSelf = self;
    [self presentViewController:progress animated:YES completion:^{
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSError *error = nil;
            NSDictionary<NSString *, id> *saved =
                [workspace saveMixedProfileWithSlotAssignments:slotAssignments
                                              fallbackProfileID:fallbackProfileID
                                                     profileName:trimmed
                                                           error:&error];
            // The replaced mix Profile is obsolete once the new version
            // exists; deletion is refused by the workspace while it is active.
            if (saved != nil && replacingProfileID.length > 0) {
                [workspace deleteProfileID:replacingProfileID error:nil];
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) strongSelf = weakSelf;
                if (strongSelf == nil) return;
                strongSelf.saving = NO;
                [strongSelf updateSaveButton];
                [progress dismissViewControllerAnimated:YES completion:^{
                    if (saved == nil) {
                        UIAlertController *failure =
                            [UIAlertController alertControllerWithTitle:FMLocalized(@"暂时无法保存")
                                                                message:error.localizedDescription ?: FMLocalized(@"混搭方案没有写入字体库。")
                                                         preferredStyle:UIAlertControllerStyleAlert];
                        [failure addAction:[UIAlertAction actionWithTitle:FMLocalized(@"好")
                                                                   style:UIAlertActionStyleDefault
                                                                 handler:nil]];
                        [strongSelf presentViewController:failure animated:YES completion:nil];
                        return;
                    }
                    [[[UINotificationFeedbackGenerator alloc] init]
                        notificationOccurred:UINotificationFeedbackTypeSuccess];
                    [strongSelf presentSavedAlertForProfile:saved];
                }];
            });
        });
    }];
}

- (void)presentSavedAlertForProfile:(NSDictionary<NSString *, id> *)saved {
    NSUInteger count = [saved[@"replacementCount"] unsignedIntegerValue];
    UIAlertController *done =
        [UIAlertController alertControllerWithTitle:FMLocalized(@"混搭方案已存入字体库")
                                            message:[NSString stringWithFormat:FMLocalized(@"已合并 %lu 个字体文件。"), (unsigned long)count]
                                     preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [done addAction:[UIAlertAction actionWithTitle:FMLocalized(@"好")
                                             style:UIAlertActionStyleDefault
                                           handler:^(__unused UIAlertAction *action) {
        typeof(self) strongSelf = weakSelf;
        if (strongSelf == nil) return;
        [strongSelf.navigationController popToRootViewControllerAnimated:YES];
    }]];
    [self presentViewController:done animated:YES completion:nil];
}

#pragma mark - Table view

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return self.workspaceError != nil ? 1 : 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    if (self.workspaceError != nil) return 1;
    if (section == 0) return (NSInteger)self.slots.count;
    return 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    if (self.workspaceError != nil) return nil;
    return section == 0 ? FMLocalized(@"主要字体") : FMLocalized(@"其余字体（兜底）");
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    if (self.workspaceError != nil) return nil;
    if (section != 0) {
        return FMLocalized(@"以上没有覆盖到的全部字体，都会使用这里选择的方案。");
    }
    NSString *guidance = FMLocalized(
        @"为每个主要字体选择一个方案；方案未包含的文件会自动使用兜底方案。");
    NSDictionary<NSString *, id> *lockSlot =
        [self slotForIdentifier:FMFontSlotIdentifierLockScreen];
    if ([lockSlot[@"sharedStyleRelativePaths"] count] == 0) return guidance;
    return [NSString stringWithFormat:@"%@\n\n%@", guidance,
        FMLocalized(@"锁屏时间槽位会按当前系统匹配 ADTTime 或 ADTNumeric；SF Pro、圆角等共用系统英文字体的样式会跟随英文字体方案。")];
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"SlotCell"
                                                            forIndexPath:indexPath];
    UIListContentConfiguration *content = [UIListContentConfiguration subtitleCellConfiguration];

    if (self.workspaceError != nil) {
        content.text = FMLocalized(@"暂时无法读取字体库");
        content.secondaryText = self.workspaceError;
        content.image = [UIImage systemImageNamed:@"exclamationmark.triangle.fill"];
        content.imageProperties.tintColor = FMDangerColor();
    } else if (indexPath.section == 0) {
        NSDictionary<NSString *, id> *slot = self.slots[(NSUInteger)indexPath.row];
        content.text = slot[@"name"];
        content.image = [UIImage systemImageNamed:FMMixSlotSymbolName(slot[@"slotID"])];
        content.imageProperties.tintColor = FMAccentColor();
        NSDictionary<NSString *, id> *assigned = [self schemeAssignedToSlot:slot];
        NSUInteger total = [slot[@"relativePaths"] count];
        NSUInteger covered = [self coveredPathCountForSlot:slot];
        NSUInteger sharedStyleCovered = [self sharedStylePathCountForSlot:slot];
        if (assigned.count == 0) {
            content.secondaryText = FMLocalized(@"未选择 · 使用兜底方案");
        } else if (covered == 0 && sharedStyleCovered > 0) {
            content.secondaryText =
                FMLocalized(@"该方案仅含共享锁屏样式，请在英文字体中选择");
        } else if (covered == 0) {
            content.secondaryText = FMLocalized(@"该方案不含此字体，将使用兜底");
        } else if (covered < total) {
            content.secondaryText = [NSString
                stringWithFormat:FMLocalized(@"%@ · 部分文件使用兜底"), assigned[@"name"]];
        } else {
            content.secondaryText = assigned[@"name"];
        }
        cell.accessibilityIdentifier =
            [@"mix_slot_" stringByAppendingString:slot[@"slotID"]];
    } else {
        content.text = FMLocalized(@"兜底方案");
        content.image = [UIImage systemImageNamed:@"square.grid.2x2.fill"];
        content.imageProperties.tintColor = FMAccentColor();
        NSDictionary<NSString *, id> *fallback = [self fallbackScheme];
        content.secondaryText = fallback.count > 0
            ? fallback[@"name"]
            : FMLocalized(@"系统默认");
        cell.accessibilityIdentifier = @"mix_slot_fallback";
    }
    content.textProperties.font =
        [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    content.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    content.secondaryTextProperties.font =
        [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    cell.contentConfiguration = content;
    cell.accessoryType = self.workspaceError != nil
        ? UITableViewCellAccessoryNone
        : UITableViewCellAccessoryDisclosureIndicator;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.workspaceError != nil) return;
    NSDictionary<NSString *, id> *slot = nil;
    NSString *currentSelection = nil;
    if (indexPath.section == 0) {
        slot = self.slots[(NSUInteger)indexPath.row];
        currentSelection = self.slotAssignments[slot[@"slotID"]];
    } else {
        currentSelection = self.fallbackProfileID;
    }
    FMMixSchemePickerViewController *picker =
        [[FMMixSchemePickerViewController alloc] initWithSlot:slot
                                                      schemes:self.schemes
                                              currentSelection:currentSelection];
    __weak typeof(self) weakSelf = self;
    picker.selectionHandler = ^(NSString *_Nullable profileID) {
        typeof(self) strongSelf = weakSelf;
        if (strongSelf == nil) return;
        if (slot != nil) {
            if (profileID == nil) {
                [strongSelf.slotAssignments removeObjectForKey:slot[@"slotID"]];
            } else {
                strongSelf.slotAssignments[slot[@"slotID"]] = profileID;
            }
        } else {
            strongSelf.fallbackProfileID = profileID;
        }
        [[[UISelectionFeedbackGenerator alloc] init] selectionChanged];
        [strongSelf refreshInterface];
    };
    [self.navigationController pushViewController:picker animated:YES];
}

@end

#pragma mark - Scheme picker

@interface FMMixSchemePickerViewController ()
@property(nonatomic, strong) NSMutableArray<NSDictionary<NSString *, id> *> *pickerRows;
@end

@implementation FMMixSchemePickerViewController

- (instancetype)initWithSlot:(nullable NSDictionary<NSString *, id> *)slot
                     schemes:(NSArray<NSDictionary<NSString *, id> *> *)schemes
             currentSelection:(nullable NSString *)currentSelection {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self != nil) {
        _slot = [slot copy];
        _schemes = [schemes copy];
        _currentSelection = [currentSelection copy];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.slot != nil
        ? [NSString stringWithFormat:FMLocalized(@"选择方案 · %@"), self.slot[@"name"]]
        : FMLocalized(@"选择兜底方案");
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.tableView.backgroundColor = FMCanvasColor();
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 60;
    self.tableView.accessibilityIdentifier = @"mix_scheme_picker";
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"SchemeCell"];

    self.pickerRows = [NSMutableArray array];
    [self.pickerRows addObject:@{
        @"id" : NSNull.null,
        @"name" : self.slot != nil ? FMLocalized(@"不单独选择 · 使用兜底方案")
                                   : FMLocalized(@"系统默认"),
    }];
    [self.pickerRows addObjectsFromArray:self.schemes];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return (NSInteger)self.pickerRows.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return self.slot != nil ? nil : FMLocalized(@"其余字体使用这里选择的方案");
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    if (self.slot == nil) {
        return FMLocalized(@"选择「系统默认」时，未覆盖的字体保持本机原生内容。");
    }
    NSString *guidance =
        FMLocalized(@"所选方案未包含的槽位文件，会使用兜底方案。");
    if ([self.slot[@"sharedStyleRelativePaths"] count] == 0) return guidance;
    return [NSString stringWithFormat:@"%@\n\n%@", guidance,
        FMLocalized(@"锁屏时间槽位会按当前系统匹配 ADTTime 或 ADTNumeric；SF Pro、圆角等共用系统英文字体的样式会跟随英文字体方案。")];
}

- (NSString *)pickerCoverageSummaryForScheme:(NSDictionary<NSString *, id> *)scheme {
    if (self.slot != nil) {
        NSUInteger covered = 0;
        NSUInteger total = [self.slot[@"relativePaths"] count];
        for (NSString *relativePath in self.slot[@"relativePaths"]) {
            if ([scheme[@"paths"] containsObject:relativePath]) covered++;
        }
        if (total == 0) return FMLocalized(@"该槽位在当前系统不可用");
        if (covered == 0 &&
            FMMixCoveredPathCount(scheme,
                                  self.slot[@"sharedStyleRelativePaths"]) > 0) {
            return FMLocalized(@"仅含共享锁屏样式 · 由英文字体控制");
        }
        if (covered == 0) return FMLocalized(@"不含此槽位字体");
        return [NSString stringWithFormat:FMLocalized(@"包含 %lu/%lu 个槽位文件"),
                (unsigned long)covered, (unsigned long)total];
    }
    NSUInteger count = [scheme[@"paths"] count];
    return [NSString stringWithFormat:FMLocalized(@"共 %lu 个字体文件"), (unsigned long)count];
}

- (BOOL)schemeRowIsSelectable:(NSDictionary<NSString *, id> *)row {
    if (![row[@"id"] isKindOfClass:NSString.class] || self.slot == nil) return YES;
    return FMMixCoveredPathCount(row, self.slot[@"relativePaths"]) > 0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"SchemeCell"
                                                            forIndexPath:indexPath];
    NSDictionary<NSString *, id> *row = self.pickerRows[(NSUInteger)indexPath.row];
    UIListContentConfiguration *content = [UIListContentConfiguration subtitleCellConfiguration];
    BOOL isNullRow = ![row[@"id"] isKindOfClass:NSString.class];
    BOOL selectable = [self schemeRowIsSelectable:row];
    if (isNullRow) {
        content.text = row[@"name"];
        content.image = [UIImage systemImageNamed:self.slot != nil
            ? @"arrow.triangle.branch" : @"checkmark.shield.fill"];
        content.imageProperties.tintColor = UIColor.secondaryLabelColor;
        cell.accessibilityIdentifier = self.slot != nil
            ? @"mix_pick_use_fallback"
            : @"mix_pick_use_stock";
    } else {
        NSString *name = row[@"name"];
        if ([row[@"isMix"] boolValue]) {
            name = [NSString stringWithFormat:FMLocalized(@"%@ · 混搭"), name];
        }
        content.text = name;
        content.secondaryText = [self pickerCoverageSummaryForScheme:row];
        content.image = [UIImage systemImageNamed:@"doc.text.fill"];
        content.imageProperties.tintColor = FMAccentColor();
        UIFont *previewFont = FMPreviewFontAtPath(row[@"previewLatinFontPath"], 17)
            ?: FMPreviewFontAtPath(row[@"previewFontPath"], 17);
        if (previewFont != nil) content.textProperties.font = previewFont;
        cell.accessibilityIdentifier =
            [@"mix_pick_" stringByAppendingString:row[@"id"]];
    }
    content.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    content.secondaryTextProperties.font =
        [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    cell.contentConfiguration = content;
    NSString *rowID = isNullRow ? @"" : row[@"id"];
    NSString *selectedID = self.currentSelection ?: @"";
    cell.accessoryType = selectable && [rowID isEqual:selectedID]
        ? UITableViewCellAccessoryCheckmark
        : UITableViewCellAccessoryNone;
    cell.selectionStyle = selectable
        ? UITableViewCellSelectionStyleDefault
        : UITableViewCellSelectionStyleNone;
    cell.contentView.alpha = selectable ? 1.0 : 0.55;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary<NSString *, id> *row = self.pickerRows[(NSUInteger)indexPath.row];
    if (![self schemeRowIsSelectable:row]) return;
    FMMixSelectionHandler handler = self.selectionHandler;
    NSString *profileID = [row[@"id"] isKindOfClass:NSString.class] ? row[@"id"] : nil;
    [self.navigationController popViewControllerAnimated:YES];
    if (handler != nil) handler(profileID);
}

@end
