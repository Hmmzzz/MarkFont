# MarkFont 本地测试

`tests/` 自 commit `203a55c` 起随当前仓库提交，不再是 `.git/info/exclude` 中的本机资产。
套件只编译当前 `markfont/shared` 与 `markfont/tests`，不会调用或修改历史
`tweaks/font-manager` 仓库。

## 运行

从当前仓库执行：

```bash
./tests/run
```

也可以从越狱开发工作区根目录执行等价入口：

```bash
./scripts/jb-build test
```

调用链固定为：

```text
markfont/tests/run
  -> ../../scripts/jb-env
  -> xcrun clang + 当前 markfont/shared
  -> 当前 markfont/tests
```

runner 需要 macOS/Xcode、`rg`，以及本地工作区的 `../../scripts/jb-env`。它在 `/tmp`
创建独立构建目录并在退出时清理，不连接设备、不部署 package，也不执行 Respring 或 reboot。

## 覆盖范围

当前套件包含 16 个 Objective-C 测试程序，覆盖：

- state/baseline schema、原子文件写入、tree manifest 与 operation lock；
- iOS 16–26 先确认版本再选择 build-specific 字体目录、旧 Fonts 与新版 FontServices 双来源清单、
  `PingFang.ttc` / `PingFangUI.ttc` 大小写敏感的精确同名选择与跨名拒绝、字体包解析、受控导入会话和
  Profile 持久化；
- Profile adoption、stage、Stock mirror、legacy takeover 与中断恢复；
- mount/backend compatibility、auto-mount、自动 Respring 和 restart evidence；
- secure directory、helper/CLI/App 权限边界，以及 package lifecycle 的静态契约。

截至未发布的 `0.3.3` 候选，正常宿主权限下完整运行输出 39 条 `PASS`。受控导入用例会通过
`NSFileCoordinator` 读取当前用户的临时目录；极严格的自动化 sandbox 可能在这一步返回
`NSCocoaErrorDomain Code=256`。这种情况下应在普通终端或允许该临时目录文件协调的环境中
重跑，以区分执行环境限制与真实产品回归。

## Package audit

宿主测试不代替 `.deb` 审计。分别构建两种 scheme 时，专用 target 会自动调用
`scripts/verify-package`：

```bash
make package-roothide
make package-rootless

# 审计已有包
./scripts/verify-package packages/<markfont.deb>
```

审计会检查 scheme 布局、版本/metadata、四个 Mach-O 的 `arm64 + arm64e` slices、iOS 16.0
minimum OS、linking/rpath、entitlements、helper/backend 权限和 launchd argv。
