# 开发与测试

App 使用 AppKit、ScreenCaptureKit、VideoToolbox 和 Vision；手机端 Java 服务使用 Android 16 虚拟设备/相机 API，通过 USB 或显式配对的无线 ADB 启动。镜像服务固定为官方 scrcpy 5.0.1。主窗口镜像物理屏，独立微信窗口使用保留的临时显示，扫码结果仍由微信返回。

`mac/` 为主应用，`src/` 为手机端临时服务，`scripts/` 为依赖准备/编译/打包，`third_party/` 为许可证。运行输出、缓存、测试证书及安装包均被 Git 忽略。

## 纯合成测试

`*MailboxTests.swift`、`SocketTests.swift`、`MirrorProtocolTests.swift`、`CancellationTests.swift`、`MirrorCancellationTests.swift`、`DesktopStreamTests.swift`、`WindowCaptureGeometryTests.swift` 和 `ADBConfigurationTests.swift` 测试合成像素、几何、受控进程或本机协议。各文件使用独立 `@main`，不要把所有测试一起编译。

例如在项目目录：

```sh
mkdir -p .local/swift-cache .local
swiftc -swift-version 5 -O -target arm64-apple-macos14.4 -module-cache-path .local/swift-cache mac/PhoneSession.swift mac/DesktopCapture.swift mac/CameraPumpMailbox.swift tests/CameraPumpMailboxTests.swift -o .local/mailbox-tests
.local/mailbox-tests
```

无线连接与临时配对服务分别使用以下独立合成测试入口：

```sh
swiftc -swift-version 5 -O -target arm64-apple-macos14.4 -module-cache-path .local/swift-cache mac/ADBConnection.swift mac/ADBPairingServer.swift tests/ADBConnectionTests.swift -o .local/adb-connection-tests
.local/adb-connection-tests
swiftc -swift-version 5 -O -target arm64-apple-macos14.4 -module-cache-path .local/swift-cache mac/ADBConnection.swift mac/ADBPairingServer.swift mac/WirelessConnectionLease.swift tests/WirelessConnectionLeaseTests.swift -o .local/wireless-lease-tests
.local/wireless-lease-tests
```

配对仅为本次操作启动独立的前台 ADB server，使用系统分配的随机 loopback 端口。固定版 AOSP 的 `server nodaemon --reply-fd 3` 在取得监听 socket 后向专用管道写入 `OK`；该源码明确拒绝 fd 0/1/2，App 以 posix_spawn 文件动作把写端映射到子进程 fd 3，并排空独立的 stdout/stderr 诊断管道。只有确认 ACK 和进程仍存活后才把六位码交给配对 client 的 stdin。server 以 `tcp:localhost:端口` 监听 IPv4 loopback；client 显式连接 `tcp:127.0.0.1:端口`，固定版 AOSP 对这个数字主机地址不会自动拉起后台 server，避免前台服务意外退出后的后台残留。配对后终止并回收本次创建的进程组，USB/模拟器扫描及调试 trace 在此服务内关闭；不调用全局 `kill-server`，默认设备保留原有默认 server；新建无线连接使用长期持有的 `ADBManagedServer`，设备的 `serverSocket` 贯穿 PhoneSession、镜像和清理。选择设备后将服务所有权交给 App，关闭选择器且未选中时收束连接并停止服务。配对信任保留在 Android/ADB，App 不保存一次性配对码。

`ADBConnectionTests` 注入不绑定网络的假端口和假可执行文件，验证独立路由、端点校验、stdin 配对码、ACK 前不发送输入、错误脱敏、成功/失败/取消/超时后的服务与子进程回收，以及不终止无关进程；不运行真实 adb、不接触手机或调试密钥。`WirelessConnectionLeaseTests` 使用纯 actor 夹具验证仅清理本窗口新端点、保留既有连接、所选连接转交和迟到连接收束。

另已用随包 adb 做隔离的前台服务启动/清理探针：随机 loopback 绑定、专用 fd 3 ACK 和退出后监听关闭通过；使用新建临时用户目录，禁用 USB/模拟器/自动连接，不读取既有用户密钥、不运行 devices/connect/pair，不停止默认 server。此探针只证明服务生命周期；真实无线配对/连接及默认 server 共享配对信任仍需单独真机验收，不能由这些测试宣称通过。

## 真机与窗口夹具

含 `Integration`、`PhoneWindow`、`DesktopMovingCapture` 的文件，以及 `QRBoard`、`WebScanBoard`、`LocalScanPreview`、`scripts/probe.py`，需要开发者逐一阅读入口和参数。部分夹具会控制真实连接手机、打开窗口或导出图像；不提供默认一键运行。

先退出产品实例，只用测试手机及纯文本合成二维码，保持清理路径；不要使用真实登录、付款或授权二维码。0.4.0 公开候选包携带 adb，路径为 Resources/adb/bin/adb。旧集成夹具仍可能需要旧目录布局，必须逐一阅读；新 AppWindowIntegration 显式使用项目 .local/adb-bundle 和 build/，仅在传入 --run-device-test 时运行。

## 发布

提交源码后运行 `scripts/build_app.py` 生成经 ad-hoc 签名校验的 ZIP，再运行 `scripts/package_release.py` 生成 DMG、校验值和 manifest。打包脚本从已签名 ZIP 解压校验，验证随包自建 adb、对应源码与许可，manifest 关联源码 commit。发布前还应人工验证设备选择/无线配对、权限及目标手机。构建通过不能替代这些实际验证。

此仓库没有自动部署或自动 Release 工作流。未验证的功能应标注为候选，已知卡顿问题继续公开记录。

## 新增验证

ADBConnectionTests、AndroidApplicationTests、MirrorInputSchedulingTests 为纯合成；test_adb_packaging.py 核对固定源码、wheel/许可/二进制哈希和移位运行，不启动 ADB server。AppWindowIntegration 默认选择唯一授权 USB 手机；加 `--wireless-endpoint 主机:端口` 会创建自有本地服务，并明确连接已配对的无线手机，不会回退到 USB。它会打开设置/微信并恢复，不保存手机画面或输出应用列表/标识。该夹具会结束其无线连接并停止自建服务。加 `--concurrent-mirrors` 会按实际界面顺序启动主屏镜像、预热空微信显示，再打开微信并验证双路新帧；这是功能验证，不计算 FPS 或主观流畅度。

原生拖放、鼠标输入、程序坞动画、无线配对和真实二维码识别必须单独验收，不以这些测试代替。

长期无线服务合成测试（不连接手机）：

```sh
swiftc -swift-version 5 -O -target arm64-apple-macos14.4 -module-cache-path .local/swift-cache mac/ADBConnection.swift mac/ADBPairingServer.swift tests/ADBManagedServerTests.swift -o .local/adb-managed-server-tests
.local/adb-managed-server-tests
```
