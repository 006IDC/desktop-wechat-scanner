# 第三方组件

| 组件 | 用途与版本 | 许可 / 来源 | 是否随 App 分发 |
| --- | --- | --- | --- |
| scrcpy server | 5.0.1，手机镜像和输入控制；服务端未修改 | [Genymobile/scrcpy v5.0.1](https://github.com/Genymobile/scrcpy/tree/v5.0.1)，[Apache 2.0](third_party/scrcpy/LICENSE) | 是，完整许可证位于 App 的 `Contents/Resources/SCRCPY-LICENSE.txt` |
| Android Debug Bridge | android-tools 37.0.0，从源码构建，USB/手工地址无线配对 | [固定开源来源与配方](third_party/adb/README.md)、AOSP Apache-2.0 及各依赖自身许可 | 是，`Contents/Resources/adb/` 含二进制、对应源码、许可证、哈希 |
| Android SDK Platform 36 / Build Tools 36 | 编译 Android Java 代码 | Google Android SDK 及其各组件许可，见官方 SDK 条款 | 否，仅构建依赖 |
| Eclipse Temurin JDK 21 | Java 构建工具 | [Adoptium](https://adoptium.net/)，GPLv2 with Classpath Exception | 否，仅构建依赖 |
| Apple 系统框架 | AppKit、ScreenCaptureKit、VideoToolbox、Vision 等 | macOS 系统框架 | 不复制，使用系统提供的框架 |

scrcpy server 固定 SHA-256：`764eb6f79811d5211fe9df341120882ba9994c7a61b897d7bf3fb662e53bc536`。构建脚本从官方 Release 获取并验证，不替换或修改其内容。

原创 Swift/Java/Python 代码适用根目录 Apache-2.0 LICENSE；第三方组件保持原有版权与许可。发布包不包含 Google SDK 的预编译 adb、SDK、JDK、密钥或运行数据。随包 adb 为固定开源源码的自建产物，libusb 动态链接并允许替换；对应源码和许可证随包附带，详细履约与重建方式见上述配方。
