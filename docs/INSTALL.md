# 安装与首次连接

## 下载

从 [GitHub Releases](https://github.com/006IDC/desktop-wechat-scanner/releases/tag/v0.3.2-preview.1) 下载 `DesktopWeChatScanner-0.3.2-preview.1-macOS-arm64.dmg` 或 ZIP。仅支持 Apple Silicon 和 macOS 14.4+。Release 同时提供 SHA256SUMS.txt 和 release-manifest.json。

打开 DMG，把 App 拖到 Applications。ZIP 用户解压后把 App 移入应用程序；不要从 DMG 内长期运行。

## macOS 提示无法验证开发者

此预览版只有 ad-hoc 签名，未公证，可能被系统阻止打开。先确认下载来自本仓库且校验值一致，再在“系统设置 → 隐私与安全”查找本 App 的“仍要打开”，按系统指引确认。保持 Gatekeeper 开启；无需关闭系统安全保护。说明依据 [Apple 官方指引](https://support.apple.com/102445)。

不同 macOS 版本的按钮文字可能不同；没有入口时不要反复删除权限记录。企业管理的 Mac 可能禁止运行此类应用。

## 准备 ADB

1. 打开 [Google 官方 Platform-Tools](https://developer.android.com/tools/releases/platform-tools)，阅读并接受其条款，下载 Mac 版本并解压。
2. 将解压后的 `platform-tools` 文件夹放在固定位置，避免放在随后删除的临时目录。
3. 在 App 中点击连接。未发现 adb 时选择“选择 adb…”，选中该目录的 `adb` 文件；“官方下载”会打开上述网页。
4. 已有 Homebrew/Android SDK 用户可选择原安装目录的 adb。首次选择后会记住位置；移动或升级工具后，可在 App 菜单中重新设置。

App 会执行所选 adb 的 `version` 检查；只选择可信来源的工具。它使用你本机 ADB 的密钥和 USB 授权，不上传这些资料。

## 手机与录屏权限

- 手机开启开发者选项和 USB 调试，使用数据线连接并解锁，在手机上接受调试授权。
- Android 16 为本版的目标；小米系统可能另有“USB 调试（安全设置）”。不需要为了使用公开版安装测试 APK。
- 连接后进入微信扫一扫，在 Mac 提示时授予本 App“屏幕录制 / 录屏与系统录音”权限，并按 App 提示重启。App 只使用屏幕图像，音频关闭。
- 确保先断开旧实例，避免两个 App 争用同一手机会话。

## 卸载

先在 App 中断开，正常退出，再将 App 移入废纸篓。ADB 是用户独立安装的工具，不随本 App 卸载；手机可撤销 USB 调试授权。App 本地状态位于 `~/Library/Application Support/006IDC/DesktopWeChatScanner/`，包含中断清理所需会话资料，不要把该目录上传到 Issues。若上次清理失败，建议先重新连接完成恢复，再移除本地状态。
