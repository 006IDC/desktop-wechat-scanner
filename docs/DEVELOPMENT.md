# 开发与测试

App 使用 AppKit、ScreenCaptureKit、VideoToolbox 和 Vision；手机端 Java 服务使用 Android 16 虚拟设备/相机 API，通过 USB 或显式配对的无线 ADB 启动。镜像服务固定为官方 scrcpy 5.0.1。当前开发候选 build 34 连接后请求原生副屏 HOME；在已确认返回白屏的小米上，主窗口改用手机实际应用目录选择器，选中后显示该应用的真实画面。应用可从列表拖出独立窗口；扫码结果仍由手机中的应用返回。build 34 尚未安装验收。2026-10-27 手机服务重启后已完成新后端同一连接内的微信/支付宝扫码、主屏锁定及清理验证，Mac GUI 仍待验收。

`mac/` 为主应用，`src/` 为手机端临时服务，`scripts/` 为依赖准备/编译/打包，`third_party/` 为许可证。运行输出、缓存、测试证书及安装包均被 Git 忽略。

## 纯合成测试

`*MailboxTests.swift`、`SocketTests.swift`、`MirrorProtocolTests.swift`、`CancellationTests.swift`、`MirrorCancellationTests.swift`、`DesktopStreamTests.swift`、`WindowCaptureGeometryTests.swift` 和 `ADBConfigurationTests.swift` 测试合成像素、几何、受控进程或本机协议。各文件使用独立 `@main`，不要把所有测试一起编译。

例如在项目目录：

