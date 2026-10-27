# 开发与测试

App 使用 AppKit、ScreenCaptureKit、VideoToolbox 和 Vision；手机端 Java 服务使用 Android 16 虚拟设备/相机 API，通过 USB 或显式配对的无线 ADB 启动。镜像服务固定为官方 scrcpy 5.0.1。当前已安装开发候选 build 41（源码 `9444951`）连接后请求原生副屏 HOME；在已确认返回白屏的小米上，主窗口改用手机实际应用目录选择器，选中后显示该应用的真实画面。应用可从列表拖出独立窗口；扫码结果仍由手机中的应用返回。2026-10-27 新透明框路径双应用的暂停、恢复、返回、重新框选、真实扫码及清理通过。程序移动不再依赖桌面视频回传，物理鼠标拖动仍未验收；普通镜像链路的延迟不因此视为解决。

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

相机状态通过已认证的手机通道返回，包含当前活动、虚拟相机所有者、所有者是否可判定及代数。Mac 仅在所有者明确、有活动流、恰好一个经真机验证的扫码 Activity、并且同包没有第二个前台窗口时开始桌面采集；未知应用、普通拍照和歧义状态保持关闭。当前经真机确认的精确 Activity 为微信 `com.tencent.mm/.plugin.scanner.ui.BaseScanUI`（亦接受同组件全名）及支付宝 `com.eg.android.AlipayGphone/com.alipay.mobile.scan.as.main.MainCaptureActivity`；支付宝其他扫码类名尚未验证，不因同包名自动放行。手机端相机所有者及相机 ID 只用于内存中的路由判断，不进入遥测。build 40 的三轮双应用自动集成识别与恢复清理通过，完整 GUI 与长时间稳定性仍未验收。相机查询使用不继承 system context 的 shell ContextImpl，使内部 ContentResolver 的包身份与 UID 相符；虚拟 context 的 AttributionSource 保留 deviceId，通过显式 `getCameraCharacteristics(String, false)` 避开无关的全局桌面旋转设置，并直接读取不一定列于 `getKeys()` 的 `INFO_DEVICE_ID` 验证映射别名，不能把设备感知的 camera ID 0 当作物理相机。

任务树解析保留 Task `U` 与 Activity `u` 的用户 ID，核对父子结构、数量与根任务包含的用户。小米的无关分身任务可以出现在其他屏幕，不再使整个快照失败；实际打开、迁移、恢复仍仅允许主用户 0，拒绝混合用户根任务及自有副屏上的其他用户。空子任务的用户也计入根任务判定。`AndroidApplicationTests` 覆盖这些边界，不意味着支持控制分身应用。

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

build 38 起分段记录 socket 写入、回复头等待、回复体读取，以及窗口移动、采集几何、独立窗口呈现和主镜像呈现的 p95/最大值。记录仅在显式六秒诊断窗口内有界采样。`SocketTests` 验证拆包回复、延迟 ACK、普通请求兼容与尺寸拒绝；`CameraPumpMailboxTests` 验证数值随帧回执传递。

普通应用选择和诊断共用可抛错的 `performMainApplicationOpen`；诊断必须先确认启动成功，失败时保留实际错误，不进入扫一扫导航。断开/退出检查取消及会话代数，迟到完成不能重新显示应用。显式自动诊断退出若恢复清理失败，将报告 `cleanupSucceeded=false`、`passed=false` 并以失败码退出，保留恢复记录；普通交互仍显示恢复错误。

build 40 在实时相机 loop 启动时持有 `ProcessInfo` 的 `.userInitiatedAllowingIdleSystemSleep` 活动，clear/pause/disconnect/terminate 路径释放；不关闭系统休眠、不使用 latencyCritical。它声明这段实时工作仍有用户关注，不能据前后性能差异单独证明 App Nap 是全部卡顿的根因。`diagnostic-state.json` 的 `cameraActivityActive` 可核对生命周期。

