# MarkFont

MarkFont 是一款面向 rootless 与 RootHide 环境的 iOS 全局字体管理器，可在 App 内导入字体、管理字体方案并切换系统字体。

## Current Status

当前最新正式版本为 `v0.3.5`（2026-08-14）。`v0.3.0` 将最低系统版本降至 iOS 16.0，
增加 conventional rootless / RootHide 双 scheme 构建，并补上重新越狱时对 clean pending
Profile mirror 的安全恢复；`v0.3.1` 进一步修复 conventional rootless 下随机 App data
container 导致的 Profile 激活和卸载清理问题，同时把本地回归套件纳入仓库。`v0.3.3` 新增
iOS 18–26 的真实 FontServices/CorePrivate 字体目录支持，并按已确认系统版本严格区分
`PingFang.ttc` 与 `PingFangUI.ttc`，不再进行跨文件名替换。`v0.3.5` 将导航栏外观限制在
MarkFont 自有界面，避免全局外观设置干扰系统文件选择器，并移除了关闭“粗体文本”的临时规避提示。

`v0.3.5` 的 `iphoneos-arm64`（conventional rootless）与 `iphoneos-arm64e`（RootHide）
正式包均已通过宿主回归和本机 package audit。2026-08-09，维护基线设备已由用户安装过 RootHide
`0.3.3-4+debug` 候选；只读回归确认 iOS 17.3.1 仍选择旧版单目录、`PingFang.ttc` catalog
与单一 mapping 策略，且 Profile/Stock preflight、状态和自动挂载回执正常。SSH 会话读取已挂载
目标目录时仍出现内容为空的矛盾证据，且本轮未获授权执行重挂载、Respring 或 reboot，因此这不表示
所有 jailbreak 组合或该设备的完整运行闭环均已验证。`v0.3.5` 的文件选择器修复尚待开启
“粗体文本”的实机复测，发布前验证范围为源码审阅、宿主回归和双 scheme package audit。

未发布的 `0.3.2` 只补了中文文件名匹配，但仍把 iOS 18–26 的 `PingFangUI.ttc` 假定在旧
`/System/Library/Fonts` 树中，因此安装后仍会提示本机没有同名目标。`v0.3.3` 改为管理真实
FontServices 目录，并移除了跨文件名替换。2026-08-09，用户反馈该实现已在 iOS 18 实机测试通过；
设备 build、越狱版本、所装包摘要及
Stock restore / 重新越狱 auto-mount 等分项证据尚未独立归档，因此不能外推为全部 iOS 18–26
组合均已验证。

## Screenshots

<p align="center">
  <img src="screenshots/home.png" width="45%" alt="MarkFont home screen">
  <img src="screenshots/font-library.png" width="45%" alt="MarkFont font library">
</p>

## Features

- 支持 ZIP、TTF、TTC 和 OTF 字体导入
- 支持多字体方案管理与快速切换
- 支持恢复系统默认字体
- 内置固定路径、只读的 bindfs 挂载后端，避免直接修改 iOS 系统字体文件
- 支持重新越狱后自动恢复字体 mapping
- iOS 16–17 固定沿用 `/bindfs/System/Library/Fonts`；iOS 18–26 通过版本门槛后增加独立的
  `/bindfs/System/Library/PrivateFrameworks/FontServices.framework/CorePrivate` 只读镜像
- 不依赖 `com.nan.bindfs`、`mount_bindfs` 或 `dash`
- 先精确确认当前 `ProductVersion` / `ProductBuildVersion`，再验证对应路径的真实 Stock 文件

## Compatibility

- iOS 16.0–26.x
- conventional rootless（例如 Dopamine）或 RootHide（例如 Relaxin）
- `arm64` and `arm64e`

RootHide 主线的 App、只读 mapping 与内置后端链路已在 iPhone 15 Pro、iOS 17.3.1
（21D61）和 Relaxin 0.4.2 上逐步验证。iOS 16 conventional rootless 与其他 RootHide
组合需要分别使用对应 scheme 的软件包；`v0.3.5` 尚未在这些组合上逐一完成实机部署，
未列出的设备与越狱组合也应视为尚未验证。

中文字体目标先由 root helper 确认当前系统版本与 build，再从对应的 build-specific Stock
清单选择；版本和真实文件布局必须同时一致：

- iOS 14–17 使用 `/System/Library/Fonts/LanguageSupport/PingFang.ttc`
  （MarkFont 当前最低支持 iOS 16）；
- iOS 18–26 使用
  `/System/Library/PrivateFrameworks/FontServices.framework/CorePrivate/PingFangUI.ttc`；
