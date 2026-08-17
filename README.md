# MarkFont

MarkFont 是一款面向 iOS 16–26 越狱设备的全局字体管理器，支持 conventional rootless 与
RootHide。它将字体应用到与当前系统 build 绑定的工作镜像，再通过只读 bindfs mapping 提供给
系统，不直接覆盖原始系统字体文件。

当前版本为 [`v0.3.5`](https://github.com/Hmmzzz/MarkFont/tree/v0.3.5)，可从
[Hmmzzz 软件源](https://hmmzzz.github.io/repo/)安装。两种越狱环境使用不同软件包，请勿混装。

## 截图

<p align="center">
  <img src="screenshots/home.png" width="45%" alt="MarkFont home screen">
  <img src="screenshots/font-library.png" width="45%" alt="MarkFont font library">
</p>

## 功能

- 导入 ZIP、TTF、TTC 或 OTF，按当前设备的 Stock 字体清单预览精确匹配结果
- 保存、预览、切换和删除多套字体方案，或恢复系统默认字体
- 使用固定路径的只读字体镜像，不直接修改 `/System` 中的原始字体文件
- 重新越狱后自动恢复受管理的 mapping；可选仅在挂载晚于 SpringBoard 时自动 Respring 一次
- 在 App 内检查组件、字体连接和恢复准备状态
- 支持简体中文、英文及跟随系统语言

## 兼容性

| Package scheme | 适用环境 | `.deb` Architecture | Runtime prefix |
| --- | --- | --- | --- |
| `rootless` | conventional rootless（如 Dopamine） | `iphoneos-arm64` | `/var/jb` |
| `roothide` | RootHide（如 Relaxin） | `iphoneos-arm64e` | `/` |

- 支持 iOS 16.0–26.x；其他版本会安全拒绝，而不是猜测字体布局。
- 不支持 rootful，也不支持在两种 package scheme 之间混装。
- App、helper、mount backend 和 CLI 均包含 `arm64` 与 `arm64e` slices。
- 软件包依赖 `uikittools`，并与旧的外部挂载包 `com.nan.bindfs`、`cn.zqbb.hello.mnt` 冲突。
- 内置后端使用越狱环境提供的 `/basebin/libjailbreak.dylib`，不依赖 `mount_bindfs` 或 `dash`。

> 兼容范围代表当前代码策略，不代表所有设备与越狱版本都已完成实机矩阵验证。维护基线为
> iPhone 15 Pro、iOS 17.3.1、Relaxin 0.4.2 / RootHide；iOS 18 中文字体路径已有实机反馈，
> iOS 16 conventional rootless 与其他组合仍欢迎社区验证。`v0.3.5` 的文件选择器修复已通过
> 回归和双包审计，开启“粗体文本”的实机复测仍待完成。

### 中文字体规则

MarkFont 会先校验 `ProductVersion` 与 `ProductBuildVersion`，再选择当前系统唯一允许的中文目标：

| 系统版本 | 导入文件名 | 系统目标 |
| --- | --- | --- |
| iOS 16–17 | `PingFang.ttc` | `/System/Library/Fonts/LanguageSupport/PingFang.ttc` |
| iOS 18–26 | `PingFangUI.ttc` | `/System/Library/PrivateFrameworks/FontServices.framework/CorePrivate/PingFangUI.ttc` |

匹配区分大小写且只接受同名文件，不会在 `PingFang.ttc` 与 `PingFangUI.ttc` 之间跨名替换。
字体包同时包含两者时，只使用当前系统对应的一份。由 `v0.3.2` 或更早版本保存的字体方案不会在
升级后自动重新分析；请用当前版本重新选择原字体包并保存为新方案。

## 安装与安全

在支持的软件包管理器中添加 [`https://hmmzzz.github.io/repo/`](https://hmmzzz.github.io/repo/)，
然后安装与当前越狱环境匹配的 MarkFont 软件包。

字体不完整或与系统不兼容可能导致文字空白或界面不可用。安装和切换前，请确认能够进入当前越狱
的 safe mode 并通过软件包管理器移除 MarkFont。不要手动修改系统字体目录，也不要强制删除
MarkFont 的 Stock 快照、镜像或恢复数据。

## 实现边界

- `fontmanagerd` 是受限的 root helper，只接受固定的字体生命周期操作。
- `markfont-bindfs` 只接受 `probe`、`mount-fonts` 和 `force-unmount-fonts`，source、target 与
  flags 均固定在二进制内；bindfs entitlement 仅存在于这个隔离后端。
- Profile 与 Stock 快照绑定当前系统 build；系统更新后不会把旧方案盲目应用到新字体布局。
- launchd 自动挂载只恢复已验证、干净且可恢复的工作镜像。

## 构建

需要 macOS/Xcode、[RootHide Theos](https://github.com/roothide/theos)、兼容的 iOS SDK、
`ldid` 与 `rg`。

```bash
git clone https://github.com/Hmmzzz/MarkFont.git
cd MarkFont
export THEOS=/path/to/roothide-theos

make package-roothide
make package-rootless
# 或依次构建两种软件包
make package-all
```

开发构建默认保留调试信息。生成的 `.deb` 位于 `packages/`；上述目标会自动调用
`scripts/verify-package` 检查 scheme 布局、Mach-O slices、最低系统版本、linking、entitlements、
文件权限和 launchd 配置。也可以单独审计已有软件包：

```bash
./scripts/verify-package packages/<markfont.deb>
```

## 测试

在本项目所属开发工作区中运行：

```bash
./tests/run
```

独立 clone 在已配置好 macOS/Xcode 环境后可跳过本机工作区包装器：

```bash
MARKFONT_LOCAL_TEST_ENV_READY=1 ./tests/run
```

测试只在宿主机编译和运行，不会连接设备、部署软件包、切换字体、Respring 或 reboot。覆盖范围和
sandbox 注意事项见 [`tests/README.md`](tests/README.md)。宿主测试不能代替两种 `.deb` 的独立审计。

## 目录结构

| 路径 | 内容 |
| --- | --- |
| `app/` | UIKit App 与本地化资源 |
| `shared/` | Profile、Stock、匹配、挂载和恢复核心 |
| `daemon/` | 受限 root helper |
| `bindfs/` | 固定命令的隔离挂载后端 |
| `cli/` | 状态与维护 CLI |
| `layout/` | launchd 与 Debian package lifecycle |
| `scripts/`、`tests/` | 双包构建审计与宿主回归 |

## 参与贡献

欢迎提交 issue 和 pull request。功能改动请运行宿主回归；涉及路径、权限、package lifecycle 或
scheme 的改动还应分别构建并审计 rootless 与 RootHide 软件包。请勿提交 `.theos/`、`packages/`、
`.deb`、设备数据、密钥或其他本机产物。

## 致谢

- [RootHide](https://github.com/roothide/Developer)：RootHide 架构与兼容基础
- [Theos](https://theos.dev/)：iOS 越狱开发与打包工具链
- [Dopamine](https://github.com/opa334/Dopamine)：`libjailbreak` 挂载能力接口参考
- [Relaxin](https://relaxin.owngoal.dev/)：当前维护基线使用的越狱环境

第三方许可见 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。

## 字体许可与免责声明

MarkFont 不提供、销售、授权、审核或分发第三方字体。用户应自行确认拥有导入、使用、复制或分发
字体所需的权利；本项目的 GPL 许可不授予任何第三方字体权利。

本软件按“现状”提供，不作任何担保。项目维护者与贡献者不对未经授权使用字体，或字体兼容性、
不当操作造成的设备异常、数据丢失和系统不稳定负责；完整条款见 GPLv3 第 15、16 条。

## 许可证

Copyright (C) 2026 Hmmzzz.

Licensed under the [GNU General Public License v3.0 only](LICENSE).