```sh
mkdir -p .local/swift-cache .local
swiftc -swift-version 5 -O -target arm64-apple-macos14.4 -parse-as-library -module-cache-path .local/swift-cache $(rg --files mac -g '*.swift' | rg -v 'mac/main.swift$') tests/CameraPumpMailboxTests.swift -o .local/mailbox-tests
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

提交源码后运行 `scripts/build_app.py` 生成经稳定本机签名校验的 ZIP，再运行 `scripts/package_release.py` 生成 DMG、校验值和 manifest。打包脚本从已签名 ZIP 解压校验，验证随包自建 adb、对应源码与许可，manifest 关联源码 commit。发布前还应人工验证设备选择/无线配对、权限及目标手机。构建通过不能替代这些实际验证。

此仓库没有自动部署或自动 Release 工作流。未验证的功能应标注为候选，已知卡顿问题继续公开记录。

## 新增验证

ADBConnectionTests、AndroidApplicationTests、MirrorInputSchedulingTests 为纯合成；test_adb_packaging.py 核对固定源码、wheel/许可/二进制哈希和移位运行，不启动 ADB server。AppWindowIntegration 默认选择唯一授权 USB 手机；加 `--wireless-endpoint 主机:端口` 会创建自有本地服务，并明确连接已配对的无线手机，不会回退到 USB。它会打开设置/微信并恢复，不保存手机画面或输出应用列表/标识。该夹具会结束其无线连接并停止自建服务。加 `--concurrent-mirrors` 会按实际界面顺序启动主屏镜像、预热空微信显示，再打开微信并验证双路新帧；这是功能验证，不计算 FPS 或主观流畅度。

原生拖放、鼠标输入、程序坞动画、无线配对和真实二维码识别必须单独验收，不以这些测试代替。

长期无线服务合成测试（不连接手机）：

```sh
swiftc -swift-version 5 -O -target arm64-apple-macos14.4 -module-cache-path .local/swift-cache mac/ADBConnection.swift mac/ADBPairingServer.swift tests/ADBManagedServerTests.swift -o .local/adb-managed-server-tests
.local/adb-managed-server-tests
```

`WirelessReconnectTests` 验证端点记忆、服务名匹配和端口变化选择；`ApplicationLibraryTests` 验证拖放意图，`--own-window` 只创建不排序到屏幕的自有测试窗口；`DetachedApplicationsTests` 使用假手机/镜像验证打开、失败、异步关闭和迟到创建后的清理。`PhoneApplicationPickerTests` 使用实际目录数据模型验证搜索、打开回调、拖出源、选择器与手机画面同尺寸以及切回真实镜像；`PhoneCameraStateTests` 验证相机所有者、精确扫码组件和多窗口歧义拒绝。这些测试均不替代原生拖放或整套真机 GUI 验收。

## 原生副屏与自动桌面相机

副屏 HOME 能否绘制完整原生桌面由手机系统决定。当前小米真机的 `SecondaryDisplayLauncher` 在按 HOME 后仍为纯白，因此在这部手机上该路径只作为副屏能力检测；主窗口的“手机应用”选择器使用已连接手机返回的真实可启动应用目录，不伪装成 Android 桌面或补造应用图标。选择应用后原生镜像继续提供画面和输入，目录内可拖出独立窗口。锁屏独立应用继续受既有显式选项和首次解锁条件约束；物理主屏不会被绕过。

相机状态通过已认证的手机通道返回，包含当前活动、虚拟相机所有者、所有者是否可判定及代数。Mac 仅在所有者明确、有活动流、恰好一个经真机验证的扫码 Activity、并且同包没有第二个前台窗口时开始桌面采集；未知应用、普通拍照和歧义状态保持关闭。当前经真机确认的精确 Activity 为微信 `com.tencent.mm/.plugin.scanner.ui.BaseScanUI`（亦接受同组件全名）及支付宝 `com.eg.android.AlipayGphone/com.alipay.mobile.scan.as.main.MainCaptureActivity`；支付宝其他扫码类名尚未验证，不因同包名自动放行。手机端相机所有者及相机 ID 只用于内存中的路由判断，不进入遥测。后端真实双应用识别已通过，build 34 完整 Mac App 上仍待验收。相机查询使用不继承 system context 的 shell ContextImpl，使内部 ContentResolver 的包身份与 UID 相符；虚拟 context 的 AttributionSource 保留 deviceId，通过显式 `getCameraCharacteristics(String, false)` 避开无关的全局桌面旋转设置，并直接读取不一定列于 `getKeys()` 的 `INFO_DEVICE_ID` 验证映射别名，不能把设备感知的 camera ID 0 当作物理相机。

## 锁屏独立应用

连接参数 `allowLockedApplications` 默认 false。Android 服务只在显式 `independent-lock` 参数下检查已有 ADD_ALWAYS_UNLOCKED_DISPLAY 权限和 UserManager 的首次解锁状态，设置 VirtualDeviceParams.LOCK_STATE_ALWAYS_UNLOCKED 并核验每个自有 Display 的实际标志。主屏锁态仍正常生效。

Android 16 的 scrcpy 二次 AUTO_MIRROR 输出属于默认显示组，真机上主屏睡眠时输出也为 OFF，即使源虚拟显示为 ON。独立模式因此用自有 VirtualDisplay 的 Surface 直接连接 MediaCodec；普通模式继续使用官方未修改 scrcpy。桌面相机输入路径不变。

已认证相机通道 command20/21 以四字节显示 ID 启停直连流；每路有随机 socket/token，视频 role0 与控制 role1 单独认证。视频沿用当前 H.264 帧格式，控制仅接受单指触摸与返回/主页，所有事件设为本次拥有的非零显示。停止先关闭网络、收束工作线程、恢复 ImageReader surface，再释放 codec。失败保留所有权，禁止在旧资源未收束时覆盖。

`AppWindowIntegration --run-device-test --locked-applications --wireless-endpoint 主机:端口` 是显式真机测试，要求手机主屏已经锁定；与 concurrent-mirrors 参数互斥。它检查实际锁策略、设置画面及滑动前后中央像素签名变化、微信新帧、停止/重建直连流及清理，所有采样只在内存，既不保存图片也不打印令牌。它不计算 FPS、不声称整套动画已验收。`DirectMirrorTests.swift` 仅使用本地假 ADB 和 loopback 验证双角色认证、错误 ACK 和取消；`LiveIndependentLockContractTests.java` 只做 JVM 合成参数/权限/标志测试，不调用真实 Android 系统。

官方依据：[VirtualDeviceManager](https://android.googlesource.com/platform/frameworks/base/+/android-16.0.0_r3/core/java/android/companion/virtual/VirtualDeviceManager.java)、[VirtualDisplay](https://developer.android.com/reference/android/hardware/display/VirtualDisplay)、[MediaCodec](https://developer.android.com/reference/android/media/MediaCodec)。

## 本机稳定开发签名

`python3 scripts/build_app.py` 默认使用项目稳定本机身份，生成 `build/桌面微信扫码-本机签名.zip`；旧命令 `--local-signing` 等效。`--ad-hoc` 只生成独立的 `build/桌面微信扫码-ad-hoc.zip` 测试包，不能与 `--install` 同用。首次签名会创建项目 `.local/signing/identity` 内的身份，后续严格核对同一证书指纹。目录与秘密不入仓，不使用钥匙串 CLI，不修改默认/搜索钥匙串、系统信任或 TCC。私钥丢失时不能自动换身份冒充原应用。自签并不提供 Developer ID 或 Apple 公证。

`python3 -m unittest discover -s tests -p test_local_signing.py` 默认只运行临时夹具的签名元数据单元测试。需要显式验证持久身份签署合成应用时，设置 `RUN_LOCAL_SIGNING_INTEGRATION=1` 再运行同一命令；该集成测试会访问项目本机签名身份并调用 `codesign`，不会安装应用。

真实安装前必须完成签名校验；跨版本的指定要求相同只是身份连续性的前提，录屏授权仍需在实际安装路径和系统上验证。

`ScanPreviewMaskTests.swift` 创建但不显示本程序窗口，确认完整手机帧没有局部透明遮罩、原生不透明标题栏及暂停/恢复后的窗口层级与继续按钮。没有录屏、手机或共享 UI 输入。运行：

```sh
swiftc -swift-version 5 -warnings-as-errors -target arm64-apple-macos14.4 -parse-as-library -module-cache-path .local/swift-cache $(rg --files mac -g '*.swift' | rg -v 'mac/main.swift$') tests/ScanPreviewMaskTests.swift -o .local/scan-mask-tests
.local/scan-mask-tests
```

## 扫码性能诊断

蓝色移动条/棋盘自检已从普通用户菜单移除，仅开发者显式使用 `--run-scan-diagnostic` 入口；需要此前选定且当前可连接的测试手机与既有录屏授权。测试自动移动本 App 的扫码窗口 6 秒，然后显示纯文本合成二维码，最多等待 8 秒；只保存数值和识别确认布尔值至 App 支持目录的 `performance-last.json`，不保存画面、二维码外的 OCR 文本或消息。测试结束恢复窗口位置、关闭测试板、撤销测试板采集例外并暂停相机。暂停、返回、最小化、断开或退出会取消测试。系统开启减少动态效果时不进行往返移动，报告会标注。

这是原生窗口位置更新与真实扫码链路的诊断，不等于物理鼠标拖动或屏幕实际显示延迟验收。视频相对积压用同一流的 PTS 与 Mac 到包时间差的最小值作基线，含时钟漂移影响；不能当作绝对无线延迟。`MirrorTimingTests.swift` 使用合成时钟，验证重连/PTS 跳变、计数、有界采样和并发，真实硬件数据需另验。

显式自动诊断入口为已安装 App 可执行文件的 `--run-scan-diagnostic` 参数。必须先退出普通实例；它只重用已选择的无线手机与已保存的锁屏选项，不接收配对码、不请求录屏权限、不合成系统鼠标输入。它运行开发自检并正常退出清理。若手机停在无法识别的非首页页面，会报告未确认，不自动点击聊天或业务结果。

诊断启动任务在断开或退出时取消并隔离迟到结果；首次退出返回取消并完成异步清理，随后再立即退出，以免 AppKit 嵌套退出循环阻塞主队列。导航诊断仅包含固定的微信导航标签、位置和耗时，不保存聊天 OCR。

仅开发者给 App 的 `--run-scan-diagnostic` 显式追加 `--diagnostic-toolbar` 时，诊断会在确认微信主页后保存顶部 11% 工具栏图片至 `~/Library/Application Support/006IDC/DesktopWeChatScanner/diagnostic-toolbar.png`，用于检查点击定位；不含聊天列表、桌面或扫码结果。正常启动与普通自检不输出图片。

自检分别报告运动阶段送帧最大间隔、发送 JPEG 中的合成码可见性、手机画面中的合成码可见性，以及手机显示测试明文结果的确认。二维码视觉检查只在六秒运动基线结束后启用，不读取或保存其他二维码内容；它不触发登录或支付。

扫码导航在确认主页的同一帧定位真实环形加号，再按阶段识别右上菜单或底部扫码标签，保留准确中文识别与受限回退。`ScannerNavigationOCRTests` 用合成文本验证 Vision ROI 局部坐标正确还原到整图坐标。自检板在普通窗口之上、扫码窗口之下，并只采集该合成板；显式 `--diagnostic-pattern` 可保存这一路纯合成裁切图 `diagnostic-board-crop.jpg`，位于上述 App 支持目录，正常运行不保存。

后台无线传输对比使用 `tests/WirelessCameraPerformanceTests.swift`，不会弹出 Mac 蓝条、棋盘或其他窗口，也不采集桌面。先确认 App 未连接、没有恢复记录；显式 `--run-device-test` 只重用已保存且授权的无线手机与锁屏独立应用设置。它在内存预编码同一组 720×1280 JPEG（质量 0.88）/PNG 合成画面，按 JPEG/PNG/PNG/JPEG 各发送六秒，最后仅识别测试明文 `006IDC20261026PERF` 并返回一次。不会点击其他扫码结果。正常结束清理本次手机会话、无线连接和自建 ADB 服务。

```sh
swiftc -swift-version 5 -warnings-as-errors -O -target arm64-apple-macos14.4 -parse-as-library -module-cache-path .local/swift-cache $(rg --files mac -g '*.swift' | rg -v 'mac/main.swift$') tests/CameraFramePipeline.swift tests/WirelessCameraPerformanceTests.swift -o .local/wireless-camera-performance
.local/wireless-camera-performance --selftest
.local/wireless-camera-performance --run-device-test --resources '/准确安装路径/桌面微信扫码.app/Contents/Resources'
```

`--selftest` 只验证合成图像格式、尺寸和 QR 内容，不连接设备。设备测试输出 JSON，须检查 `ok`、`qrMatched`、`phoneCleanupOK` 和 `wirelessDisconnectOK`，不能仅凭退出码认定通过。各段 ACK/FPS/手机处理耗时是真正分段数值；镜像 `RollingWindow` p95 是最近样本窗口，只作上下文，不能直接比较各段。此对比不含图像编码、Mac 采集和窗口绘制耗时，不代表完整产品体验。

后台入口仅在显式追加 `--diagnostic-toolbar` 且确认微信主页后，保存顶部 11% 的手机工具栏裁切至项目 `.local/headless-toolbar.png`；该路径与 App 支持目录的 `diagnostic-toolbar.png` 不同。正常后台测试不输出图片，合成测试帧和其余手机镜像只在内存中使用。

在同一后台入口追加 `--compare-pipeline`，改为串行/流水线/流水线/串行各六秒，逐帧生成并编码同一种合成 JPEG；保留每段 ACK、编码耗时、选帧到 ACK、发送前帧龄和覆盖/过期计数。该模式包含合成绘图与编码，但不含 ScreenCaptureKit 或 Mac 窗口绘制；两种模式最后都用真实微信核对固定明文。

`tests/CameraFramePipeline.swift` 是仅供测试的实验支撑：一个编码生产者、一个发送消费者与一个覆盖旧帧的槽，产品默认仍走串行相机路径。`CameraFramePipelineTests` 验证慢消费、取消收束、两侧错误、无效/过期时间戳与并发运行拒绝。后台 run6 的串行两段约 27.66 / 27.71 fps，流水线两段约 27.05 / 26.83 fps，最终测试明文识别、手机会话及无线连接清理均通过；未见流水线提速，因此不纳入默认产品。该结果不证明其他无线状态或完整 App 交互的性能，build 33 已安装且录屏权限延续为 true，完整 App 路径仍待复验。

视频包格式的纯 JVM 验证：使用项目内 JDK 编译 `src/DirectVideoPacket.java` 与 `tests/DirectVideoPacketTests.java` 后运行测试类；覆盖 config/key/普通帧字节、单次写调用及 8 MiB 边界。实际无线延迟仍须真机测量。

### 通用应用路径集成诊断

显式 `--run-desktop-diagnostic` 重用已配对设备和已有录屏权限，走普通的独立桌面、应用目录、主窗口打开及相机归属跟随路径。依次仅定位微信、支付宝的真实“扫一扫”，不操作聊天、登录或支付；桌面采集在进入扫码前限定为 App 自有合成板。每款应用以原生窗口往返移动 6 秒，再验证固定纯文本码，数值结果写入 App 支持目录 `desktop-performance-last.json`；不保存截图或 OCR 正文。它验证实际采集/发送/识别，仍不测量鼠标到屏幕的物理拖动延迟。正常启动不运行该诊断。

诊断状态文件由后台串行 writer 合并写入最新快照，界面线程不再执行 JSON 编码或磁盘写入；退出异步等待最后一次写入。
