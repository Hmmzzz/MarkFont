#import "FMCoordinatorFixtures.h"

static NSDictionary<NSString *, id> *FMFixtureInspection(
    NSString *mirrorKind,
    BOOL mappingActive,
    BOOL mappingValid,
    NSString *scanState,
    NSString *manifestBuild,
    NSInteger stockCount,
    NSInteger mirrorCount,
    NSArray<NSString *> *changedPaths,
    NSArray<NSString *> *missingPaths,
    NSArray<NSString *> *unknownPaths,
    NSArray<NSString *> *typeChangedPaths,
    BOOL statePresent,
    BOOL stateValid,
    NSString *stateBuild,
    NSString *mirrorState,
    BOOL matchesWorkingProfile) {
    return @{
        @"schemaVersion" : @4,
        @"evidenceMode" : @"simulatorFixture",
        @"systemBuild" : @"21D61",
        @"mountBackend" : @{
            @"identifier" : @"markfont-bindfs",
            @"version" : @"1",
            @"executablePresent" : @YES,
            @"runtimeLibraryPresent" : @YES,
            @"runtimeLibrarySecure" : @YES,
            @"contractVersion" : @1,
            @"recognition" : @"known",
            @"compatibility" : @"compatible",
            @"compatible" : @YES,
            @"executableSecure" : @YES,
            @"machOExecutable" : @YES,
            @"supportsReadOnlyMount" : @YES,
            @"supportsForceUnmount" : @YES,
            @"storageSupported" : @YES,
            @"legacyProviderPreferencePresent" : @NO,
            @"legacyProviderAutoMountConflictsWithFonts" : @NO,
        },
        @"fonts" : @{
            @"systemReadable" : @YES,
            @"rootfsReadable" : @YES,
            @"mirrorKind" : mirrorKind,
            @"mirrorInsideJBRoot" : @YES,
            @"rootfsDistinctFromMirror" : @YES,
        },
        @"mapping" : @{
            @"active" : @(mappingActive),
            @"targetMatches" : @(mappingValid),
            @"sourceMatchesMirror" : @(mappingValid),
            @"readOnly" : @(mappingValid),
            @"filesystemType" : mappingActive ? @"bindfs" : NSNull.null,
        },
        @"manifest" : @{
            @"scanState" : scanState,
            @"systemBuild" : manifestBuild,
            @"stockEntryCount" : @(stockCount),
            @"mirrorEntryCount" : @(mirrorCount),
            @"changedPaths" : changedPaths,
            @"missingPaths" : missingPaths,
            @"unknownPaths" : unknownPaths,
            @"typeChangedPaths" : typeChangedPaths,
            @"matchesWorkingProfile" : @(matchesWorkingProfile),
        },
        @"state" : @{
            @"present" : @(statePresent),
            @"valid" : @(stateValid),
            @"systemBuild" : statePresent ? stateBuild : NSNull.null,
            @"mirrorState" : mirrorState,
        },
    };
}

static NSDictionary<NSString *, id> *FMFixture(NSString *identifier,
                                                NSString *name,
                                                NSString *summary,
                                                NSString *expectedClassification,
                                                NSDictionary *inspection) {
    return @{
        @"id" : identifier,
        @"name" : name,
        @"summary" : summary,
        @"expectedClassification" : expectedClassification,
        @"inspection" : inspection,
    };
}