2026-10-27 本机无线、已保存的独立锁屏选项、同一签名下，build 40（源码 `2cf0410`）三轮两应用均 `automaticCameraStarted=true`、`qrRecognized=true`，整体 `passed=true`、`cleanupSucceeded=true`；主屏前后锁定，实际录屏权限 true。结果如下，每格顺序为微信 / 支付宝：

| 运行 | 六秒移动送帧 fps | 窗口间隔 p95 ms | 窗口间隔最大 ms | 最大送帧间隔 ms |
| --- | --- | --- | --- | --- |
| 第一轮，无线程采样 | 27.21 / 30.17 | 17.44 / 17.41 | 17.66 / 43.42 | 235.89 / 49.53 |
| 第二轮，无线程采样 | 29.52 / 29.38 | 17.46 / 17.32 | 29.02 / 492.39 | 50.01 / 231.74 |
| 第三轮，附加进程采样 | 28.87 / 29.55 | 18.74 / 18.49 | 24.87 / 23.00 | 49.27 / 120.24 |

此前 build 39 同类运行分别约 9.0 / 18.2 fps；以上是前后观察，非受控因果实验。第三轮只采样本 App，未复现半秒窗口间隔，因此采样未定位第二轮长尾的阻塞位置；不能删除该反例或宣称卡顿根治。这些测量由程序移动自己的窗口，不是鼠标到画面的端到端延迟。界面控制工具返回捕获错误，物理鼠标拖动、完整 GUI 与拖出动画未完成验收；App 本身实际录屏和测试码识别正常，不应因此重置录屏授权。

三轮退出后恢复记录均已清除，连接、相机、用户活动均为关闭状态，录屏权限仍为 true。原始运行日志、采样和设备状态仅保留于忽略目录，不进入公开仓库。候选尚不能称达到参考视频效果。

### 独立透明扫码框：build 41 与单帧实验

