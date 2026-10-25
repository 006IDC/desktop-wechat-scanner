# 随包 ADB 源码构建

`python3 scripts/bootstrap_adb.py` 在 Apple Silicon Mac 构建 `.local/adb-bundle`。
下载和工具仅在项目 `.local/adb-build`，无需用户安装 ADB 或 Homebrew 依赖。
需要 Apple Xcode Command Line Tools、Python 3.12+、首次构建的网络访问。

固定 nmeum/android-tools 37.0.0（基于 AOSP android-17.0.0_r1），归档哈希与维护者 Release 公布值核对。
CMake 4.1.3 与 Ninja 1.13.0 的官方 PyPI `py3-none` universal2 wheel 固定完整 URL 和官方 SHA-256；
先校验下载字节，再以 `pip --no-index --no-deps` 从本地轮子安装，构建清单记录精确工具输入。
其余依赖固定 URL 和首次取得归档的 SHA-256；这些哈希保证后续相同输入，不冒充独立发布签名验证。
构建只选择 adb；protobuf、brotli、lz4、zstd、fmt、BoringSSL 和 AOSP 辅助库静态链接；libusb 动态链接。
Mac 系统 Framework、libc++、zlib 等系统库由 macOS 提供。

本构建保留 Android 11+ `pair IP:port`、`connect IP:port` 和 USB 能力。
上游独立 CMake 未链接 mDNS 后端；此构建明确禁用自动发现，手工输入地址配对和连接。
`version`、Mach-O 依赖与 ad-hoc 签名验证不证明实体设备配对成功。
脚本不运行服务、不枚举设备、不读取调试私钥。

许可证与通知完整保留在 bundle 的 `licenses/`；每个上游完整源码归档和本地构建配方保留在 `sources/`。
AOSP/android-tools 为 Apache-2.0（具体子项目以各自许可为准）；libusb 为 LGPL-2.1-or-later，
protobuf 与 lz4 为 BSD 类许可，brotli/fmt 为 MIT，zstd 为 BSD/GPL 双重许可，BoringSSL 含多种许可。
保留各源树 LICENSE/LICENCE/COPYING/COPYRIGHT/NOTICE/AUTHORS 的点号、横线、下划线变体及 MODULE_LICENSE 标记；
清单逐份记录许可原文哈希，并检查实际链接组件的独立许可/通知完整。
没有独立许可文件的 AOSP helper/libziparchive，其逐文件版权头保留在完整源归档，Apache-2.0 全文另有保留。

LGPL 替换：动态库位于 `lib/libusb-1.0.0.dylib`，adb 通过相对 `@loader_path` 加载。
可从随包 android-tools 源归档内 vendor/libusb 和配方构建兼容替代库，替换后重新 ad-hoc 签名库及 App。
发行者不得禁止用户为个人使用修改该 LGPL 库、替换或为调试此类修改进行逆向工程。

来源：[android-tools Release](https://github.com/nmeum/android-tools/releases/tag/37.0.0)，
[AOSP](https://android.googlesource.com/platform/packages/modules/adb/)，[libusb](https://libusb.info/)。
重建：将 sources 内归档放入 sources/build-recipe/.local/adb-build/downloads，
在 sources/build-recipe 执行 `python3 scripts/bootstrap_adb.py`（需要网络准备固定构建工具）。
Googletest 仅使用 BSD 许可的 gtest_prod.h 头文件，不编译或链接测试库。

精确输入、能力与文件校验值见随包 `manifest.json`。