NSArray<NSDictionary<NSString *, id> *> *FMCoordinatorFixtures(void) {
    NSDictionary *empty = FMFixtureInspection(
        @"missing", NO, NO, @"notApplicable", @"21D61", 0, 0,
        @[], @[], @[], @[], NO, NO, @"", @"none", NO);
    NSDictionary *stockUnmounted = FMFixtureInspection(
        @"present", NO, NO, @"complete", @"21D61", 842, 842,
        @[], @[], @[], @[], NO, NO, @"", @"none", NO);
    NSDictionary *stockMounted = FMFixtureInspection(
        @"present", YES, YES, @"complete", @"21D61", 842, 842,
        @[], @[], @[], @[], NO, NO, @"", @"none", NO);
    NSDictionary *manual = FMFixtureInspection(
        @"present", NO, NO, @"complete", @"21D61", 842, 842,
        @[ @"CoreUI/SFUI.ttf", @"LanguageSupport/PingFang.ttc" ],
        @[], @[], @[], NO, NO, @"", @"none", NO);
    NSDictionary *manualMounted = FMFixtureInspection(
        @"present", YES, YES, @"complete", @"21D61", 842, 842,
        @[ @"CoreUI/SFUI.ttf", @"LanguageSupport/PingFang.ttc" ],
        @[], @[], @[], NO, NO, @"", @"none", NO);
    NSDictionary *incomplete = FMFixtureInspection(
        @"present", NO, NO, @"incomplete", @"21D61", 842, 841,
        @[], @[ @"CoreUI/SFUI.ttf" ], @[], @[], NO, NO, @"", @"none", NO);
    NSDictionary *unknownFile = FMFixtureInspection(
        @"present", NO, NO, @"incomplete", @"21D61", 842, 843,
        @[], @[], @[ @"ManualBackup/unknown.ttf" ], @[], NO, NO, @"", @"none", NO);
    NSDictionary *buildMismatch = FMFixtureInspection(
        @"present", NO, NO, @"complete", @"21C62", 842, 842,
        @[], @[], @[], @[], NO, NO, @"", @"none", NO);
    NSDictionary *unexpectedMapping = FMFixtureInspection(
        @"present", YES, NO, @"complete", @"21D61", 842, 842,
        @[], @[], @[], @[], NO, NO, @"", @"none", NO);
    NSDictionary *ready = FMFixtureInspection(
        @"present", YES, YES, @"complete", @"21D61", 842, 842,
        @[ @"CoreUI/SFUI.ttf" ], @[], @[], @[], YES, YES, @"21D61", @"clean", YES);
    NSDictionary *managedInactive = FMFixtureInspection(
        @"present", NO, NO, @"complete", @"21D61", 842, 842,
        @[ @"CoreUI/SFUI.ttf" ], @[], @[], @[], YES, YES, @"21D61", @"clean", YES);
    NSDictionary *repair = FMFixtureInspection(
        @"present", YES, YES, @"complete", @"21D61", 842, 842,
        @[ @"CoreUI/SFUI.ttf" ], @[], @[], @[], YES, YES, @"21D61",
        @"repairRequired", NO);

    return @[
        FMFixture(@"empty", @"还没有字体镜像", @"可以从系统字体创建第一份安全副本。",
                  @"initializeEmptyMirror", empty),
        FMFixture(@"stock-unmounted", @"已有完整系统副本",
                  @"可以接管现有文件，无需重复复制。",
                  @"adoptStockMirror", stockUnmounted),
        FMFixture(@"stock-mounted", @"系统副本已经挂载",
                  @"可以直接接管当前状态，不重复操作。", @"adoptStockMirror", stockMounted),
        FMFixture(@"manual", @"发现手动替换的字体",
                  @"先保存为字体方案，避免丢失已有改动。",
                  @"adoptManualChanges", manual),
        FMFixture(@"manual-mounted", @"手动字体正在使用",
                  @"保留当前字体和挂载关系，不重复操作。",
                  @"adoptManualChanges", manualMounted),
        FMFixture(@"incomplete", @"字体文件不完整",
                  @"保持只读，先补齐缺失文件。", @"blocked", incomplete),
        FMFixture(@"unknown", @"发现未识别文件",
                  @"保持只读，不自动删除。", @"blocked", unknownFile),
        FMFixture(@"build-mismatch", @"系统版本已经变化",
                  @"旧的系统字体基线需要重新确认。", @"blocked", buildMismatch),
        FMFixture(@"mapping-mismatch", @"挂载关系不一致",
                  @"来源或目标不符合预期时停止继续。", @"blocked",
                  unexpectedMapping),
        FMFixture(@"ready", @"字体环境已经就绪",
                  @"所有检查均通过，无需处理。", @"managedReady", ready),
        FMFixture(@"managed-inactive", @"已验证字体等待重新挂载",
                  @"只恢复现有只读映射，不复制或改写字体。",
                  @"managedInactive", managedInactive),
        FMFixture(@"repair", @"上次操作没有完成",
                  @"完成恢复前不会继续替换文件。", @"blocked", repair),
    ];
}