- iOS 16–17 不探测、不创建也不挂载 FontServices 工作区；iOS 18–26 如果精确路径或文件缺失，
  会直接失败，不回退套用旧路径；
- 字体包同时包含两者时，选择与当前 Stock 同名的文件，另一份作为其他系统版本忽略；
- 字体包缺少当前 Stock 同名文件、只包含另一名称时，不做跨名写入，并明确作为其他系统
  版本文件忽略；
- `PingFang.ttc` 与 `PingFangUI.ttc` 不是别名或兜底来源：被忽略项不携带 target ID/path，
  不会生成 replacement，也不能把其中一份内容写到另一文件名的系统目标。

该规则同时用于字体包导入和“系统默认”中文预览。iOS 18–26 首次应用包含
`PingFangUI.ttc` 的 Profile 时，helper 会在同一引擎锁内创建并验证第二份 Stock 快照和镜像，
再由固定后端建立两个精确只读 mapping；Profile 不会在旧 Fonts 镜像里伪造新版目标路径。

已经由旧版本导入的 Profile 不会在 App 升级时自动重新分析，因为 MarkFont 只保留已选中的
replacement，不保留原始字体包。安装 `0.3.3` 或更高版本后，需要重新选择原字体包并另存为一个新 Profile，
再检查导入预览中的中文匹配结果；只打开或再次应用旧 Profile 不会补回此前漏掉的中文文件。

## Tests

仓库提交了 16 个宿主侧测试程序和一组实现边界检查：

```bash
./tests/run
```

当前 runner 通过本地越狱开发工作区的 `../../scripts/jb-env` 固定 Xcode/工具链环境，
详细覆盖范围和独立 package audit 命令见 [`tests/README.md`](tests/README.md)。测试不会连接
设备，也不会执行字体切换、Respring、reboot 或 package 部署。

## Build

需要安装 [RootHide Theos](https://github.com/roothide/theos)（保持与 Theos rootless scheme
兼容）及兼容的 iOS SDK。

```bash
export THEOS=/path/to/roothide-theos

# 分别构建
make package-roothide
make package-rootless

# 或一次生成两种包
make package-all
```

两种 `.deb` 都位于 `packages/`：RootHide 包架构为 `iphoneos-arm64e`，conventional
rootless 包架构为 `iphoneos-arm64`。上述专用构建目标会在打包后自动运行
`scripts/verify-package`，检查路径布局、Mach-O 架构与最低系统版本、linking、entitlements、
文件权限和 launchd 配置。普通开发构建保持 `DEBUG=1`；Theos 生成的正整数 build number
（例如 `0.3.5-1+debug`、`0.3.5-2+debug`）属于合法候选版本。只有明确进入发布流程时才改用
release 构建参数。请勿在两种环境间混装软件包。

## Warning

字体文件不完整或与系统不兼容可能导致文字空白或界面不可用。安装前请确保你能够进入
当前越狱的 safe mode 并移除软件包。请勿强制删除 MarkFont 的恢复数据或手动修改系统字体目录。

## Acknowledgements

- [RootHide](https://github.com/roothide/Developer)：提供 RootHide 架构与兼容基础
- [Theos](https://theos.dev/)：提供 iOS 越狱开发与打包工具链
- [Dopamine](https://github.com/opa334/Dopamine)：提供 `libjailbreak` 挂载能力接口设计参考
- [Relaxin](https://relaxin.owngoal.dev/)：提供本项目当前适配与测试的越狱环境

第三方许可见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## Disclaimer

MarkFont 仅提供字体管理功能，不提供、销售、授权或分发任何第三方字体文件。字体文件、
字形设计、字体名称及相关内容可能受到版权、商标、字体许可或其他权利保护。用户在导入、
安装、使用、复制或分发任何字体前，应自行确认已取得必要授权，并遵守字体许可与适用法律。

用户导入的字体由用户自行选择和获取，项目维护者与贡献者不审核其来源或授权状态。在适用
法律允许的最大范围内，项目维护者与贡献者不对用户未经授权或违法使用字体所引起的侵权主张、
损失或其他责任负责，也不对字体兼容性或不当操作造成的设备异常、数据丢失或系统不稳定负责。

MarkFont 的 `GPL-3.0-only` 许可仅适用于本项目软件，不授予任何第三方字体的使用或分发权利。
本软件按“现状”提供，不作任何担保；完整的无担保及责任限制条款见 [GPLv3 第 15、16 条](LICENSE)。
如不确定某款字体的许可范围，请在使用前向字体权利人或专业人士确认。

## License

Copyright (C) 2026 Hmmzzz.

Licensed under the [GNU General Public License v3.0 only](LICENSE).
