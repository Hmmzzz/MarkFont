# MarkFont

MarkFont 是一款面向 rootless 与 RootHide 环境的 iOS 全局字体管理器，可在 App 内导入字体、管理字体方案并切换系统字体。

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
- 沿用 `/bindfs/System/Library/Fonts`，并支持安全接管旧版字体目录
- 不依赖 `com.nan.bindfs`、`mount_bindfs` 或 `dash`
- 按当前设备的 Stock 字体树动态生成文件清单，不硬编码 iOS 版本或字体文件名

## Compatibility

- iOS 16.0+
- conventional rootless（例如 Dopamine）或 RootHide（例如 Relaxin）
- `arm64` and `arm64e`

既有发布版已在 iPhone 15 Pro、iOS 17.3.1（21D61）和 Relaxin 0.4.2 上验证。
iOS 16 rootless 与其他 RootHide 组合需要分别使用对应 scheme 的软件包；未列出的设备与
越狱组合仍应视为尚未完成实机验证。

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
文件权限和 launchd 配置。请勿在两种环境间混装软件包。

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
