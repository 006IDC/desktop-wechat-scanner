# 桌面微信扫码 · 开源预览版

在 Mac 上镜像和操作 Android 手机，把窗口后方的电脑二维码送给真实手机微信扫一扫。

**这是实验性预览版，拖动和打开扫一扫仍有明显卡顿，尚未达到 iPhone 镜像式流畅体验。** 适合愿意测试和参与开发的用户，不建议用于重要登录、支付或生产操作。

[下载安装包](https://github.com/006IDC/desktop-wechat-scanner/releases/tag/v0.3.2-preview.1) · [安装说明](docs/INSTALL.md) · [版本记录](CHANGELOG.md)

## 版本概览

- 发布版本：`v0.3.2-preview.1`（App 0.3.2 / build 11），2026-10-25。
- Mac：Apple Silicon（M 系列），macOS 14.4 或更高；不提供 Intel 包。
- 手机：Android 16；曾在小米 HyperOS / 微信 8.0.79 验证基础镜像和合成二维码识别，其他机型、系统和微信版本尚未验证。
- 连接：仅 USB。无线配对、音频、剪贴板同步和电脑键盘输入未实现。
- 签名：本地 ad-hoc 签名，未使用 Apple Developer ID、未公证；安装可能被 Gatekeeper 拦截，处理方式见安装说明。

## 主要功能

- 原生 macOS 手机比例窗口，显示真实 Android 屏幕。
- 鼠标点击、滑动、滚动、返回、主屏幕与微信快捷入口。
- 打开微信扫一扫后，通过临时虚拟显示/相机，把窗口后方桌面图发送给手机微信识别。
- 识别结果来自真实微信，后续登录、授权和支付由用户决定。
- 断开或退出时清理本应用创建的临时连接；中断遗留会在下次连接时尝试恢复。

## 使用与升级

1. 下载 DMG，将“桌面微信扫码.app”拖入“应用程序”；ZIP 用户先解压，再移动 App。
2. 安装 [Google 官方 Platform-Tools](https://developer.android.com/tools/releases/platform-tools) 并解压。本发行包不包含 adb。首次点连接时可以直接选择解压目录中的 `adb`，无需运行终端命令；已有常见 SDK/Homebrew 安装可被自动发现。
3. 手机启用开发者选项与 USB 调试，通过数据线连接、解锁，并在手机上允许此 Mac 调试。部分小米系统还需要允许 USB 调试安全设置；无需 Root。
4. App 点连接，进入微信“＋ → 扫一扫”，或点工具栏扫码图标。按提示授予本 App 屏幕录制权限并重启。
5. 拖动**窗口标题栏**覆盖电脑上的二维码。普通页面使用手机主屏镜像；扫码时微信任务会暂时迁到同一手机的虚拟显示，手机物理屏与 Mac 可能不同。结果页会尝试移回物理屏。
6. 完成后断开或退出，等待清理，再拔线。升级前先退出旧版本，再替换 App；ad-hoc 签名变更可能要求重新授权录屏。

不要把窗口拖到含有不打算交给微信识别的信息上。查看 [隐私与数据路径](docs/PRIVACY.md)。

## 已知限制

- 移动预览存在回传延迟，打开扫一扫时也可能停顿；此发布只整理开源与发行方式，没有宣称修复性能。
- 跨屏切流、不同缩放比例、其他机型及长期运行尚未完整验收。
- 需要手机解锁、微信登录及 USB 调试授权；不绕过设备锁屏。
- 最新的本地透明合成实验不在本公开版本中。
- 新增的外部 adb 选择流程已做代码与合成测试；文件选择器和全新 Mac 的首次安装尚未完成真人验收。

## 从源码构建

在 Apple Silicon Mac 上准备 Xcode Command Line Tools 和 Python 3.12+。阅读 Android SDK / JDK 的相关许可后执行：

```sh
python3 scripts/bootstrap.py
python3 scripts/build_app.py
python3 scripts/package_release.py
```

`bootstrap.py` 从官方地址下载固定版本工具并校验哈希；它们仅进入被忽略的 `.tools/`。发行包位于 `build/release/`。`build/*.app` 是中间产物，请使用经签名校验的 ZIP/DMG。开发者构建前需有 Git 提交，安装包会记录对应 commit。

测试区分纯合成测试与会读取连接设备的集成测试，见 [开发与测试](docs/DEVELOPMENT.md)。不要在连接私人设备时批量运行未知集成夹具。

## 版本演进

本次是首次公开预览：保留 USB 镜像与桌面扫码的现有实现，增加外部 adb 配置，整理中文安装、隐私、许可及可复现打包；不发布内部调试历史、真实测试截图、设备标识或本机配置。

## 许可证和维护

原创代码：[Apache License 2.0](LICENSE)。第三方来源与许可见 [THIRD_PARTY.md](THIRD_PARTY.md)。维护者：[006IDC](https://github.com/006IDC)。

本项目与微信、腾讯、Apple、Google、Xiaomi、AndroMeld 无隶属关系。请通过 Issues 报告问题，只提供系统版本、复现步骤和脱敏错误信息，不上传聊天、二维码登录凭据或 ADB 密钥。