2026-10-27 新路线研究：手机应用窗口继续显示完整原生界面；进入应用内扫一扫后，另用 Mac 原生透明窗口提供桌面取景框，底下直接是桌面，视觉显示不等待手机回传。取景框内图像仍通过已有虚拟相机送给真实应用，结果返回原应用窗口；识别期间仍沿用既有录屏权限。它改变扫码交互，不是复活旧的局部透明手机遮罩，也不重绘微信或支付宝的按钮。AppKit 提供窗口透明属性，见 [isOpaque](https://developer.apple.com/documentation/appkit/nswindow/isopaque) 与 [backgroundColor](https://developer.apple.com/documentation/appkit/nswindow/backgroundcolor)。此设计已接入 build 41；实际鼠标拖动与整体过渡手感尚未验收。

`tests/SingleFrameScannerExperiment.swift` 只验证这条路线的必要前提：应用能否识别一张持续保留的相机图片，而无需持续上传桌面视频。`--selftest` 仅验证内存中的合成 JPEG 与固定文本二维码，不连接手机。明确传入 `--run-device-test --resources <已安装 App 的 Resources>` 才连接已保存、已配对的无线手机，要求先前已选择独立锁屏选项、产品未连接且无恢复记录；仅进入已核实的微信/支付宝主页及扫一扫，不点聊天或业务结果。所有输入均为合成图，不录制桌面、不申请录屏权限、不保存镜像或 OCR 正文。固定导航标签和布尔/耗时结果可以输出，外部错误不原样输出。

第一次运行在微信导航阶段未确认入口，未进行单帧判断，手机/无线清理均成功。第二次运行两款应用均成功：每款先上传一张白图排除旧结果，再仅上传一张合成码；微信与支付宝各一张码均被真实应用识别，结果页观察耗时约 1909 / 5422 ms，上传 ACK 约 71.8 / 28.7 ms。主屏前后锁定，手机任务恢复与自建无线连接清理均成功。观察耗时包含轮询、镜像返回和文字确认，不是单纯的手机解码耗时，也不是端到端拖动延迟；该实验不能证明识别已足够快或整套交互已完成。它只证明取景框显示可以与持续相机上传解耦；普通手机应用点按的镜像延迟仍需另行优化。


build 41 的生产路径使用既有 `ScanFrameController`，而不是对手机像素挖洞。透明开口固定为 320×320 点，Mac 顶部工具条可拖动、暂停/继续、再扫、返回；Esc、Cmd-W 与系统关闭走同一返回路径。框内直接显示窗口下面的桌面，不创建手机视频预览层。只使用 0.16 秒窗口淡入，并尊重减少动态效果；状态正确性不依赖动画完成回调。

稳定期为 180 ms，最多约每 250 ms 在内存中裁切并检测 QR 存在性；无 QR 不上传，不读取业务码的 payload。区域或显示变化、拖动开始及再扫递增 mailbox revision，A→B→A 也不能复用旧 selection。capture/Vision 后、PhoneSession 实际写入前、ACK 后及主线程 handoff 前均核对同一 selection。若 ACK 期间或 ACK 后用户再移动，拒绝 handoff，丢弃该代图片后继续取景。认证命令 23 仅在请求 epoch 等于当前 epoch 时清图；不会擦除较新一代图片。它不等同于原命令 3（仅推进 epoch 才清图）。图像已经被真实应用识别时，Mac 无法撤销其识别；本程序不确认登录、授权或支付。

发送当前 QR 图且确认 ACK 后，关闭透明框、停止桌面采集和相机上传、展开完整原生手机窗口，让真实应用继续显示识别过程与结果；不把 ACK 当识别成功。相机图保留供手机识别，暂停、取消、离开扫码或换应用时清除。本地模式未确认清帧 ACK 时安全断开并保留恢复信息，不显示“已清除”；旧窗口任务不能覆盖较新会话。`LocalScanFrameTests` 验证透明开口 alpha、取景坐标、没有视频层及暂停/恢复/再扫/返回/Esc/系统关闭，`CameraPumpMailboxTests` 覆盖稳定期、A→B→A、重扫及 ACK 前后 revision 失效。两者与 Swift 类型检查通过。

已安装 App 的 `--run-desktop-diagnostic` 走真实透明框路径，另检查暂停→恢复→同代 discard ACK→返回→重新框选，再程序移动透明框六秒、显示自有合成码并确认真实应用结果及回原生窗口。2026-10-27 源码 `9444951` 的第一次运行微信未确认预期首页（未点击未知页面），支付宝完整通过；第二次两应用所有上述步骤通过，`passed/cleanupSucceeded/screenPermission=true`。六秒运动期间均上传 0 帧；停稳显示测试码后各上传一张；紧接第二轮结束时单独读取终态 `diagnostic-state.json` 得到总 `framesSent=2`，它不是 performance 报告的顶层字段。窗口间隔 p95 微信/支付宝约 17.43 / 17.47 ms，最大约 17.61 / 21.77 ms；未复现 build 40 的 492 ms 反例，但新路径测量不证明普通镜像长尾已根治。

第二轮手机主屏开始锁定、结束解锁，不能称全程锁定；App 不操作主屏解锁。退出后连接、相机、透明框和用户活动均关闭，无恢复记录，实际录屏权限保留 true。界面控制工具仍返回 ScreenCaptureKit -3811，物理鼠标拖动和完整 GUI 手感未能验收；不因此重置用户授权。断链/清帧 ACK 失败的安全断开已完成静态独立审查，未做真实故障注入。原始数值、日志及合成 UI 渲染留在忽略目录，不公开上传。


### 原生扫码界面分离研究（2026-10-27，未纳入默认产品）

目标是保留手机应用自己渲染的整个扫一扫界面，只让相机背景在 Mac 本地透出桌面。原参考视频为 888×576、30fps；不能再以“参考片是60fps”解释差距。build 41 的独立透明框不等于该界面，也不能用其扫码通过证明原生透明效果完成。

早期黑/白/灰探针在微信、支付宝均完成纯色采样，但移动扫描线造成帧间不一致：一次中段灰色预测 p95 误差约10.2% / 19.8%，另一次约9.0% / 21.8%。全区均值更小，不能掩盖条带错误。早期渲染探针对1268×2756图像记录到 p95 约9.94 / 11.53ms，每段3秒181帧；这是早期研究程序的内存渲染耗时，不是当前源码验收、屏幕实际帧率或输入到显示延迟。早期采样曾用三帧median、渲染器却取最后一帧；现探针改为用同一张选定原始帧分析及校准，旧报告不能作为修正后实现的验证。

GPU渲染器和显式集成候选位于 `mac/NativeScannerMatte.swift` / `mac/NativeScannerOverlay.swift`，独立实验窗口与真机探针位于 `tests/`；服务端几何计算和实验开关位于 `src/`，只由显式研究参数启用。`NativeScannerMatte.swift` 使用公开 Metal 运行时编译和 Core Image，提供黑白校准以及单帧蓝色背景加静态原生颜色偏置两种实验。所有按钮、文字和扫动线取自真实手机帧，没有重画 Android 控件。蓝色实验在合成输入中验证了灰色、静态任意彩色前景、动态绿色/黑色前景、半透明边缘及非对称图像方向；它依赖静态颜色偏置及动态前景颜色条件，新彩色动画、布局变化和完整真实界面尚未证明等价，不能默认启用。早期CGImage预览以 common-mode timer 取单槽最新图，GPU初始化、校准和连续render均放入worker；新的Metal路径直接提交drawable，首次初始化耗时另计。后续真实预览结果见下方续记，不能等同于完整产品验收。

编译合成测试：

```sh
swiftc -swift-version 5 -warnings-as-errors -O -target arm64-apple-macos14.4 -parse-as-library -module-cache-path .local/swift-cache mac/NativeScannerMatte.swift tests/NativeScannerMatteTests.swift -o .local/native-matte-tests
.local/native-matte-tests
```

`NativeScannerMatteExperiment.swift` 是显式真机探针，编译时加入除main外的mac源码、`NativeScannerMatteProbe.swift` 和 `NativeMattePreview.swift`。CLI 仅在 `--run-device-test --resources <Resources>` 时连接已保存并配对的手机；显式 `--usb-probe` 改为选择唯一已授权 USB 手机，不同时使用无线服务。默认做合成纯文本单帧识别控制实验，`--native-matte-probe` 做黑白灰分离试验，`--show-native-chroma` 只对微信显示最长90秒的原生像素透明预览，正常结束后才交接纯文本合成码并确认原生结果。研究 Bundle 无参数打开只显示说明及“开始 USB 实验”，点击前不连接手机；需确认此前已经启用独立锁屏应用。该预览用于拖动/外观研究，不转发鼠标点击、不采集桌面、不请求录屏权限、不保存手机图片；关闭窗口或请求退出会先收束实验、恢复任务，并取消后续测试码交接。预览完成永远不会自动写 `passed=true`，也不构成视频同等效果认证。其他应用/相机归属变化会停止当前预览。

另观察到独立直连镜像原来按手机完整1268×2756编码，而普通scrcpy路径已有max_size=1600。`DesktopDisplayGeometry` 提供1600长边上限及同比密度的纯计算候选（上述输入为736×1600，像素减少约66.3%，逻辑dp近似不变）。`balanced-display` 和 `display-before-camera` 仅为明确传入的研究开关，要求desktop-home；默认尺寸及初始化顺序保持build 41行为。可在研究探针分别加 `--balanced-display` / `--display-before-camera` 复现实验；新的服务jar必须与Mac源码一起构建。尺寸/密度、方向、偶数边界和参数隔离的合成测试通过，实际手机响应改善尚未验证。

早期真机阻塞记录：无线连接曾准确匹配已保存的Bonjour身份及重启后的新端口，但 `createVirtualCamera` 在 `camera_register` 阶段不返回。先创建独立屏幕未解除阻塞，两项相机服务只读dump均2秒超时；当时已停止继续注册并清理自有会话。根因不能归为Mac录屏权限或用户未重启。USB恢复、服务预热及后续多次成功实验见下方续记；一次恢复不证明冷启动可靠性已修复。

研究源码不携带设备标识、地址、配对码、令牌、图片或OCR正文。正式安装包仍为build 41，未替换、未重置TCC、未发布新Release。要进入默认产品，需要先恢复并查明注册可靠性，再验证整个真实界面的控件、彩色/动态内容、扫码结果过渡、物理拖动和退出恢复；合成测试或平均耗时不能替代这些结果。


#### USB 恢复与直显实验续记（2026-10-27）

USB 接入后只读检查发现手机无线调试开关实际返回关闭，服务发现找到一个记录但解析超时；不能把发现服务当成可连接端点。一次受控整机重启及机主首次解锁后，先调用只读 `cmd -w virtual_camera help` 预热服务、等待提供器出现，再检查 `media.camera` 和 `virtual_camera` 响应，之后多次原生注册/清理成功。预热后两项检查约257ms/34ms返回；这仅覆盖一次冷启动，尚不能证明预热解决了ROM根因。原生线程回溯工具明确要求root，未提权或降低手机安全设置。

新增 `mirror-only` 研究开关隔离相机注册：不设置相机 CUSTOM 策略、不授予相机、不注册虚拟相机，并拒绝帧上传，仅测试自有副屏的视频路径。USB全尺寸首帧约185ms，解码p95约4.0ms；736×1600对照首帧约211ms、解码p95约2.4ms，相对队列积压未改善，不能据像素量下降称响应已修复。此副屏HOME的视觉响应仍未确认，报告始终区分 videoPathVerified 与 homeVisualResponseVerified=false。

`realtime-video` 仍为默认关闭的研究参数，仅在desktop-home下允许。请求公开编码器 PRIORITY=0、LATENCY=0、REPEAT_PREVIOUS_FRAME_AFTER=16667µs；手机输出格式仍报告3帧延迟。首轮不含重复帧的对照相对积压p95约78ms，加入重复帧后约313ms，未证明改善。相对积压不是绝对输入到显示延迟；默认编码器配置没有改变。

自动导航的另一个故障是原生微信标题带未读数。导航探针现接受严格的“微信(数字)”/“微信（数字）”，仍须验证实际圆圈加号像素和精确前台组件后才点按；没有改成猜坐标。一次成功导航约2.4秒，另有多次探针导航超时；新增分段计时继续区分OCR观察耗时、前台查询和真实手机状态，不能把自动测试导航的全部耗时等同于用户点按延迟。

完整原生微信预览已实际运行多轮。蓝色输入期间相机代数未改变，原始帧蓝通道保持有效；中段恢复的alpha均值约0.09，先前窗口截图的灰底不能直接解释为相机输入丢失。单帧校准会将移动彩色扫描线误记成静态颜色偏置；九帧B-R中位数校准的合成反例通过，真实棋盘背板预览已连续透出整个相机区域、保留真实关闭/菜单/扫码文字/我的二维码/图库等原生像素，已观察截图中旧蓝色残影消失。它仍只验证当前微信状态；新彩色动画和布局变化不保证等价。

`--metal-preview` 使用CAMetalLayer、同一command queue和有界drawable，直接把合成纹理呈现到透明窗口，避免逐帧CGImage读回及重新上传；所有按钮仍来自手机。首轮60秒实测3577个GPU完成、3465个已记录呈现，呈现间隔p95约16.67ms、最大约1033ms，GPU耗时p95约8.69ms；当时没有等待尾部所有呈现回调，数据不完整，不能用作完整60秒或视频等价验收。研究程序已增加有界收束与submitted/pending/completeness统计，并把有CPU读回的 `--coverage-probe` 从默认性能对照移除。`--checker-underlay` 仅在研究窗口放置合成背板以核对透明度，不是Mac桌面采集或用户界面替代。

每轮正常完成后，测试码仍由真实微信识别；已成功观察多次，交接到观测约1.7–2.0秒，手机任务和连接清理成功。预览提前关闭不会继续投码。真实桌面内容捕获、二维码交接后的控件/结果切换、连续物理鼠标拖动和完整默认产品流程仍待验收；研究程序与安装版build41/TCC保持隔离。


后续90秒USB全尺寸对照关闭coverage读回探针，等待尾部GPU及呈现回调收束：submitted/completed/callbacks均5399，pending均0，实际非零时间戳呈现5397次，间隔p95约16.67ms、最大约33.33ms，未出现超过50ms间隔；GPU p95约8.43ms、最大约11.35ms，解码失败0。该轮与首轮的差别除coverage开关外还包含统计收束和不同运行时刻，故支持“该轮可用时间戳序列中没有长间隔”（另2个回调无可用呈现时间戳），不能据单次对照断言所有长停顿均由coverage造成。九帧校准/原生透明层已形成可用研究路径，仍未证明真实桌面与输入过渡的完整体验。该轮导航约16.9秒，其中OCR单次约14.59秒，前台查询约56.9ms、状态查询约6.3ms；已明确观察器本身会造成测试启动耗时，不能把这段时间归为手机点按响应。测试纯文本二维码识别观测约1.72秒，任务与会话清理成功。


#### 同一手机窗口的显式集成候选（尚未真机验收）

`--native-camera-preview` 仅对desktop-home模式下、所有者/精确扫码Activity均已确认的路线启用；复用 `PhoneCameraState.scannerActivity()` 的微信/支付宝精确白名单，不另放行相机应用。默认扫码流程保持不变。首次同窗口真机仅验证微信，支付宝原生透明层扩展正在候选中验证。用户仍在真实应用中进入扫一扫，没有另造扫码按钮或Android控件。校准期间保留旧的真实帧并禁用画面点击，九个新黑底观测用于静态颜色中位数，确认蓝底已返回后在原窗口安装透明Metal层；窗口背景对整个手机画面开孔，标题栏保留不透明原生背景。离开精确scanner或所有者/流代数变化时撤销此层。

桌面捕获复用既有权限、窗口ROI及二维码存在门控，只在停稳、当前选择未变化且服务端扫码身份仍有效时上传原图。上传确认后先冻结原生透明层并禁用其点击，等相机所有者变化或最多3秒，再恢复完整普通镜像；具体结果仍由手机决定，不自动点确认。暂停、退出、隐藏窗口和连接清理会停止worker并等待其有界收束。组件测试覆盖校准/交接/失焦时结束按下状态、阻止旧画面输入、完整区域透明与标题栏恢复；它不证明真实鼠标或扫码结果过渡已通过。

`--diagnostic-usb` 只在显式诊断入口选择唯一已授权USB手机，不创建无线连接，不重新配对；诊断仍要求预先存在的录屏授权，预检失败即退出。该候选的真实桌面采集、二维码交接、渐变/颜色、暂停恢复及真实窗口拖动正在验证；不能用9a5d39e的独立研究数据声称新集成已经完成。


首次同窗口候选5cbe91c在系统临时目录中以既有稳定身份运行（与安装版DR相同），录屏预检及实际捕获成功，未重置TCC或要求新授权。USB微信自动进入原生透明层，程序移动六秒期间上传0帧，停稳后上传测试码，真实识别和回原生窗口通过；全流程清理成功。原生层统计submitted/completed/callbacks367、非零呈现366，p95间隔约33.33ms、最大约50ms；窗口调度p95约16.69ms。此短段含真实桌面捕获，不能替代物理鼠标拖动。支付宝已点固定的扫一扫标签但未确认扫码Activity，整轮passed=false；正在加入有限重试且每次重新确认真实首页和当前活动。候选停止原生层时现显式恢复浮层级，附加组件回归覆盖层级/集合行为恢复。已安装包仍为build41。

`--diagnostic-native-hold` 仅在显式desktop诊断且原生透明层就绪后保留60秒观察期，便于真实CUA标题栏拖动；期间仍只允许捕获合成测试板，不继续自动点击。观察期结束再复核同一overlay仍有效，变化时停止本段测试。

诊断导航的30秒是循环目标期限，Vision同步识别可能越过它；OCR返回后、每次返回/点击前及状态重查后，均重新核取消、连接代数和非清理状态，过期时不再投递输入。后台OCR自身不是严格30秒可取消操作。

后续d93da36候选中，微信原生层与支付宝旧透明框两条真实桌面流程均通过识别/返回/清理（整轮passed=true），录屏仍为true且未要求新授权；这仍不能证明支付宝原生透明层。CUA实际拖动中发现状态刷新会重新显示旧视频层，造成原生透明层下有旧镜像重影；当前已按native层优先隐藏旧still/video，新增show→普通status刷新→旧层仍隐藏的组件回归。新增60秒观察期间自有窗口位移数值，只证明窗口确实移动，不测量鼠标到画面延迟。

原生校准诊断新增同一主机单调时钟的阶段累计毫秒：黑底上传确认、九帧就绪、GPU渲染器就绪、蓝底上传确认与镜像确认。它从overlay.prepare开始计时，不包括用户点击、Android打开相机、此前桌面采集准备，也不代表输入到显示延迟。

#### 启动优化对照候选

b375177普通产品路径的微信原生层：本轮校准累计约2577ms（黑底确认238ms、九帧就绪1637ms、GPU就绪2289ms、蓝底确认2577ms）；实际手机识别与返回通过，支付宝本轮未确认导航。CUA执行了两次drag，但自有窗口位移为0，因此不能称真实拖动通过。呈现间隔p95约33.35ms、最大约534ms；最大间隔含二维码结果OCR观察阶段，不等于拖动延迟，但也不能据此称已达到参考效果。

后续候选在后台预热并缓存同设备的不可变Metal pipelines及CIContext，队列、像素纹理和校准仍属于各自renderer；预热只用2×2合成黑色，不访问屏幕/相机。默认九帧仍间隔80ms（移除最后一次无用等待），显式 `--native-fast-calibration` 改为40ms，必须做真机颜色/扫线/识别对照后才能选为默认。`--diagnostic-manual-navigation` 仅在显式desktop诊断中等待90秒内的真实scanner状态，期间不自动点击，供CUA实测应用内入口。退出证据仅记录固定原因、数值错误码、受限错误域与状态相同比较，不记录手机内容或实际应用外的路由。

d787206显式40ms候选：微信校准累计1250ms（九帧892ms、GPU就绪993ms），支付宝1314ms（九帧939ms、GPU就绪1021ms）。此轮微信被CUA按钮命中试验暂停，不能称识别失败；支付宝原生层识别与返回通过。两段窗口位移仍为0，CUA截图/输入映射尚未确认，不能据调用成功宣称拖动通过。呈现p95分别约50/150ms，最大约200/617ms，包含CUA窗口捕获和结果观察，仍未达到参考验收；下一轮无CUA对照必须独立报告。

60秒观察期补充本进程NSEvent局部monitor，仅统计交付到本窗口的鼠标down/drag/up、标题区域命中及最多8个down坐标，以验证CUA是否真正操作此窗口；结束和取消均移除monitor。不观察键盘/其他窗口，不保存像素，默认不启用。

无CUA捕获的d787206对照整轮passed=true、cleanupSucceeded=true、既有screenPermission=true。微信/支付宝均为同窗口原生层，真实合成桌面码识别及返回通过：校准约1361/1269ms；呈现p95均33.33ms、最大50.00/66.67ms，呈现及GPU回调收齐。此范围只是自有窗口程序移动和合成板流程；没有真实鼠标拖动，也未证明实际桌面透出像素与参考等价。不能把CUA并行与对照的差异直接归因为某一个系统组件。

GPU资源复用依据[Apple CIContext文档](https://developer.apple.com/documentation/coreimage/cicontext)：CIContext/CIImage允许多线程使用，context包含内核缓存，不宜频繁创建；这里不共享可变CIFilter或手机校准纹理。

7a1302c实际输入诊断证明微信窗口收到2次down、4次drag、2次up，down均为本窗口(250,805)，contentLayoutRect顶部788，确实命中标题区域，但最大位移为0；这排除了该轮“工具根本没把事件投到窗口”的解释。当前修正fullSize透明根view空白标题区域的mouseDown，调用公开NSWindow.performDrag(with:)；手机画面和工具栏不进入该分支，普通不透明镜像窗口不变，必须再测真实位移。该轮微信识别通过，支付宝本轮导航未确认，整轮不通过；没有发布或替换安装版。
