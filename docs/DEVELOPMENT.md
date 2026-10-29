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

相机状态通过已认证的手机通道返回，包含当前活动、虚拟相机所有者、所有者是否可判定及代数。以下为未开启通用桌面相机时的兼容规则：Mac 仅在所有者明确、有活动流、恰好一个经真机验证的扫码 Activity、并且同包没有第二个前台窗口时开始桌面采集；未知应用、普通拍照和歧义状态保持关闭。当前经真机确认的精确 Activity 为微信 `com.tencent.mm/.plugin.scanner.ui.BaseScanUI`（亦接受同组件全名）及支付宝 `com.eg.android.AlipayGphone/com.alipay.mobile.scan.as.main.MainCaptureActivity`；支付宝其他扫码类名尚未验证，不因同包名自动放行。手机端相机所有者及相机 ID 只用于内存中的路由判断，不进入遥测。build 40 的三轮双应用自动集成识别与恢复清理通过，完整 GUI 与长时间稳定性仍未验收。相机查询使用不继承 system context 的 shell ContextImpl，使内部 ContentResolver 的包身份与 UID 相符；虚拟 context 的 AttributionSource 保留 deviceId，通过显式 `getCameraCharacteristics(String, false)` 避开无关的全局桌面旋转设置，并直接读取不一定列于 `getKeys()` 的 `INFO_DEVICE_ID` 验证映射别名，不能把设备感知的 camera ID 0 当作物理相机。

任务树解析保留 Task `U` 与 Activity `u` 的用户 ID，核对父子结构、数量与根任务包含的用户。小米的无关分身任务可以出现在其他屏幕，不再使整个快照失败；实际打开、迁移、恢复仍仅允许主用户 0，拒绝混合用户根任务及自有副屏上的其他用户。空子任务的用户也计入根任务判定。`AndroidApplicationTests` 覆盖这些边界，不意味着支持控制分身应用。

## 锁屏独立应用

连接参数 `allowLockedApplications` 默认 false。Android 服务只在显式 `independent-lock` 参数下检查已有 ADD_ALWAYS_UNLOCKED_DISPLAY 权限和 UserManager 的首次解锁状态，设置 VirtualDeviceParams.LOCK_STATE_ALWAYS_UNLOCKED 并核验每个自有 Display 的实际标志。主屏锁态仍正常生效。

Android 16 的 scrcpy 二次 AUTO_MIRROR 输出属于默认显示组，真机上主屏睡眠时输出也为 OFF，即使源虚拟显示为 ON。独立模式因此用自有 VirtualDisplay 的 Surface 直接连接 MediaCodec；普通模式继续使用官方未修改 scrcpy。桌面相机输入路径不变。

已认证相机通道 command20/21 以四字节显示 ID 启停直连流；每路有随机 socket/token，视频 role0 与控制 role1 单独认证。视频沿用当前 H.264 帧格式，控制仅接受单指触摸与返回/主页，所有事件设为本次拥有的非零显示。停止先关闭网络、收束工作线程、恢复 ImageReader surface，再释放 codec。失败保留所有权，禁止在旧资源未收束时覆盖。

`AppWindowIntegration --run-device-test --locked-applications --wireless-endpoint 主机:端口` 是显式真机测试，要求手机主屏已经锁定；与 concurrent-mirrors 参数互斥。它检查实际锁策略、设置画面及滑动前后中央像素签名变化、微信新帧、停止/重建直连流及清理，所有采样只在内存，既不保存图片也不打印令牌。它不计算 FPS、不声称整套动画已验收。`DirectMirrorTests.swift` 仅使用本地假 ADB 和 loopback 验证双角色认证、错误 ACK 和取消；`LiveIndependentLockContractTests.java` 只做 JVM 合成参数/权限/标志测试，不调用真实 Android 系统。

官方依据：[VirtualDeviceManager](https://android.googlesource.com/platform/frameworks/base/+/android-16.0.0_r3/core/java/android/companion/virtual/VirtualDeviceManager.java)、[VirtualDisplay](https://developer.android.com/reference/android/hardware/display/VirtualDisplay)、[MediaCodec](https://developer.android.com/reference/android/media/MediaCodec)。

## 本机稳定开发签名

`python3 scripts/build_app.py` 默认使用项目稳定本机身份，生成 `build/MiraDroid-本机签名.zip`；旧命令 `--local-signing` 等效。`--ad-hoc` 只生成独立的 `build/MiraDroid-ad-hoc.zip` 测试包，不能与 `--install` 同用。首次签名会创建项目 `.local/signing/identity` 内的身份，后续严格核对同一证书指纹。目录与秘密不入仓，不使用钥匙串 CLI，不修改默认/搜索钥匙串、系统信任或 TCC。私钥丢失时不能自动换身份冒充原应用。自签并不提供 Developer ID 或 Apple 公证。

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
.local/wireless-camera-performance --run-device-test --resources '/准确安装路径/MiraDroid.app/Contents/Resources'
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

进一步系统窗口几何对照：同一候选透明窗口和断开后的普通不透明窗口，经CUA drag前后WindowServer主窗口边界均未变。因此上一段“透明标题区域未交给AppKit导致不动”只是待验证推断，不能定性为唯一程序根因；817c818虽证明performDrag请求2次，仍没有实际位移。当前使用公开原生拖动方式，不以额外手写拖动绕过工具限制。局部输入诊断补充mouseDown/mouseUp时的自有WindowServer边界及最多8个drag坐标，以区分系统位置与AppKit缓存；不读取其他窗口标题或图像。

打开扫描的后续候选：黑底校准阶段继续显示真实Android新帧并保持输入禁用，仅在送蓝底前短暂冻结普通镜像，确认后由原生透明层接管；不再从准备开始冻结旧微信首页。原生层已挂载时始终阻止旧视频恢复。空白标题背景允许首击，手机控件仍按自身事件处理。组件回归检查黑底阶段视频继续显示、原生层挂载后旧视频保持隐藏与既有touch释放。尚未将此过渡宣称为真机通过。


原生实验退出保护候选：测试取消后曾出现 virtual_camera 持续超时且 media.camera 服务缺失，单独退出本次精确匹配的远端进程后 virtualdevice 恢复，但相机服务仍未恢复；这些是实测现象，尚不能认定小米 ROM 内部死锁原因。旧会话的自有资源与恢复记录已通过生产清理逻辑清掉。

新增认证命令24仅使用服务端持有的 VirtualDevice 对象调用 goToSleep，不接受display ID，不注入Back或关闭应用页面。客户端先核对会话owner、虚拟设备和association；服务端确认独立显示休眠并核对主屏电源未变，再由客户端连续两次确认已知相机owner为空且流数为0、generation稳定，才恢复任务与释放设备。未配置相机的mirror-only实验明确返回无相机；不支持、未知或超时则保留会话。该退出顺序依据[AOSP VirtualDeviceImpl](https://android.googlesource.com/platform/frameworks/base/+/HEAD/services/companion/java/com/android/server/companion/virtual/VirtualDeviceImpl.java)中作用于本设备可信非mirror显示的休眠能力；不把AOSP当作此小米ROM的根因证据。合成测试覆盖活动相机、未知owner、状态变化与读取失败；真机缓解效果尚未确认。此前检查后发送ADB Back的草案因页面变化竞态已弃用，从未纳入已安装包。


退出顺序进一步缩小：b05541b双应用原生识别/返回都通过，但总体验收因cleanupSucceeded=false未通过；微信/支付宝校准1045/1261ms，呈现p95均33.33ms，支付宝最大116.67ms。随后无第三方应用、无镜像、无录屏的单独实验也失败在wait_owned_displays_off，证明这一失败无需扫码页即可复现，不能归为支付宝关闭相机慢。改为先有界停止本次directStreams，再仅对保留的VirtualDisplay对象setSurface(null)，然后休眠并继续原检查，无应用实验清理成功、journal消失、三个系统服务仍健康。依据[VirtualDisplay.setSurface官方说明](https://developer.android.com/reference/android/hardware/display/VirtualDisplay#setSurface(android.view.Surface))，分离Surface类似关屏、暂停buffer输出；不假设API返回就等于STATE_OFF，仍实际验证OFF、主屏未变和相机闭合。该结果还不证明活跃扫码退出已稳定。

后续显式原生性能候选：连接启用已有balanced-display（最长1600像素、同比缩放dpi保留dp布局）与realtime-video编码提示；不改变物理手机的分辨率/密度，厂商是否接受latency提示以编码器回报为准。快速校准不再固定等350ms，改为认证黑帧ACK后等待新的中心暗底帧，再收齐九个新观察；暗底只是准备度探针，不能替代确切扫码路由、owner和generation检查。合成测试拒绝白/蓝/灰底和过小帧，容许外围原生白控件及薄绿色扫码线。保守80ms模式保持原逻辑。`--diagnostic-primary-screen`在显式桌面诊断创建棋盘和捕获目标之前，将本程序scanner与board选择到同一主显示器，结束恢复scanner原位置；可与hold联用，不操作其他窗口，不改变显示设置。

`OwnedDeviceShutdownIntegration --run-device-test <resources> <adb>` 是显式USB生命周期试验，仅创建本次独立设备，不打开第三方应用、不采集画面；输出固定阶段、流数和owner闭合布尔值。`OwnedCameraCleanupTests`与`NativeCalibrationReadinessTests`为合成测试，不能当作真机验收。


9ebdca2完整双应用实验两者均未确认扫码入口，不能当作快校准/呈现通过；退出cleanupStage=complete，journal消失，三个系统服务健康。随后CUA直接观察在balanced-display下微信出现重复标题，点按未正常打开菜单，故从App候选连接参数中撤掉balanced-display，保留原有独立显示尺寸，仅继续试realtime-video。没有替换已安装版。此处先前“保留布局”仅是按比例缩放的设计意图，在该ROM上的实际回归否定了它的可用性，不能作为产品承诺。

快模式进一步要求ACK后连续两帧中央暗候选再采样；统计名改为darkCandidateReadyMilliseconds。暗色启发式仍可能命中排队的旧暗帧，不能称上传黑图的端到端确认，须以真机背景/原生扫线/识别验收。主屏hold定位按CGMainDisplayID映射NSScreen后才移动本窗口，避免将任意枚举屏幕叫主屏。


8e9f980微信已通过原生校准、测试码识别/返回：约1202ms校准，呈现p95=33.33ms、最大50ms、GPU p95=4.73ms，编码器报告latency=1帧（不是端到端输入延迟）；支付宝本轮自动入口未确认，整体passed=false。退出complete、journal清除、系统相机健康。此结果也不证明此前重复标题一定由分辨率单一因素导致，只能说明保留原尺寸候选的微信主流程已通过。

退出取消边界：先取消并等待启动诊断结束，再停止镜像/手机会话，避免还在收尾的诊断与设备释放交错。`--diagnostic-active-scanner-exit`在显式桌面诊断下只打开微信，确认原生扫码层及认证scanner状态，不展示QR、不发送Home，随后走正常退出；用独立test名称/通过条件，不冒充双应用QR通过。cleanup另记录休眠前流数、是否完成双闭合及固定阶段，不输出owner包名/页面/设备标识。此模式待真机验证。


6f7c41d活跃退出真机实测：test=desktop-native-active-scanner-exit，开始退出前认证scanner存在、流数1；PhoneSession在cmd24前再次认证读取仍为1流，随后双闭合确认true、cleanupStage=complete、journal消失；virtualdevice/virtual_camera/media.camera均健康。此实验不验证QR识别，也不证明ROM底层无缺陷。后续将cmd24前scanner布尔、正流数与闭合/清理共同作为activeScannerExitVerified门槛，缺证据不通过。

同轮CUA主显示器拖动：窗口收到down/drag/up与1次NSWindow.performDrag请求，按下/松开WindowServer边界仍(555,46,360,820)，60秒位移0。排除了仅负坐标屏幕导致此现象的解释，仍不能用CUA替代物理拖动验收。呈现p95约33.33ms，最大216.67ms；长间隔集中于CUA观测时段，只是相关，不能归定某个系统组件。原生微信控件在截图中可见；单窗口捕获不能证明真实桌面透视已等价参考视频。

随后6f7c41d手动双应用诊断被CUA明确报告的Mac锁屏挡住；既有screenPermission=true。尚未完成支付宝手动入口、真实桌面透视及物理拖动手感验收，已安装build41没有替换，未发布候选。


纯合成校准图缓存候选：将每次临时创建CIContext编码两张PNG，改为后台预热并缓存固定720×1280纯黑/纯蓝PNG（不缓存任何用户像素）。组件验证PNG解码尺寸、四角/中央不透明颜色与重复读取字节一致；本机一次冷初始化约33ms，1000次缓存读取平均约0.00022ms，只说明固定资源路径成本，不能当端到端扫码提升。真机接入耗时仍待后续对照。

锁屏挡住的手动双应用诊断最终已自行结束，cleanupStage=complete、journal消失，三个相机/虚拟设备系统服务仍健康。没有停用系统锁屏或重置录屏权限。


机主再次解锁后的f3a1f04手动验收：CUA对候选和系统设置均报ScreenCaptureKit -3811，但仍可读应用清单；重建CUA JavaScript会话后恢复，并实际读到支付宝首页。没有修改TCC或系统权限。不要把这个工具失败直接归为App权限错误，也不能保证同法能修复所有-3811。

本轮随后ADB报告设备不可达，复查授权USB设备=0、已连接无线设备=0，5秒无线调试Bonjour浏览也未发现服务；支付宝点按/原生扫码未完成验收。测试前端已通过正常退出关闭，恢复记录仍保留，不能宣称已核对本轮手机侧资源清理。需要恢复到此前准确的USB连接再用既有生产恢复逻辑核对/清理；未重启手机、未新配对、未切换设备身份或改动安装版。

USB重新接入后，生产恢复逻辑清理旧journal成功，三个系统服务均正常响应。f3a1f04与8b0f600两轮手动入口诊断均未确认扫一扫，均正常清理，不能当作流畅度通过；既有screenPermission持续true。8b0f600的显式手动诊断同时记录主窗口局部事件、最多8个自有命中view类型及PhonePreview down/up累计计数（含before快照）；不记录Android正文或图片。该轮两应用的局部事件与preview计数均为0，尚不足以断定输入被App拦截，需要与自有纯测试窗口对照。单独普通AppKit探针能收到工具的down/drag/up，但原生标题拖动的窗口位置仍未变化。

8b0f600修复同值localScanPreview状态刷新清空尚未完成触摸的问题：同值不改变触摸，真正模式变化才发送UP并释放。组件回归覆盖down→同值刷新→up，以及实际view树hitTest命中PhonePreview。AppKit hitTest参数属于receiver的superview坐标（[Apple文档](https://developer.apple.com/documentation/appkit/nsview/hittest(_:))）；不能套用UIKit坐标约定。此修复不等于已定位全部卡顿。另在恢复原尺寸后仍观察到微信重复标题，因此此前balanced-display与该现象的关联不能表述为唯一根因。

随后纯合成输入探针复用真实ControlWindowController，工具重建会话后收到down/up、localEvents=2，触点坐标与合成圆点一致。产品诊断仍未收到事件，进一步查明自检棋盘在扫码启动前已固定floating-1，而主镜像尚为normal；其遮挡会拦截坐标点击，单窗口截图却排除了棋盘。当前修复仅涉及诊断：初始棋盘与镜像同级并order below，随后按镜像normal/floating变化同步层级，停止扫码时退回normal；缓存层级避免60Hz重复排序。组件回归验证normal→floating→normal，实际view树命中与同值刷新触摸均通过；含NSScreen的层级测试需在可访问WindowServer的环境运行。此前“坐标点击未交付”不能解释成所有普通AppKit输入或真实手机控制故障；修正后的手动真机验收另记。

0c5bd8d修正后的CUA手动双应用链路整轮passed=true：微信3组、支付宝4组实际PhonePreview down/up成对送达，命中自有预览；均从应用内入口启用原生层，识别测试纯文本并返回。两段校准约809/648ms，呈现p95约33.33/16.67ms；支付宝出现一次约667ms间隔，不能称零卡顿。该轮曾出现非测试页面，已退出且未同意其位置请求，未保存该页面/正文。

同一0c5bd8d无并行CUA截图对照：微信/支付宝识别、返回、清理均成功，校准约756/1027ms，呈现p95均16.67ms，最大33.33/100ms（支付宝长间隔位于约6秒的测试码交接末段）。仍不能由工具并行与否直接断言因果。随后60秒微信原生hold的p95约16.67ms、最大83.33ms；退出前认证确认scanner=true、stream=1，关断确认及生产清理均成功，journal消失，三项系统服务健康。CUA的down/drag/up、标题命中、performDrag请求均到达，但WindowServer实际位移仍为0；物理拖动和参考视频同等手感尚未验收，未替换已安装build41或发布Release。

后续原生计时新增受限数值：首次drawable提交后的源帧到达间隔、每次原生呈现尝试的nextDrawable等待（含未拿到drawable或后续渲染失败），与已有GPU/实际呈现间隔分别统计；过滤无效值，每类最多7200样本，不存像素。合成计时测试验证校准期排除、阶段分离和采样上限。用于区分源帧、可绘制缓冲区与屏幕呈现停顿，不能把GPU耗时当成鼠标端到端响应。

40a10bc首轮分阶段对照两应用识别、返回、清理通过，但微信初段呈现空档约700ms、视图收帧空档约831ms，nextDrawable最长约129ms；这只能缩小观察范围，视图收帧发生在Mac主线程，不能直接归因手机/USB。随后本App启动期3秒线程采样并未复现同样空档；该轮微信/支付宝p95均16.67ms，最大33.33/50.00ms，视图收帧最大34.02/35.62ms，nextDrawable最大27.60/10.66ms，真实扫码返回和清理仍通过。采样主要显示主线程正常等事件，不能据前一轮间隔认定主线程死锁，也不能凭后一轮将偶发空档认作已修复。原生画面不变时编码器不发新帧本身正常，呈现间隔不等于可见卡顿；真实桌面移动和肉眼跟手性仍需独立验收。当前发布/安装默认行为未改变。

### 解码直达与显示同步对照（2026-10-27）

`--native-camera-preview` 研究路径新增直接解码观察者：最新CVPixelBuffer在解码回调中进入独立有界槽，不再等待AppKit的60Hz镜像定时器。观察者绑定精确的流代次与UUID，reset/stop/替换会在源锁外失效旧槽，旧清理不能移除新绑定；冻结后拒绝晚到帧。对应组件覆盖主线程阻塞、重入、同值UI刷新不重复投递、替换与代次失效。

e1d43e2的USB双应用扫码、返回及清理通过；显式暂停本App主线程约251ms期间，微信收到22帧/呈现15帧，支付宝收到18帧/呈现2帧。但直接输入配合旧5ms绘制轮询后，支付宝呈现p95约367ms、最大767ms，性能退化。因此不能仅凭跨越主线程暂停或功能passed判作流畅。

74129ce改用独立线程的CAMetalDisplayLink，消费最新帧并使用回调提供的drawable，不再额外调用nextDrawable。首轮暂停实验因呈现时间全为0而失败；GPU完成不等于实际呈现。无暂停整轮随后识别/返回/清理通过，p95均约16.67ms，但微信出现约1017ms空档、支付宝约183ms，仍非无卡顿。自有纯色Metal窗口对照确认display-link有有效呈现，且主线程暂停250ms时继续呈现；它不连接手机或采集桌面。

e48dcc7以有效呈现时间为就绪条件，记录窗口可见区域和屏幕交集；后续版本同时将这些条件纳入guard，不能确认则不执行暂停实验。e48一轮两应用真实扫码/返回/清理通过：约250ms暂停期间微信解码21/呈现15帧，支付宝解码17/呈现13帧；呈现p95均约16.67ms、最大约33.33/50ms。这是一次受控故障注入结果，不是物理鼠标拖动或参考视频等价验收，也不能消除先前长空档的事实。

6c0c22c进一步将drawableSize变更合并为一个待处理尺寸，由渲染线程在回调之间应用，AppKit只提交几何请求；避免重复尺寸写入，并允许已取得的旧尺寸drawable完成当前帧。静态审查未证明旧实现存在内存竞态，不能把此改动称为已找到卡顿根因。组件覆盖最新有效尺寸、无效尺寸拒绝、停止后不再改尺寸；纯Metal可见窗口已确认新的320×480 drawable及阻塞主线程期间继续呈现。真机长时间观察结果另记。以上均为研究候选，不替换已安装build41、不改变默认入口、不发布Release；使用既有稳定签名和录屏授权。

6c0c22c长时间观察未通过：微信约64秒内3482次非零呈现，p95约16.67ms但最大约566.66ms，多个较长间隔仍存在；CUA标题down/drag/up与performDrag均送达，实际位移为0，不能据此判断真实鼠标手感。随后发生frameExpired并停预览，未识别测试码；支付宝入口未确认。退出停在waitCameraClosure（activeStreams=1），journal保留。生产恢复只读核验后仍报告virtual_device_unavailable，virtualdevice/virtual_camera/media.camera均持续约2秒超时。仅自有服务进程的诊断栈入口要求root，未提权、未停止系统服务。已停止新建真机相机会话，需正常恢复手机后先核对旧会话清理。

该轮额外发现诊断自身把scanner在hold时移到主屏、board却留在原副屏；后续将屏幕选择提前至board/捕获目标创建之前，并以组件回归验证两者同屏及结束位置还原。因此该轮不能当作有效多屏扫码/交接对照，也尚无证据将手机服务阻塞归因为此几何错误。新增Mac解码槽收到帧至非零drawable呈现时间的有界数值统计（p95/max，最多7200样本，拒绝无效/负时间），以及无效呈现时间回调计数；不采集像素、不包含Android抓取/网络/解码或物理输入，不能称端到端延迟。新计时与多屏修正的真机结果尚未取得。

后续同时修正错误后的继续操作：普通应用打开在旧相机清除ACK失败时不再发起新launch；诊断若观察到原生pumpFailure，立即结束该轮观察，清理后也不再切换下一应用，并记录cameraFrameClearAcknowledged。此门槛只确认旧图像清除命令响应，不等价于相机关闭或系统服务恢复；真实关闭仍按OwnedCameraCleanup和恢复journal核验。新失败门槛尚未在已阻塞的手机上验证。

机主重启并解锁后，生产恢复清理成功、旧journal消失。虚拟相机服务经既有help入口预热后正常；097985f在同一主屏完成微信/支付宝真实扫码与返回、清除ACK和退出清理，三项系统服务仍健康。两应用校准约743/727ms；约250ms主线程暂停期间仍呈现13/11帧。微信呈现间隔p95约16.67ms、最大50ms；支付宝p95约33.33ms、最大66.67ms。新帧龄暂记约81ms，但该版采样端使用systemUptime，不能仅凭该轮认定跨时钟延迟：本机静态对照与CACurrentMediaTime相差不足0.001ms，仍统一改用CACurrentMediaTime后再验证，避免睡眠语义等变化。实际物理拖动和长时间稳定性仍未通过，不将先前系统服务超时视为已解决。

同一7a80792候选的CA统一时钟A/B（均同主屏、无并行CUA截图）：同步与`--native-unsynced-presentation`两轮均完成微信/支付宝测试码识别、返回、清除ACK和退出，journal消失，三系统服务健康。同步时两应用Mac解码槽到呈现p95约80.49/64.82ms；显式关闭本层displaySyncEnabled后约64.77/64.90ms，仅微信这一轮约改善一帧。呈现间隔p95同步约16.67/33.33ms、不同步约19.05/16.67ms，最大约50/217ms与58/183ms，长间隔仍在，不能称零卡顿。两轮编码器均回报latency=1帧；这不是完整手机到Mac的延迟测量。

不连手机、无录屏的同一纯色窗口辅助对照：双缓冲且每次回调记录CA时间，8秒结果的提交至非零呈现p95约66.69ms（不透明同步）、66.69ms（透明同步）、50.04ms（透明且本层不同步）。另60Hz Timer对照未明显优于CAMetalDisplayLink。不能将纯色实验数字转为产品表现；它只证明部分显示尾部无需Android也能出现。`--native-unsynced-presentation`只影响已显式启用的研究原生层，CAMetalDisplayLink仍负责约60Hz调度，系统显示设置和普通/已安装默认行为不变；尚无物理拖动或撕裂等视觉验收，不据一轮就更改默认值。

随后单应用长hold尝试未进入扫一扫：没有目标activity/可读首页样本，诊断未点击其他页面，已正常退出、清理且服务健康，因此没有取得60秒数据。改用显式manual-navigation从候选原生界面核对：恢复的应用停留既有页面，已仅返回首页并打开原生“＋→扫一扫”，未操作页面正文或发送消息，未将这些页面写入仓库或诊断文件；长时间结果另记。自动测试入口对恢复页面的处理仍不完善，不能把该轮未开始归为渲染停顿。

7a80792手动入口长观察仍未通过：原生层约13秒后随scannerStateChanged结束（owner/stream代次变化、activeStreams=0），不能将设定的60秒写成持续60秒有效呈现。清理、相机闭合确认及journal删除成功，三系统服务健康；不知页面变化由何触发。9ff4156因此新增实际观察秒数及AppKit可见/遮挡/最小化独立计数（非互斥，不能相加推导时长），提前结束即退出观察，并仅记录owned display是否仍有activity、是否仍为同应用的布尔值。

9ff4156随后一轮在准备阶段未确认有效呈现：window visible-region、screen intersection均true，但160次GPU完成的呈现时间均不可用；诊断未执行暂停或长hold，正常清理、journal消失、服务健康。同一时段CUA对自有空闲候选报SCStream -3811，重建工具会话未恢复；不连手机的纯色同driver对照仍有468次非零呈现、CA帧龄p95约50.03ms。因此不能简单归因录屏授权、全局锁屏或手机服务。继续补数值化phone view/ancestor隐藏、visibleRect、layer挂载及drawable尺寸；进入已认证native scanner时强制隐藏旧HOME picker并恢复phone view。组件覆盖picker隐藏→native恢复且不会露出旧视频层；此修正尚不能证明前述零呈现的根因。

fcf865f定向双应用复验通过：微信/支付宝均识别、返回、清除ACK和退出清理，journal消失、三服务健康。CA帧龄p95约62.23/64.83ms、呈现间隔p95约16.67/33.33ms、最大约52.35/133.33ms。挂层前phoneHidden/hiddenAncestor均false，所以这一轮不能证明之前零呈现来自picker，也不能将通过归因为强制显示修正。数值快照同时观察到两应用挂层前phone预览约327.12×711pt、随后约312.40×679pt，进入阶段几何变化仍在。

后续取消native模式对fullSizeContentView样式的进入/退出切换，保留原生AppKit标题栏与内容布局，移除配套的自定义标题拖动转发；只对手机图像区域做透明合成。组件断言picker恢复、进入前后NSWindow frame和phone frame完全一致、标准titlebar样式保留、退出后旧视频/输入状态恢复，已通过；真机前后几何和手感仍须复验，不把32pt观测直接归为唯一根因。

a169b39复验：第一次启动未取得唯一USB设备，未执行扫码；连接恢复后重跑，支付宝真实测试码识别、返回、清除ACK及清理通过。进入前后phone预览均约327.12×711pt，标准标题栏修正消除了该轮此前观测到的32pt高度变化；250ms主线程暂停期间解码16/呈现11帧，CA帧龄p95约63.32ms，呈现间隔p95约33.33ms、最大约100ms，仍存在长间隔。微信该轮目标activity和图像均有107次样本，但没有识别到允许自动点按的固定首页/扫码标签，测试未继续点击，不能记为微信扫码通过。退出journal消失，三个手机服务均及时返回。另修正私有检查脚本将相机历史日志中的timeout字样当作当前超时的误判；本次media.camera约263ms完成、没有dumpsys超时标记，不将历史文字当作新服务阻塞。后续CUA明确报告Mac锁定，真实拖动未验收；权限和已安装build41未改，候选不发布。

机主解锁后的a169b39手动入口尝试：CUA可读窗口AX树，但截图报SCStream -3811，未取得可供点击的真实手机画面；手动等待到期后正常清理。随后自动长hold尝试两应用均进入原生scanner，但微信165次、支付宝158次GPU完成的呈现时间全部无效；因此没有执行暂停和60秒观察，不能当作长时测试通过。两应用phone进入前后仍均约327.12×711pt，退出无journal，三个手机服务约40–352ms返回，screenPermission保持true。

无手机、无录屏的私有窗口对照：简单Metal窗口先取得472次有效呈现；实际ControlWindowController纯合成窗口随后无有效呈现，调整分组/层级/激活顺序/根图层/透明背景均未恢复。但最后复跑简单窗口同样只有3次回调且呈现时间全无效，故不能据非同时的结果认定产品视图或某一个窗口flag是根因；这些失败变体未合入产品。只读显示元数据观测中三显示器均active/online且不休眠，当前会话onConsole=true、锁定字段未提供；这些值也不证明窗口已经真实呈现。当前具体缺口是可重复的Mac有效呈现环境及实际物理拖动证据，不能归为手机系统服务再次卡死或要求重置TCC。

2026-10-28研究续接：同进程同时显示简单Metal窗口与产品手机视图，两者均持续约60Hz并跨过250ms主线程暂停（有效呈现475/476次），进一步否定仅凭先后实验归因视图层级。相同产品视图的并行显示链路/Timer对照均有效约471次，提交至呈现p95约50.04/43.61ms；这一纯合成阶段差异不足以更改默认时钟，也不是端到端响应速度。df2e333真机支付宝识别/返回/清理通过，Mac解码槽至呈现p95约48.49ms，结果切换附近仍有最长约300ms间隔；微信确认首页后首次plus未展开菜单，旧诊断不再重试。7f7f23c只在重新识别同首页/真实plus且owned activity未变化时允许最多3次、间隔至少800ms重试，合成OCR/图标及预算回归通过；未据此宣称微信真机入口已修复。

显式研究参数`--native-batched-calibration`将九帧采样间的逐帧手机状态RPC集中到采样边界：仍启用黑底就绪检查、40ms间隔、九个不同帧序号和原中位数算法，镜像代次失效立即停止槽，采样后、发送蓝底前及挂层前保留owner/generation/route核验。默认关闭，正常安装入口不变；这一候选的安全检查、真机开场耗时和显示质量待复验，不因减少RPC直接宣称已流畅。

129c153同包USB A/B：原始与批量边界校准两轮微信/支付宝均完成测试码识别、返回及清理，journal消失、三服务健康。采样内状态查询8次变1次；从黑底候选就绪到九帧齐备约378→339ms（微信）、435→337ms（支付宝），但完整校准约671→962ms、1026→784ms，黑底初始就绪/蓝底确认差异仍明显，不能凭单轮认定开场整体变快。四项Mac解码槽至呈现p95约46–48ms；批量微信移动阶段仍有约183ms呈现间隔、源收帧间隔约199ms，未达到零卡顿。真实物理拖动与视频等价仍未验证。

独立只读审查随后指出旧帧重试和挂层前状态窗口两处边界：修正诊断保留帧receipt/generation，只使用本轮导航后、绑定当前独立镜像route身份及代次的观察；plus重试需收到严格晚于上次tap、最近1秒内的新帧，状态RPC之后再确认预算及帧时间。挂层前补一次新的phone.cameraState与overlay.matches核验，再保留取消/路由/代次guard。新增合成旧帧、过期/未来时间、新帧与预算回归并通过；全量Mac源码warnings-as-errors编译/链接通过，生成的可执行文件没有运行。这一修正后的源码尚未进行前台真机复验，不沿用129c153的通过结果冒充新版本验收。

当前前台交互验收已停止，后续任何会打开测试窗口、自动启动手机应用或切换Mac前台的测试须先取得机主明确同意。后台继续限于源码审阅、无窗口合成测试、编译和保存，不自动重启/安装App或恢复前台测试。

后台GPU合成优化（2026-10-28）：将blue原生像素提取和常规缩放融合为一遍compute，保持原RGBA8中间量化语义后再对四个源像素作双线性插值，不重绘任何手机控件。任意轴缩小超过2倍时保留Core Image原重建路径；blackWhite算法、非BGRA8目标、无shaderWrite能力及融合shader/library或pipeline不可用时也回退原路径。新增无窗口render(into:)与实际present共用编码器，统计记录fusedCompositionSubmissions/referenceCompositionSubmissions以供未来确认真实drawable提交时选择了哪条路径，不能将提交数当作有效呈现帧数。

合成像素回归覆盖非对称彩色/透明前景、移动绿线、放大/常规缩小/强缩小、单行单列和格式/usage回退；融合与参考输出逐字节差异≤2且保持预乘alpha。最终独立shader/library版本中，720×1565→646×1404的40对交替样本，CPU编码p95约0.0687→0.0404ms、GPU p95约0.6377→0.5014ms、中位数约0.3603→0.2731ms。较早一轮GPU p95约0.6034→0.4251ms，运行间波动存在，不能给出普遍性能保证。另只创建不附着窗口、不present的8×8 CAMetalLayer纹理读取能力，当前主机usage=23包含shaderWrite；这不证明可见呈现或真实扫码。原透明度/跨实例校准隔离、时间统计回归及全量warnings-as-errors编译/链接通过，App没有运行。以上仅合成阶段结果，不能外推手机到Mac的响应速度或参考视频等价；独立只读复核要求明确提交数并隔离可选shader编译，已修正并复查；最新融合路径尚未前台/真机验证，不替换安装版或发布Release。

批量校准的新帧等待改为事件通知（仍只在`--native-batched-calibration`研究路径启用）：decoded slot继续只保留最新一帧、最多一个等待者，以新revision和CA receipt的notBefore门槛维持九帧及至少40ms间隔；已花在状态RPC上的时间不再额外叠加到sleep中。黑底就绪与蓝底确认等新publication唤醒；蓝底确认后再复核owner/state，App挂层前仍做独立核验。普通非batch采样保留原轮询/延时。stop、取消和发布在锁内摘除waiter、锁外resume；UUID限定取消自身请求，结构化timeout分支会取消并等待剩余子任务，不遗留等待任务。

纯CPU合成验证通过latest-only、时间间隔过滤、断流唤醒、超时后恢复、并发拒绝、100次预取消及100次publish/cancel/stop竞态；发布至await恢复p95约0.04ms，仅说明通知机制，不能当作扫码开场或真实手机延迟。解码观察者替换/reset/stop/冻结及主线程阻塞回归通过，全量warnings-as-errors编译/链接通过，App未运行。独立只读复核未发现新的continuation、取消、timeout或采样间隔缺陷；新事件路径与上一轮GPU融合均仍待经机主允许的前台真机验收。

机主明确允许约1–2分钟前台测试后，af85c5e同签名候选在约32.6秒内完成一轮双应用测试：微信/支付宝真实识别、返回、清除ACK与退出清理均通过，journal消失，三个手机服务正常响应；随后停止前台操作。两应用融合提交388/366次、reference提交均0，有效呈现387/364次，确认本轮真实drawable使用了融合管线。主线程暂停约250ms期间解码22/17帧、有效呈现15/12帧；程序移动阶段与识别交接整体呈现间隔p95约16.67/33.33ms、最大33.33/66.67ms，Mac解码到呈现p95约47.12/64.67ms，GPU p95约6.13/3.30ms。该轮仅程序移动，不是物理鼠标拖动验收，也不证明长时间稳定或视频等价。

开场校准仍约906/971ms，未显示整体启动已明显加速。黑底就绪后九帧收集阶段约381/476ms，蓝底ACK到镜像确认约207/183ms；通知机制的纯CPU微秒级数据不能替代这些真机等待。只读继续检查发现Android painter在无输入时先绘WHITE（LiveCameraServer.paint），之后才绘认证的黑/蓝输入；这只是待对照的开场白底/绘制时序假设，尚不能认作900ms等待的根因。本轮未改Android底色或协议，未再启动前台测试，未替换安装版、重置权限或发布Release。

机主随后要求继续验证，af85c5e单微信原生预览持续约60.05秒，窗口可见1151次采样、无遮挡/最小化采样，活跃扫码退出核验、清理和三个手机服务均正常；整轮约70.8秒。记录到一次标题栏down、313个dragged和一次up，窗口最大位移约175pt，按下/松开的WindowServer边界位移约6pt；工具drag调用返回未激活错误，不能将这些事件归因于一次成功的工具拖动或声称手感验收通过。有效呈现3071/3549次回调、478次时间不可用，p95约16.67ms、最大有效时间间隔约1016.66ms；26个超过50ms间隔集中于开头约3.4–12.4秒，解码间隔最大约39.13ms、GPU最大约7.67ms。无法仅凭这些时间戳判断真实停画或区分抓图与拖动影响。

CUA窗口图把原生控件上下倒置，但机主直接观察明确回复屏幕显示正常。因此撤回仅据该抓图认定软件方向错误的结论，不翻转renderer或改权限。追加`--diagnostic-native-short-hold`仅把显式hold诊断从60秒缩到20秒，以减少后续无抓图对照占用；正常产品与既有默认60秒hold不变。

b35959d无抓图短对照：同一产品显示管线持续约20.05秒，整轮约28.3秒；未调用CUA、无本窗口down/drag/up事件、窗口位移0。有效呈现1199/1205次回调，时间不可用6次，呈现间隔p95约16.67ms、最大约50.00ms，超过50ms间隔0；解码到呈现p95约43.04ms、GPU p95约2.38ms。活跃扫码退出、清理及三个手机服务均正常，journal消失。该静止对照未复现前一轮的秒级时间空档，但不能单独分离抓图、拖动和其他时序差异，不能据此断言某个工具或系统组件是卡顿根因。

机主进一步确认第一轮是本人手动拖动，主观反馈“比较流畅”；与本窗口拖动事件及位移记录相符。这是一次真实使用反馈，不是物理输入到显示的延迟测量，也不证明参考视频等价或长期无卡顿。截取图与实际屏幕方向不一致的原因仍未知，不据该图翻转产品。验证后不再启动前台窗口；默认安装版未替换、TCC未重置、未发布Release。


后台纯色校准协议候选（2026-10-28）：仅当显式`--native-batched-calibration`且已认证手机状态报告`solidCalibrationSupported=true`时，黑/蓝背景改走命令25，payload固定9字节（8字节大端非负epoch，1字节颜色0黑/1蓝）。服务端只在desktop-home、realtime-video、非mirror-only模式接受，仍在stateLock内确认真实扫码owner，按stateLock→cameraLock赋值并绑定cameraStateGeneration；过期epoch不改画面，owner/route失效、清帧与后续真实图像均清除填色。仅以同一720×1280源尺寸、原旋转/aspect-fit/整数rect替代PNG解码后的绘制，保留白边，不画任何自制手机控件。ACK只统计赋值和排队，不代表Surface已画出或手机已识别。

旧服务缺少/空能力字段时仍走PNG，非批量路径保持PNG；新能力不绕过scannerActivity归属检查，不改变九帧、至少40ms间隔、新revision蓝底确认或挂层前复核。新增JVM固定payload解析与Swift能力/编码边界测试，覆盖空/错误长度、负epoch、大小端、非法颜色及非Bool能力；源码检查保留未知owner拒绝。尚未真机比较新协议的总开场耗时，也未逐像素验证非16:9 Android Canvas；不能把省掉两次PNG传输/Bitmap解码直接当作视频等效或整体延迟改善。当前仅准备研究候选，不替换安装版、不改TCC、不打开前台测试。


本候选后台验证：JVM固定9字节解析、Swift编码与能力/owner解析测试通过；CPU-only帧等待回归含取消/停止/超时、唯一revision、采样间隔及100次竞争通过；全量Mac源码warnings-as-errors编译/链接、全量Android Java编译与DEX构建通过，未启动生成的App。独立只读复核未发现新的锁序、能力绕过、旧填色残留或采样门槛变化；服务端真实owner/epoch/generation状态转换与Android Canvas像素仍须真机验证。未将此前版本的扫码结果沿用于本候选。


2026-10-29真机A/B准备：`--native-png-calibration`仅覆盖研究校准发送选择，与`--native-batched-calibration`联用时保留全部新帧等待、采样及状态检查，以同一签名包/同一Android服务对照PNG和solid。默认选择不变。报告新增black/blue request和processing耗时（ACK赋值/解码成本，非实际paint），以及明确标签`scannerTapToNativeAttachedMilliseconds`：程序在真实扫一扫控件发出内部tap，到原生层挂载的时间，不包含用户找入口、物理鼠标延迟或首像素测量；无本次有效tap则不填写。真机数据尚未取得。


## 纯色校准真机对照（2026-10-29）

实测候选源码`031e7b4`，同一签名App、同一Android服务、唯一已授权USB手机；研究参数`--native-camera-preview --native-batched-calibration`固定，A仅加`--native-png-calibration`，B走已认证能力协商后的solid。安装版仍为build41/9444951。为不把无效入口当测速，早期自动导航失败、人工导航超时/取消、只读导航探针均不进入以下比较；它们的会话也正常清理，未改TCC。`--diagnostic-navigation-settle`仅在真正扫描tap前等2秒，不计入tap→attach或calibration。

支付宝单应用范围：`--run-desktop-diagnostic --diagnostic-usb --diagnostic-primary-screen --diagnostic-navigation-settle --diagnostic-alipay-only`。按A-B-B-A、B-A-A-B共8轮，每轮`solidCalibrationSelected`与参数一致、真实合成纯文本码识别、返回及清理通过，journal消失，screenPermission持续true。此处的passed仅表示支付宝选定范围，不冒充双应用通过。内部tap→attach起止为扫描控件输入派发到原生层挂载，不是物理输入/首像素；calibration为prepare开始到新蓝底确认，也不是扫码结果等待。

| 顺序/方式 | tap→attach ms | calibration ms |
| --- | ---: | ---: |
| A3 PNG | 1178.743 | 982.889 |
| B1 solid | 799.305 | 654.816 |
| B2 solid | 870.330 | 723.691 |
| A4 PNG | 872.477 | 634.615 |
| B3 solid | 901.503 | 683.634 |
| A5 PNG | 760.610 | 533.298 |
| A6 PNG | 767.610 | 612.225 |
| B4 solid | 831.383 | 665.346 |

各4次：tap→attach均值PNG894.860ms、solid850.631ms，平均差44.230ms；但中位数PNG820.044ms、solid850.857ms，未见稳定整体提升。calibration均值690.757→681.872ms仅差8.885ms，中位数623.420→674.490ms。两次背景Android ACK处理总和均值19.864→0.334ms，说明赋值/解码微步骤实际减少；不包括真实Surface paint、Mac PNG生成或用户首像素。黑底候选就绪到九帧齐备平均390.666/391.031ms，此阶段仍远大于背景处理成本。样本小且初始/热身差异明显，不用单次最好值或均值差宣称加速。

微信在同包中改用`--diagnostic-manual-navigation --diagnostic-active-scanner-exit`，由界面工具仅操作真实加号/扫一扫（必要时从当前页返回首页）；自动入口尚不稳定，导航本身的等候不算calibration。有效校准顺序M4 solid746.180ms、M5 PNG714.089ms、M6 solid775.984ms、M7 PNG776.619ms、M8 solid812.496ms。PNG2次均值/中位745.354ms；solid3次均值778.220ms、中位775.984ms，仍未见开场提速。手工入口没有本轮可用的内部tap起点，因此不填tap→attach；不能将校准数字冒充微信完整打开时间。这5轮是预览/活跃扫码退出测试，没有运行微信合成码识别，不复用旧版本识码结果。

M4/M5/M6立即退出模式有效呈现1/1/0次，不当作持续呈现验收。M7/M8额外`--diagnostic-native-hold --diagnostic-native-short-hold`分别运行约20.04/20.02秒，可见384次采样、无遮挡/最小化采样，有效呈现934/1065次，GPU失败0且回调收齐；呈现间隔p95约50.00/16.67ms，但最大时间戳间隔两者仍约1秒。未测物理输入到显示，不据时间戳直接判真实停画，也不据单轮p95称已达到参考视频。镜像截图曾出现重复标题，实际菜单以上方真实加号触发；这不证明截图问题或产品绘制的根因。

只读导航探针只输出尺寸、像素格式、亮度抽样统计及固定导航标签，不保存任意OCR/手机图像。曾取到启动黑帧，等候后有正常导航标签；同帧锁前/锁后/物化识别未证明是CPU读取故障。探针单列`test=navigation-frame-probe/performanceMeasured=false/probeCompleted`，不混入产品测速。原始诊断和数值汇总留本地忽略目录，不上传设备标识、运行配置或手机内容。

末轮结束已核对本候选进程不存在、恢复记录不存在；virtualdevice、virtual_camera、media.camera只读检查约57/47/330ms，均正常响应。全部测试沿用已有录屏授权，没有重置TCC、重新配对、修改证书/系统信任、替换安装版或发布Release。结论是处理微步骤优化成立，稳定整体开场提速尚未成立。


## 通用桌面相机重构（2026-10-29）

连接窗口增加明确选择的“桌面相机（通用）”，首次默认关闭，只在选中设备时保存该偏好。它是本次所选应用窗口的相机来源选择，涵盖扫码、拍照、视频，不能通过 CameraManager 所有者事件推断用途。未选择时保留原精确扫码页面路由；选择后跳过 NativeScannerOverlay 九帧校准、本机 QR 预检及送一帧后自动交接，原 App 镜像继续显示，另用本地透明开口持续供图。开口拖动仍由 WindowServer 显示实际桌面，发送目前为停稳 180ms 后最多 8fps；这不是手机识别响应速度或整套视频效果的保证。

认证通道命令26使用有界1–260字节请求：`[2]`选择连接来源；`[1]+Int32BE(display)+UTF8(package)`绑定；`[0]+Int32BE(display)`清除。所有显示必须由本连接拥有，包必须属于已认证的主用户 launcher 目录并声明 CAMERA。绑定回复1为已绑定、2为明确未声明相机权限（普通应用仍可打开），清除回复0；其他回复拒绝。liveState 的 supported/enabled/generation/bindings 与 owner、activities 联合决定路由，同包多窗口或不明 owner 停止供图，不增加 App/page 白名单。

虚拟设备范围的授权与回收在 cameraPermissionLock 串行执行；先撤销绑定、推进图像代数并清帧，再撤销无引用的临时权限。Binder grant 前记录待回收包，失败补偿；先前不确定的 revoke 保留在集合内，后续 clear 再尝试。客户端共享启动事务在绑定或应用启动失败时补偿 clear，补偿失败明确断开并保留原有恢复机制。仅成功启动且不在关闭中的独立窗口可成为采集目标。每个图像仍受 epoch/owner/generation 检查；取景位置变化丢弃旧帧，隐藏/最小化原 App 暂停供图。

新增 `DesktopCameraRoutingTests.java` 验证有界解析、任意第三包/任意页面路由、错误归属/歧义拒绝、代数失效和 grant/bind 回收；`GenericDesktopCameraTests.swift` 验证相同第三包状态、无二维码图像不触发检测、旧路由隔离、双屏取景框位置、协议回复和失败补偿。隐藏窗口回归检查通用开口透明、按钮语义和未展示窗口；独立窗口夹具覆盖 pending/ready/关闭/失败回收目标，不连接真实手机。

这些后台测试不能证明第三款真实 App 接受虚拟设备或性能改善。已安装 build41 保持不变，录屏授权不重置，未运行新的手机 App 或发布 Release；需要对通用路径另做真实 App 兼容与耗时验收。

本轮后台验证：上述 JVM 与 Swift 通用协议/路由测试、原 PhoneCameraState 路由回归、CameraPumpMailbox 旧帧/并发回归、隐藏 LocalScanFrame 透明与控制回归、DetachedApplications 假手机生命周期回归均通过；全量 Swift warnings-as-errors 优化编译/链接、Android Java/DEX/测试 APK 构建及测试签名校验通过。独立只读复核发现并修复“legacy 关闭独立窗口误撤兼容授权”的回归，新增 disabled/共享引用/最后引用/重试策略测试后复查未发现遗留问题。未运行测试 APK、候选 App 或手机扫码。


## MiraDroid 更名（2026-10-29）

用户指定改用英文名，本轮采用 MiraDroid，候选 build43。仅更新菜单/关于、CFBundleName/DisplayName、构建 App/ZIP、后续发行命名与使用文档。CFBundleIdentifier 仍为 `com.idc006.DesktopWeChatScanner`，可执行文件名、持续签名身份、原有偏好/恢复路径及 GitHub 仓库地址保留；不自动替换当前安装或修改 TCC。NOTICE 保留原名出处及原有版权信息，旧发行与历史记录不改名。

更名前 build42 源码4b020d6已签名打包，包内源码与 Android JAR 逐字节核对，签名要求与已安装版一致。经机主允许，界面勾选通用桌面相机并通过 USB 连接，握手、实际应用目录展示和正常断开通过；之后截图接口返回 ScreenCaptureKit -3811 捕获错误，未继续操作第三款 App，不能记为第三方扫码或耗时通过。已从界面断开并退出候选；未修改录屏权限。


## 通用模式真机验证（2026-10-29）

实际受测 App 为已签名 MiraDroid build43，包内源码 `08e636f37224a2698f9d97e89a8eaffc3c25196f`；ZIP SHA256 `0b699ad21d880e42d788bf1f1188f8180eaf89236c2501fe6aaea5a59a114495`。本次新增的集成夹具与记录不改变该包的生产源码或签名；安装版、TCC 与公开 Release 未改。CUA 在准确候选路径及重建会话后仍返回 ScreenCaptureKit -3811，系统元数据确认 Mac 未锁、候选在运行且窗口在屏；不把它误判为用户未授权，也未反复申请权限。改用 App 既有 `--run-desktop-diagnostic --generic-desktop-camera --diagnostic-usb --diagnostic-primary-screen --diagnostic-navigation-settle` 原生测试入口，不模拟 OS 输入，采集仅放行自有合成测试板。

首先限定 `--diagnostic-alipay-only`，约20.62秒结束：支付宝真实扫一扫识别固定测试明文，自动透明框、暂停/恢复、同代丢帧确认、返回/重开、清帧与退出清理均通过。随后默认双应用约32.96秒结束，微信和支付宝分别通过同样流程；两次运行均 exit0、passed/cleanupSucceeded/screenPermission 为true，恢复记录消失。nativeScannerPreviewVisible=false、nativeCalibration缺席，与所选通用路径一致。微信识别时透明框仍在，不套用旧“交接后必须关框”判据；结果文字来自真实手机镜像，不将相机 ACK 当识别。

六秒**程序移动**自有透明框的数值（未使用真实鼠标输入）：

| 运行范围 | App | 窗口tick p95 / 最大(ms) | ROI位置误差p95(pt) |
| --- | --- | --- | --- |
| 单支付宝 | 支付宝 | 16.893 / 17.468 | 0 |
| 双应用 | 微信 | 17.499 / 17.669 | 0 |
| 双应用 | 支付宝 | 17.516 / 41.033 | 0 |

这不是物理输入至画面的端到端延迟，也没有本轮内部 tap→透明框/首图的同口径新旧对照；不能据此填写开场“快了多少”或称视频等效。旧校准约700–1000ms的数据与这组tick不能相减。

### 第三应用与失败证据

只读确认手机未安装 `com.xiaomi.scanner`、已安装 `com.android.camera`，因此使用新增 `tests/GenericCameraDeviceIntegration.swift` 通过生产 PhoneSession API 的正常应用目录启动系统相机，不使用 Activity 捷径、OS 输入、额外安装、桌面采集或像素落盘。夹具只在内存匹配本轮 UUID 合成 QR；ACK后的镜像帧先确认preview，再以更晚帧确认结果文字。报告区分 `cameraDeliveryPassed` 和 `appRecognitionPassed`，整体 `validationScope=third-app-camera-input-delivery`，不将预览当识码。输出只允许 `.local/generic-camera-tests` 的新文件，O_EXCL/0600，路径越界和既有文件拒绝测试通过；warnings-as-errors 编译、独立只读复核通过。

系统相机两轮都确认绑定，但8秒内 activeStreams=0、ownerKnown=true，未进入供图：

- 首轮启动事务约602.72ms，cameraNotOpened；首次断开未确认、保留恢复记录。停止夹具后，用既有自有恢复器完成清理，记录消失；服务检查均正常，无重启或系统服务终止。
- 补充失败观察后仅复测一次：启动事务约361.82ms，镜像正常收到121帧，相机owner为空、虚拟流0；固定UI提示词仅命中“拍照”，未自动点击任何提示。仍为cameraNotOpened。该轮cleanupStage=complete、关闭确认true、休眠前流0、会话记录消失。

上述启动事务是目录打开/任务确认等后端耗时，不是扫一扫打开速度。两轮只能证明**本次未观察到系统相机打开受控虚拟相机**，不能仅据此确认 ROM/App 不兼容、权限弹窗、物理相机绕过或具体根因。第三应用的相机供图与识码均不计通过，微信/支付宝结果也不外推所有 App。最后三项系统服务约48/44/255ms返回，Mac测试进程及窗口为0，phone session记录不存在、App connected/cameraActive=false、screenPermission=true。

夹具要求显式 `--run-device-test --resources /准确路径/MiraDroid.app/Contents/Resources --package com.android.camera --locked-applications --output .local/generic-camera-tests/唯一新报告.json`；只在已有相应锁屏授权与唯一USB设备时使用该锁屏参数。原生GUI自检与该后端夹具不能同时运行，失败保留会话时先恢复，不叠加新测试。运行原始记录与OCR/像素不入仓，仅保存本节脱敏结论。


## 首次取景等待优化（2026-10-29）

build44候选仅优化首次generic区域：送图泵尚无target且没有任何此前move/retry的captureNotBefore时，初始区域可立即开始取景；否则继续等待180ms，绝不缩短已有截止点。onMoved、刷新、revision/epoch/owner验证、暂停与关闭逻辑未改。新增CameraPumpMailbox回归包含首次立即、已有移动截止点不被覆盖、后续区域继续稳定期、兼容模式仍等待、停止不可恢复及首ACK快照。

原生自检的 `--diagnostic-initial-settle` 只在 `--run-desktop-diagnostic` 入口生效，把同一generic路径恢复为原首次180ms等待，用于同包对照。报告显式记录genericDesktopCamera与initialGenericSettleSelected，先保存初次pump计时，再执行原暂停/重开回归，避免把后续pump归成首次。

新增计时从自身镜像输入派发的uptime开始，desktopCameraReady指ROI发布且后台送图泵已启动；firstFrameAcknowledged指同代当前区域图像请求返回手机处理ACK。不是物理输入、首个显示像素、手机绘制或识别结果。若没有本轮扫描点击或有效初ACK则不填数值；为观察初ACK最多额外等待3秒，不主动接受权限或跳转任意App页面。默认和180ms对照尚待同包USB实测，不以理论节省等同实际快180ms。

系统相机继续只读检查：仅按该App进程过滤最近300条warning，在内存匹配固定的相机ID/权限/会话/后台拒绝等类别，未输出或保存原始日志；八类匹配均为0。该有界筛选未定位原因，不能由零匹配认定没有错误；不扩展读取其他App日志或靠修改系统权限试错。官方[AOSP虚拟相机说明](https://android.googlesource.com/platform/frameworks/av/+/refs/heads/main/services/camera/virtualcamera/README.md)描述标准Camera API消费者与EXTERNAL能力/限制，这是通用来源路线的依据，不能据此断言小米系统相机为何没有打开流。


## 首次取景同包对照与复核（2026-10-29）

App build44安装包源码 `794d923ea3b8bd47a81b927e45ef6c22717b1900`，ZIP SHA256 `3f5fadd120e3a1599ed9eeba80e5b8891a65b2e812c61ccbcc4653a62b339c86`；全量Swift warnings-as-errors优化编译/链接、CameraPumpMailbox回归、完整Java/DEX与签名打包通过。包内源码/JAR回读一致，签名要求与原安装相同；原build43 ZIP已保留有效恢复点。独立只读复核确认首次优化不覆盖已有fence、后续区域与兼容行为不变；当时README候选版本口径不一致已修正，再构建。

同一USB小米、同一包、同一支付宝与原生合成板路径，A=显式 `--diagnostic-initial-settle`、B=默认首次立即取景，顺序A-B-B-A。均使用genericDesktopCamera=true，selected模式与参数一致，各轮真实合成文本识别、暂停/恢复、返回/重开、清帧/退出通过，权限持续true、无journal。

| 轮次 | 内部tap→送图泵就绪(ms) | 泵就绪→首图ACK(ms) | tap→首图ACK(ms) |
| --- | ---: | ---: | ---: |
| A1 等待 | 204.771 | 373.286 | 578.057 |
| B1 优化 | 134.810 | 147.121 | 281.931 |
| B2 优化 | 178.823 | 210.009 | 388.832 |
| A2 等待 | 113.940 | 376.258 | 490.198 |

表格四舍五入到三位小数；均值和差值按未舍入的原始数值计算。各模式2次，tap→首图ACK均值534.128→335.382ms，这4轮内减少198.746ms（约37.2%）；泵就绪→ACK均值374.772→178.565ms，减少196.207ms。tap→泵就绪均值159.356→156.816ms基本相近，因此这组改善集中在取景启动后的供图段。仅对这组小样本描述，不承诺普遍缩短、识别速度或手机首次绘制；不能与旧native layer/calibration指标直接比较。

### 双应用反例与调用栈观察

默认B路径随后两轮微信/支付宝完整识码、暂停/恢复/返回/重开、同代丢帧与退出清理均通过，但没有稳定达到视频效果：

| 非采样运行 | App | tap→首图ACK(ms) | 窗口tick p95 / 最大(ms) |
| --- | --- | ---: | ---: |
| 第一轮 | 微信 | 901.193 | 31.163 / 145.621 |
| 第一轮 | 支付宝 | 465.689 | 19.164 / 61.107 |
| 复核 | 微信 | 759.665 | 17.474 / 139.108 |
| 复核 | 支付宝 | 218.774 | 17.474 / 17.636 |

各轮ROI位置误差p95=0，移动期间发图数=0；这只能支持坐标与发送门槛，没有测真实鼠标拖动延迟。第一轮微信已计时几何最大约1.00ms、镜像呈现调用最大约1.67ms、窗口移动调用最大约14.82ms，未覆盖整个145ms间隔，不能归因于这些已量测调用中的某一个。

随后仅对本次创建的自有GUI进程进行8秒/10ms间隔 `sample`，原始调用栈留本机私有目录，不采集其他App、像素或正文。样本显示主线程存在RunLoop正常等待、Core Animation提交/同步，以及合成板ScanPerformancePattern.draw工作；没有据此发现或证明主线程死锁，也不能把调用栈采样数直接当延迟百分比。合成板本身与采样可能影响观测：该受采样轮功能与清理通过，但微信首ACK约2007.848ms、tick最大116.247ms，支付宝约506.801ms/48.555ms；不混入前述未采样A/B均值，不据此将性能差异归为产品回归或某一确定根因。

本次未重测系统相机；Android源及PhoneSession/PhoneCameraState与build43未改变，先前“未观察到虚拟流”的未通过状态保留，固定类别warning筛选没有定位根因。CUA仍无法完成真实鼠标/视觉验收，本次依然不称视频同等效果，不修改已安装App、不创建Release或重置录屏权限。最终回读：自有GUI进程与屏上窗口均为0，session记录不存在、connected/cameraActive=false、screenPermission=true；三个系统服务约45.8/42.8/306.5ms正常返回。


## 元数据准备生命周期重构（2026-10-29）

build45候选将通用来源的SCShareableContent查询移到所选相机应用启动后。后台任务先检查已存在的CGPreflightScreenCaptureAccess，未授权不调用prepare；它只查询可捕获显示器和窗口元数据，不调用SCStream、裁切、编码或phone.frame。前台采集仍保留完整相机owner/binding/revision/epoch校验。主窗与独立窗口只在cameraReady后触发，非相机应用或失败/关闭中的窗口不触发。

CaptureMetadataWarmup负责唯一pending/draining Job；重复start合并，finish取消并等待相同Job，等待期间不开始下一份准备。前台owner的嵌套独占阶段在drain之前禁止新start，跨所有await保持，抛错/返回时恢复；所有正式prepare与换板统一入口，旧runPerformanceCheck也纳入。startCamera、clearCamera、断开和退出统一收束；诊断换合成板前也收束，避免旧元数据请求与新的采集上下文竞争。已完成准备可复用DesktopCapture原有元数据缓存，未完成/失败则由原正式prepare路径处理。没有新增权限申请或后台图像预采集。

显式原生诊断 `--diagnostic-cold-capture-metadata` 关闭此预热，用于同包比较；新增 `--diagnostic-wechat-only` 可限定微信，与alipay-only冲突时拒绝，不扩大该范围通过结论；报告coldCaptureMetadataSelected、metadataWarmupCompleted和startupStages（drain/clear/prepare/verifyOwner/presentAndStartPump、tapToDetection等）。检测前包含镜像输入、Android打开相机、回调及状态轮询，不能单独当作手机处理耗时。原有tap→首图ACK仍不是首像素/识别完成。

`--diagnostic-static-board` 只在原生桌面诊断内冻结合成板持续重绘，窗口仍按相同轨迹移动并正常显示后续测试QR；report.boardAnimated区分工作负载。系统减少动态效果时也不更新该测试条。静态/动态板不能混作同一性能基线，不将降低测试负载称为产品优化。

新增CaptureMetadataWarmupTests的禁止准入、重复start、并发finish、取消/失败/完成复用通过；DetachedApplications假手机回归增加仅ready触发的校验并通过。真机分段及同包对照尚待完成，不预报提速。


build45初次真机对照（包源码6c7abbc）：M1冷准备微信识码/清理通过，prepareMetadata约100.47ms，但下一轮在目录应用打开到独立屏幕时失败，未进入预热计时；复核服务健康、主屏已解锁、无会话遗留后，以各轮统一两秒任务恢复稳定前提重做，M5冷准备通过（prepareMetadata约171.34ms），随后M6仍同阶段启动失败，均清理成功。缺失的预热轮不算性能样本，不计算冷热收益，也不以冷轮约1395/1506ms首ACK证明优化有效。原始失败保留本机；下一步只增加已在启动轮询中的固定placement计数（前台0未知/1目标/2其他、目标任务数、目标包在目标/其他屏幕的数量、混合用户数量），不新增移动、重试或导出任意组件/页面，以定位跨会话重开为何未通过。


### 通用来源启动权限路径（build46候选）

新增`desktop-camera-source`服务启动参数，必须与desktop-home同时使用且不能mirror-only；Mac在创建会话前也拒绝不一致组合。它只取消旧兼容包预授权，不启用路由或授予任何新权限；认证后的命令26选择来源及每个主用户应用窗口的验证/绑定仍为必需。旧兼容入口保留原权限行为。现有范围内ActivityManager微信终止原因筛选未观察到权限撤销记录，不能确认该绕路是重连失败原因；本次以独立启动路径及位置计数继续验证，不预报修复结果。


### build46首包对照及保守收口（源码d4dc090）

同一签名包、USB、微信、动态合成板，顺序预热/冷/冷/预热，统一各轮前两秒稳定条件。四轮应用均成功进入指定屏幕，不再出现本轮旧包第二次启动失败，但缺少同期旧权限路径反向对照，不能确认权限撤销为根因或宣称彻底修复。

|轮次|预热完成|前台prepare(ms)|tap→首图ACK(ms)|识码|窗口tick最大(ms)|
|---|---|---:|---:|---|---:|
|N1 预热|是|0.092|663.966|通过|22.246|
|N2 冷|否|44.004|636.461|通过|33.521|
|N3 冷|否|44.581|589.273|未确认|58.616|
|N4 预热|否|173.916|缺失|通过|315.454|

N3启动、暂停/恢复/返回/重开、清帧及清理通过，但最终未确认手机识码，保留为失败，不混成完整通过样本。N4功能和清理通过但首帧计时字段缺失、drain约58.85ms；不补算或剔除异常来宣称提升。四轮既有录屏权限true、无会话遗留、主屏前后解锁。本轮没有物理鼠标拖动测量。

预热只能在部分轮次消除元数据等待，没有证明点击→首图稳定改善，因此普通产品路径关闭预热，仅显式原生诊断`--diagnostic-prewarm-capture-metadata`可启用；同时指定cold时cold优先。报告metadataWarmupRequested与metadataWarmupCompleted分别表示请求与实际完成，所有前台资源准备仍经过同一生命周期gate；没有放松取景、图像新鲜度或窗口归属门槛。默认路径仍待准确包复验。


### 默认包复验与尚未解决的反例（源码b37574f）

build46默认包ZIP SHA256 `dd4c62f8037178432e712e696cd4f1d55491b1191e9682377198636660e1b86a`；完整构建/签名校验、包内SOURCE与JAR一致、designated requirement与安装版相同。独立只读审查已复核通用启动参数的认证/绑定门槛、启动失败证据生命周期及预热回收gate。JVM启动/路由测试、Swift warnings-as-errors类型检查与元数据生命周期合成测试通过。

准确默认包原生双应用回归中，metadataWarmupRequested=false。微信在导航前未通过前台确认：任务快照固定计数为目标屏幕2个任务、微信主用户任务1个、其他屏幕微信0个、其他用户0个、解析前台类别=其他。它说明任务已位于指定屏幕，但不能单凭解析结果确认实际视觉前台，更不能把权限绕路认定为根因；失败保留，不绕过验证。支付宝真实合成码识别、自动透明框、暂停/恢复/返回/重开、同代旧帧丢弃、清帧/退出通过；tap→泵287.531ms、tap→首ACK607.263ms、窗口tick p95约18.814ms、最大155.737ms，仍存在长间隔。主屏前后解锁、录屏权限true、整个运行退出1，清理成功且无session记录。默认包不算双应用完整通过，不作为正式流畅版本安装或发布。

随后两轮后台对照只调用同版PhoneSession生产API：创建自己的通用桌面会话、目录选择微信、启动、比对Android活动回调与dumpsys固定枚举、退出清理；无Mac GUI激活、无图像采集/导出、无OS输入注入。两轮启动与清理成功，目标显示各有一条topResumedActivity且匹配微信、mResumedActivity条目为0、服务活动回调也匹配。没有复现启动失败，也没有证明“后面任务的resumed覆盖topResumed”假设；未据此改任务前台解析或增加盲目重试。现有偶发前台确认与扫码长间隔继续作为未解决项，原始记录仅留本机，公开仓不包含手机/桌面像素、任意页面/组件或运行日志。


## 任务迁移与恢复重构（build47，2026-10-29）

本轮保持后台，不激活Mac窗口、不重置录屏权限。相同独立锁策略下，无/有直连镜像四轮应用启动及清理都通过，两个HOME后重开也通过；未复现此前GUI前台确认失败，不能据此称其修复，也未更改前台解析、增加盲目重试或改用扫码页面名单。

### 唯一新快照与完整任务组校验

原launch/restore先在调用处读一次任务树核完整组，moveTask又读一次、只查用户与根，最后只查代表任务位置。现在统一moveTasks(expected)：用唯一迁移前新快照同时核预期组的ID/包/根/用户/显示与HOME标记，再执行原am display move-stack；移动后的新快照核所有仍存活的预期孩子及该根是否有未知孩子。每个实际移动根减少一次重复任务树读取，没有删去最终新状态检查。launch仍先为整组写恢复记录；restore仍在全部恢复确认后才移除记录。

该调整也让最后一次新快照拒绝同用户的新异包孩子，而非依赖更早一次组检查；这不等于Android把核验和移动作为原子事务，也不能辨认所有字段完全相同的系统ID重用。已到达整个组可不重复移动，结束的孩子可消失；新孩子、重复ID、重新挂根、跨屏组、其他用户或HOME拒绝并保留恢复记录。恢复仍可接纳此前已在本次显示内确认的完整混包结果页root；启动迁移仍必须整组属于所选主用户App。

OwnedTaskMoveTests合成覆盖上述反例，并贯通真实任务树解析器到混包组迁移/恢复与空异用户孩子的root taint检查；不调用设备、UI或ADB。独立只读审查已复核迁移、恢复及异常时记录顺序，未发现成立缺陷。

### 受控后台真机对照

基线为905cd93中的PhoneSession，候选为本轮PhoneSession/OwnedTaskMove；相同Swift warnings-as-errors非优化后台测试入口、同一未变Java服务、同一USB小米、相同独立锁策略。先在一个自有虚拟显示打开所选App，再创建另一自有显示并启动直连镜像，计时把已有任务迁入后核对前台；每轮迁移前都确认其他显示有一个所选App任务。测试不激活Mac GUI，不点击登录/支付、不保存任何像素或任意OCR，只输出固定计数/布尔/时长。结束恢复并清理全部自有会话。

最初T1没有待迁移的旧任务，预置条件不满足，已停止该组；保留其结果，不混入性能样本。U组两种模式各2次、顺序旧/新/新/旧：

|轮次|内部启动确认(ms)|
|---|---:|
|U1 旧|453.214|
|U2 新|310.210|
|U3 新|324.689|
|U4 旧|423.325|

旧均值438.269ms，新317.449ms，减少120.820ms（27.57%）；四轮前台解析与Android活动回调均匹配、恢复成功、无session遗留。但新模式两轮结束计时前尚无已解码帧，不能用该表证明用户已看到画面。

随后V组保留同样顺序，在内存增加确认后新解码帧及原App固定界面标签验证；两种模式仍各2次：

|轮次|内部启动确认(ms)|启动确认后首个解码帧的时间戳，距启动(ms)|固定原App界面确认|
|---|---:|---:|---|
|V1 旧|484.082|489.408|通过|
|V2 新|315.628|521.100|通过|
|V3 新|328.014|488.797|通过|
|V4 旧|446.990|481.213|通过|

内部确认均值465.536→321.821ms，减少143.715ms（30.87%）；解码到帧未见稳定改善。表中是后台解码接收时刻，并非Mac呈现/物理输入延迟、首个属于所选App的像素或完整App打开时间。测试的launchToKnownNativeUIMilliseconds包含同步文字识别与轮询，前两轮约14秒，因此未把它用于画面到达或提速统计。四轮固定界面确认、前台状态、镜像及清理均通过。另两轮候选支付宝迁移/界面/恢复通过，内部确认约476.609/539.771ms，确认后解码帧约536.734/541.931ms；没有支付宝旧新速度对照，不扩大为任意App或扫码通过。

本轮只完成应用任务迁移链路的后台优化，未修改相机供图或动画，没有重测扫码识别、前台实际拖出、物理拖动或无线。之前的微信偶发前台确认失败、扫码长间隔与第三款App供图缺口保持未解决。


### build47包内资源回读与反例

最终包源码`e8228cf1c9509a0e0f41447ad37ca8d8fc351886`，ZIP SHA256 `7bc59e5c8ce98861552975585ce1f48f4aa16401add5ff18d11f3a6a6164eda8`。完整优化编译/链接及持续签名通过；解压后SOURCE、build47、JAR与构建源一致，deep/strict签名校验通过，designated requirement与原安装build41相同。随后使用这个包内的ADB/Java资源与同版生产PhoneSession/MirrorSession进行后台迁移回归，微信真实固定界面、前台确认、任务恢复和清理通过；没有启动签名App GUI。

该轮内部启动确认约890.060ms、确认后新解码帧约923.887ms，比前述受控组更慢。没有该轮同期旧基线，不能判断是资源路径、设备/宿主负载还是其他原因；保留为长等待反例，不剔除后宣称整体稳定提速。源码减少重复读取的结构事实不等于用户总等待始终缩短。最后三个服务约77.3/66.7/350.3ms正常响应，无session记录、无自有GUI进程或屏上窗口。原build41未被替换，未请求或重置Mac录屏授权，未创建新Release。

## 独立窗口失联与重试（build48，2026-10-30）

修复三个生命周期问题：启动过程中即使已收到镜像帧，也不能接受手机输入或成为桌面相机目标；镜像失败须立即停用当前来源；失败窗口再次打开须能重试。每次启动使用独立的线程安全 availability fence 和帧队列 generation，后台错误回调先失效两者，再排主线程清理，避免主线程繁忙时仍继续接纳桌面帧。生产 CameraPumpMailbox 在区域更新、选择、发布、handoff 和 PhoneSession 实际写 socket 前的 validator 都读取同一 fence。正在写出的请求无法撤回，随后停止并等待清帧确认，不将“已排清理”当作已清除。

主线程停止输入和采集，结束已接受的手势，等待镜像停止、迟到的启动结束及相机清帧确认，再恢复旧任务、关闭旧 Android 显示。再次打开仅排一个重试意图，复用原 Mac 窗口，新建独立的启动代数和 Android 显示。旧错误或旧像素不能污染新会话。清帧未确认、绑定回滚不确定或任务恢复失败时保留恢复信息；前两者要求重新连接，不在来源归属不明时新建显示。断开/退出等待已有清理并取消排队重试。

### 合成与隐藏真机验证

`DetachedApplicationsTests` 使用假手机和镜像、真实 MirrorVideoMailbox，以及从不排序到屏幕的自有窗口，覆盖启动期输入拒绝、后台失败在主线程接管前即拒绝输入/画面、已有手势松开、清帧屏障、重复重试、同窗重开、旧回调、迟到创建、清理失败和退出取消。`MirrorVideoMailboxTests` 验证只停止指定代数；`CameraPumpMailboxTests` 验证来源停用后拒绝全部入队/选帧/交接且不污染新来源。三项最终源码测试及完整 Mac warnings-as-errors 编译通过。

新增显式 `DetachedRecoveryIntegration`，编译时使用除 `mac/main.swift` 外的生产 Mac 源码。测试必须同时指定 `--run-device-test --locked-applications --resources <bundle Resources> --report <new JSON>`，从仓根运行。报告仅允许新建在本人所有、mode700的 `.local/generic-camera-tests` 下，不跟随符号链接；只记录固定布尔/计数/失败阶段，不存图片、设备标识、页面内容或原始错误。测试只允许唯一已授权 USB 手机，拒绝已有 GUI/恢复会话，不触发 Mac 屏幕录制。

三轮均使用当前生产 DetachedApplications、PhoneSession、MirrorSession 和真实 ControlWindowController，采用禁止激活策略及仅测试注入的不显示窗口方式；生产默认呈现方式不变。打开已有微信的自有虚拟显示，确认本地视图收到手机像素；只停止本次自有视频流，检验旧来源立即失效；在清帧 ACK 后重试，确认同一 Mac 窗口、新 Android 显示、新画面及所选应用前台，最后断开清理。没有注入点按、进入扫码、读取二维码或登录/支付操作。

|轮次|结果|证据与边界|
|---|---|---|
|1|失败|首段画面与旧来源失效通过，第二段画面阶段失败；当时没有分类错误码，原因未知。清理成功、恢复记录不存在。|
|2|通过|清帧ACK、同窗重试、新显示/新画面、应用前台及清理全部通过；窗口从未排序到屏幕。|
|3|通过|重复第2轮全链路通过，结束后恢复记录不存在。|

第一轮与后两轮之间仅增加测试分类诊断及报告路径约束，核心恢复代码未更改，不能据此宣称已定位或修复第一轮失败。真实测试的清帧通过测试回调直接调用 PhoneSession；没有构造 AppController、运行生产桌面采集/供图泵，不能作为实际桌面帧停止或完整扫码的真机证明。生产泵接线以源码复核和上述合成回归为证据。未测扫码提速、物理拖动、无线、第三款 App 或视频同等效果，旧反例继续保留。

本轮不启动候选 GUI、不替换已安装 build41、不请求或重置录屏授权、不创建新 Release。

最终路径反例测试覆盖仓外路径、`..`逃逸及两级目录符号链接，均在访问设备前拒绝。独立只读复核已检查来源 fence、代数隔离、输入门禁、清理顺序、报告路径与结论边界；未把复核当作真机代跑。测试后 virtualdevice / virtual_camera / media.camera 分别约113.1 / 58.0 / 307.4ms正常响应；无自有GUI或屏上窗口，无恢复记录，安装版仍为41。

### build48 包校验

运行源码 `4b118050a2c21bfb814d658739365f5f44709cc5`，本地候选 `build/MiraDroid-0.4.0-build48-4b11805-arm64.zip`，SHA256 `b8e6fa4525af4cda68df4b543880762a352384ea1cb29471ec52bd863a65a44f`。完整优化构建和签名通过；解压后 build48、SOURCE、JAR 与构建源一致，deep/strict 校验通过，designated requirement 与已安装 build41相同。本包没有启动或安装，不能将签名一致当作新包已实际录屏的证明。报告写入另以无效资源目录做正向路径测试：合法目标能以0600新建固定失败报告，在访问手机前结束；不计入真机恢复轮次。

## 后台恢复原因与扫码诊断（build49，2026-10-30，验证中）

按用户要求，本轮不切换正在使用的Mac应用、不重置录屏权限。恢复夹具把第二帧与前台状态检查拆成独立阶段，新增可选的固定内存事件和任务校验错误类型；不导出任务原文、组件、ID或页面内容，严格拒绝条件暂不改变。精确复测已出现重试启动失败：新显示创建/镜像连接后，在任务树校验中失败；首轮历史报告缺分类，不能追溯认定同因。

新增显式 `--run-background-scan-diagnostic --diagnostic-usb --locked-applications --background-report <new private JSON>` 研究入口。其 `.prohibited` 分支不构造AppController、不调用激活接口，仅检查已有屏幕录制权限；不足则失败，不申请权限。测试板只含随机纯文本二维码，禁止key/main与鼠标输入，排在普通窗口后方；生产DesktopCapture过滤器只包含本进程该测试板。真实手机应用、已认证相机归属、生产采集/帧队列/socket/解码组件参与测试，结果仅固定布尔/计数和耗时，无图片或任意OCR。扫码动作只允许在确认的自有显示/应用页面中执行固定导航；首次扫码点击后仅等待，不重复点击，不通过返回键退出既有页面。此入口不等于完整AppController、物理拖动或前台体验验收，实际扫码结果待下文记录。

### TaskFragment 反例与修复（build50）

精确恢复轮次1–13中，4/7/10/13在重试就绪前失败（其余9轮通过），四轮停止后都不继续自动复试。7的固定类型为startupOther；10已细分为任务树malformedTask；13进一步定位为TaskFragment，且任务恢复失败、记录保留。此前轮次只细分了诊断，没有修改解析器放行条件。不能把这些后来失败追溯当作最早那次second-frame的已证实原因。

[Android 16 AOSP TaskFragment.dump](https://android.googlesource.com/platform/frameworks/base/+/android16-qpr2-release/services/core/java/com/android/server/wm/TaskFragment.java)递归输出fragment/活动，Hist使用所属Task。修复将fragment视为真实Task下的结构容器，活动仍核对真实Task ID和用户，直接child计数逐层验证，不生成虚假的可迁移任务；同task内多包新增拒绝。正常/嵌套fragment及内嵌真实Task通过合成测试，跨包、跨用户、错Task ID、错子数、孤立/空/损坏fragment仍拒绝。原迁移组与窗口生命周期合成回归通过，独立只读复核未发现放宽归属门槛的缺陷。

修复后用当前生产PhoneSession和新解析器编译仅恢复入口，核原设备/owner/关联后成功恢复第13轮保留会话，无恢复记录；不清空记录、不新建虚拟设备、不修改录屏权限。研究包49源码`89c80fd`仅用于诊断，尚未运行扫码入口；后续包使用修正后的解析器。

TaskFragment修复后六轮隐藏断流重试全部通过，均收到首段/第二段手机画面、前台应用确认且恢复清理成功；对应原来连续组中第三轮出错的窗口创建序列未再失败。该结果支持所复现的TaskFragment问题已解决，不能证明历史首轮同因、任意App兼容或长期稳定。实际扫码诊断的跨App epoch同时修正为严格递增，避免前一App清帧后拒绝下一App的图像；耗时p95采用nearest-rank口径。

### build50 首次后台真实扫码（源码197fc7d）

既有录屏权限检查为true，仅采集自有后置测试板；微信成功识别本轮随机纯文本码，支付宝导航阶段失败，整轮不计通过。清理成功，无恢复记录。微信launch内部确认868.2ms；首个扫码tap到相机归属1358.6ms、首ACK1643.4ms；QR显示请求到首次确认结果帧约4199.8ms、观察完成4255.9ms。43次成功请求耗时p50/p95约9.59/36.59ms；44次捕获约2.82/6.64ms（含一次212.9ms启动最大值）；目标8Hz，42个循环起点间隔p50/p95约129.3/132.2ms。不能据低socket成本把完整等待视为解决。

二维码起点是本地displayIfNeeded结束，不是WindowServer首像素；结果时间为首次被文字检查确认的解码帧，包含采样遗漏的上界，不是手机精确识别完成时间。未构造AppController、未测物理输入。报告activationRequested=false，但frontmostUnchanged=false；机主使用电脑期间前后台标识可变化，不能据此归因给测试或宣称整段前台标识不变，诊断源码未请求激活或使测试板成为key/main。

### build51 受控供图诊断

区分从相机页恢复与真实扫码点击；已有相机流不伪造tap计时。新增固定导航标签/计数。显式单App的`--diagnostic-supply-abba`采用8/30/30/8目标频率，旧入口记录的是循环起点，包含采集等待；不能当作实际发包间隔（build55起另记phone actor请求时刻）；文字结果观察独立于供图循环，以相同125ms休眠周期检查，避免更快供图同时加快观察而混淆对照。仅该受控重复入口会在本轮随机测试码结果已确认、帧小于1秒且两次认证活动快照一致时，以普通镜像BACK离开本轮结果；仍存在快照到异步输入间的页面转换竞态，不作原子路由保证。普通诊断没有此返回操作，产品默认供图频率尚未更改。八种诊断scope旗标组合合成检查通过。

### build51 真机结果与反例（源码aca12f1）

支付宝单App轮完成真实扫码，扫码tap→owner约427.1ms、首ACK769.3ms；QR显示请求→首次确认结果帧1486.1ms，观察完成1600.4ms。源仅自有测试板，既有权限true、frontmostUnchanged=true、恢复清理成功。没有伪造tap起点（本轮确实点击了手机自己的扫一扫）。

微信第一组同包ABBA四轮均识别随机测试码且清理；按8/30/30/8顺序：

|轮次|目标Hz|扫码tap→owner(ms)|tap→首ACK(ms)|QR显示请求→确认结果帧(ms)|循环起点间隔p50/p95(ms)|
|---|---:|---:|---:|---:|---|
|A1|8|409.4|646.4|1909.7|130.3 / 133.0|
|B1|30|276.3|433.0|1117.8|36.5 / 38.5|
|B2|30|335.0|478.5|1096.7|36.9 / 38.5|
|A2|8|270.5|403.4|1174.5|129.9 / 132.8|

这组均值A1542.1/B1107.3ms，但A2已接近B组，不能排除冷启动/顺序/设备状态影响。重复组中A1识码1459.5ms、首ACK609.7ms；B1首ACK426.2ms、循环起点间隔p50/p95约36.1/38.4ms，但未确认结果，整组失败并停止，没有继续B2/A2。不能排除手机识别、源呈现或OCR漏认，不能称30Hz稳定更快，不丢弃这轮失败后汇总好看均值；产品仍保持原8Hz上限。两组最终均正常清理，首组frontmostUnchanged=false，重复组true；不把机主前台标识变化归因给测试。

### build52 诊断证据收紧

为区分新反例，首次送QR前验证捕获源确为本轮测试板上的随机码；此QR解码只在显式自有诊断中执行，不加入产品通用供图。结果检查允许Vision把同一token拆词后拼接，但仍必须严格包含本轮字符串；编辑距离仅作数值诊断，绝不作为通过。结果提交和主loop接纳均核截止时间。记录固定的源确认、OCR次数、是否看见自有前缀、最小编辑距离、结束流数/目标活动布尔，不导出任意文本或像素。

build52自有源验证ABBA（源码0b0eeaa）四轮均识码并清理，frontmostUnchanged=true，既有权限true：8/30/30/8组源确认约149.1/50.1/66.9/62.6ms，首次确认结果帧约1836.6/1102.9/1090.2/1136.8ms。四轮capturedExpectedQRConfirmed=true、实际发送成功且结果帧晚于源确认，编辑距离均0。该包的源确认当时仅报告，后续已将它与发送成功及结果时间顺序纳入硬性通过门槛；上述四轮也独立满足这些条件。首次8Hz仍比最后8Hz慢，暖态8Hz与30Hz约1.14与1.09–1.10秒，不能把冷暖差异归因给频率。此前51重复组的未确认结果不能被本组追溯解释或剔除；继续保留默认8Hz，不称达到视频同等效果。

### build53 首帧就绪与缺帧回收

独立窗口原本只核Android启动成功就进入ready，即使镜像没有新解码帧也可保持此状态。现在还要求同代Mailbox收到receivedAt不早于本次launch请求开始的帧；takeLatest不清除这份证据，reset/stop则清除。启动前空显示旧帧与上一代帧都不能放行。默认等待5秒，无帧则固定firstFrameTimeout并走原有停帧、禁输入、清帧/恢复/回收链路。此门槛证明本次请求期间镜像有解码输出，不保证非空、已呈现或已包含目标App最终内容；以launch开始而非确认结束为界，避免合法静帧已先到达却继续等待刷新。

Mailbox与生命周期合成回归通过，新增同代prelaunch旧帧必须等新帧、无帧超时回收反例。独立只读复核未发现停机、迟到帧或超时自等待问题。两轮当前生产代码的隐藏真机恢复均通过：各自启动、首帧门槛、故意断流、同窗重试、新帧和清理成功。一次重试从waitingForFrame到ready仍约992ms，长等待没有消失，不能把状态修正当作提速或原始首轮根因证明。没有重置录屏授权或切换Mac应用。

### build53 最终包及双App后台复测

运行源码`78f40b3e2b99a1eba2a65d526d5867d8edcc4fe2`，候选`build/MiraDroid-0.4.0-build53-78f40b3-arm64.zip`，SHA256 `ea6af7484a3223b6380a6fef46c75ec80f05e2fac427b87fb4288fe1c9adb3f6`。完整优化构建、包内SOURCE/build53/JAR回读、deep/strict签名校验通过，designated requirement与原安装版相同。最终Mac warnings-as-errors类型检查、任务解析/归属、窗口生命周期、Mailbox以及scope测试均已有相应通过记录；未将构建当作产品验收。

最终包以默认8Hz后台入口顺序打开微信、支付宝自己的扫一扫，两者均实际点击扫码（非恢复已有相机），本轮随机源QR核实、实际发送、严格结果匹配、时间顺序和清理全部通过：

|App|扫码tap→owner(ms)|tap→首ACK(ms)|QR显示请求→源确认(ms)|QR显示请求→首次确认结果帧(ms)|→观察完成(ms)|
|---|---:|---:|---:|---:|---:|
|微信|544.5|798.9|139.5|1797.5|1910.3|
|支付宝|335.7|472.1|75.0|1602.3|1708.7|

既有权限true，未请求或重置录屏授权；activationRequested=false，frontmostUnchanged=false，不把整段机主前台标识变化归因给诊断。测试只捕获自有后置板，未构造AppController、未显示手机控制窗口、未注入Mac输入、未验证完整前台动画/物理拖动/无线/第三App；不能称视频同等效果。源码首帧门槛由前述两轮隐藏生产Manager恢复另行验证，不以本扫码入口替代其GUI验收。

最终三个服务约49.0/41.8/381.1ms响应，无自有GUI进程、屏上窗口或session恢复记录，原安装版仍为41。所有未通过/未知反例仍保留；默认供图没有因第一组较快均值改为30Hz，候选未创建Release或替换安装版。

## 预览返回与结果文字分段（build54，2026-10-30，验证中）

用户要求继续且不抢前台、不重置授权。本轮显式后台诊断增加`--diagnostic-preview-timing`：仅在自有随机源QR已核实/发送之后，判断它何时首次被确认出现在手机H264返回帧，与结果文字匹配分别记录。记录两个帧的序列号、相对时间及before/same_frame/after/no_text关系；只有更早的独立QR帧才计算到结果帧的时距。该观察不代表手机物理显示时刻、AppController或纯识别时间，125ms休眠还会叠加Vision/调度成本。

纯内存fixture区分QR预览、文字结果、同帧二者、错误码/近似文字不通过；宿主图形运行时测试通过，沙盒内CoreImage生成失败不计通过。观察器不输出OCR正文、图片或payload。源失效、取消、截止和固定源证明继续限制成功。额外记录既有镜像解码数/耗时与相对积压；相对PTS积压不等于绝对输入延迟。独立只读复核已检查锁/取消及不混淆QR和文字的边界，未代跑真机。


### build54 分段实测与阻塞路径

源码ba28f29默认双App轮在微信导航失败：首页固定标签已确认，110个OCR帧都未定位到合格“＋”，没有发送tap，最终清理成功。这是导航未进入扫码，不能当扫码或预览性能失败。随后支付宝单App轮通过，源确认约168.0ms，自有码首次确认出现在手机视频帧约349.1ms（序列205），结果文字帧约1565.4ms（序列283）；源确认后到视频QR约181.0ms、两个已确认视频帧间约1216.4ms。该轮QR→text关系before、既有权限true、前台标识前后相同、清理成功。镜像硬解p95约4.97ms、max5.94ms，相对PTS积压p95约79.8ms、编码器输出报告1帧；这些值不等于绝对输入到显示延迟。约1.22秒还包含手机App处理/UI/取样，不称为纯识别时间或网络成本。

## 首图单帧与连续流交接（build55，2026-10-30，验证中）

受控研究比较现有stream-only与snapshot→stream：SCScreenshotManager.captureSampleBuffer本机SDK标注macOS14.0可用，本项目最低14.4。新方法硬限已显式选择的自有board、当前PID、既有preflight、完整单屏ROI和0.5秒freshness，截帧后复用原CVPixelBuffer/JPEG编码；普通桌面capture不调用它。snapshot完成后才启动独立stream warmup，下一次采集等待并清空该任务；warmup失败标fallback、停止旧流并由正常capture重新准备，权限失败不回退重试。退出cancel/stop/join，并将晚期stream停止统一为3秒有界，不自等待。

`--diagnostic-snapshot-abba`仅单App，按stream/snapshot/snapshot/stream，与供图ABBA互斥。`--diagnostic-startup-snapshot`为单模式；`--diagnostic-immediate-qr`从第一张输入开始放本轮码，不插入1.5秒空白预热，增加实际scan tap→结果帧分段。`--diagnostic-expire-stream-warmup`仅与单snapshot模式配合，将自有warmup target故意过期，验证fallback而不是重复await失败任务。snapshot策略还须核实连续流首张有效源码，防止单帧成功掩盖交接空白；未核实帧不送入手机。当前只是研究，不提升产品默认捕获路径。

微信诊断新增真实“发现→扫一扫”备用路径：Home标题/至少三个底tab、Discover标题/菜单地标、扫一扫区域共同核对；只点一次发现，其tap不冒充扫码tap；发送前继续确认同一owned display/activity。产品通用相机流程不新增任何微信按钮或App名单。scope/实验旗标互斥、自有snapshot拒绝普通桌面、Discover合法/错误页面合成通过。

统计更正：build50–54的sendStartGap实际来自每次成功请求所属循环的起点，含采集等待，不是实际socket发送间隔；已更正上方相关表头，数值原样保留，不能据它判断首图后是否停顿。build55的CameraFrameReceipt增加phone actor内部requestStartedAt（旧初始化兼容nil），分别记录loopIterationGap、sendStartGapClock=phone_actor_request_start和ACK完成间隔；这仍不是物理网络上第一个字节时刻。firstCapture只含capture/warmup等待，firstImagePipeline才含源验证和确认。早前30Hz稳定性未通过和保守默认8Hz的结论不因改口径变更，不沿用旧最大loop间隔声称发包停顿。

### build55 后台结果（源码68bd88a）

首轮snapshot模式支付宝严格识码、连续源交接核实、清理通过，但firstACKUsedSnapshot=false，首张在发送前过期；tap→首ACK839.5ms，不能计为snapshot提速。随后ABBA首个stream轮通过（tap→首ACK447.5ms、结果帧1790.5ms）；第二个snapshot轮实际送达首图且交接源核实，tap→首ACK254.6ms，但9秒内未严格匹配文字结果（最小编辑距离1），整组失败即停止，不继续B2/A2，不把近似文字当通过。两轮手机返回帧均核实源QR，约145.5/421.0ms在源确认后首次观察到，ACK较快不等于返回画面较快。两组清理成功，权限一直有效。

故意过期warmup轮firstACKUsedSnapshot=true、streamWarmupFailed/fallback=true，正常capture重建后源交接核实并严格识码；tap→首ACK347.7ms、结果帧1431.8ms，确认失败Task没有被连续await到截止。微信单轮也实际点击其原生扫一扫并严格识码，tap→首ACK684.1ms、结果帧2257.8ms，清理成功；本轮用的是已验证＋菜单，新增Discover备用尚未实测。所有四次入口未请求激活、前后前台标识相同，只有自有后置板；不以此替代物理拖动/真实前台动画验收。snapshot不启用产品默认，继续定位手机收帧到相机Surface实际post的等待。

## 相机Surface等待分段（build56，2026-10-30，验证中）

新增CameraPaintTiming仅保留连接内最多128个数字样本，无像素/包名/文本。计时从服务端发布解码Bitmap或合成色源后，到任一自有相机Surface首次成功unlockCanvasAndPost；重复空闲刷新不重复计数，replacement/clear/失效后的旧ticket不计。lock/draw/post分段含该绘制调用自身的开销，不可简单相加为total（源可能在lock等待期间更新）；不包含JPEG解码/socket/手机App消费/物理呈现。状态与owner不是原子快照，数据不参与归属授权，不能用作某App纯处理时间。旧服务不提供时缺省nil，无效可选数字丢弃，不改变归属证据。

结果文字核验新增无customWords、无expected输入的英文top1二次识别，仅原有结果前缀近似但未命中时尝试；仍须独立top1去空白后完全等于本轮码，不将编辑距离当通过。primary也拒绝附带ASCII字符；拆词只组合同基线邻近的完整ASCII组，跨行/远区不拼。该变化只改善自有诊断核验，不改变手机识别或产品供图。此前失败组继续保留，不追溯转为成功。

### build56 真机分段与频率对照（源码f4982b5）

包SHA256 `219982912e8b10a333f1403f215b7710f689204ff2f652f42f659730448c4fb9`，源码/JAR/同DR深度签名回读通过。支付宝单轮严格识码与清理通过，tap→首ACK699.9ms、结果帧3619.9ms；10个有效相机首post样本最大53.4ms、最后6.03ms。微信单轮也通过，635.97ms到owner、948.25ms首ACK、2808.83ms结果帧；15个相机首post样本最大57.51ms、最后17.30ms。两轮secondaryChecks=0，结果由primary严格命中；不能把本轮较慢结果归因于secondary或把首post数字当完整画面延迟。

同包支付宝8/30/30/8Hz供图四轮均严格识码且清理：tap→首ACK383.5/427.5/263.2/200.3ms；tap→结果帧2094.5/1536.6/1157.7/1119.6ms；QR显示请求→结果帧1899.1/1214.3/990.1/1011.8ms。实际phone-actor请求间隔p50约131.7/34.8/34.1/54.8ms（末轮仅2间隔，另一个128.0ms，不拿小样本p50当稳态）；有效相机首post最大39.1/47.5/7.46/13.6ms。冷暖/顺序仍显著：最后8Hz接近暖30Hz，不提升产品默认供图频率。源QR与返回QR及真实原生文字结果分别核实，不丢弃既有失败。

随后snapshot ABBA在第一轮stream-only的导航阶段失败：已核首页标签且发出一次scan tap，但25秒未确认camera owner，未进入采集，整组失败且停止；不是snapshot或传输性能失败。清理成功、三个系统服务继续响应。所有以上入口既有权限true、activationRequested=false、前后台标识前后相同、无恢复记录；未构造AppController或测前台动画/物理拖动。重新定向读取用户原视频：文件888×576、30fps、16.23秒；编码30fps不证明原软件渲染上限或本软件已达同效。

## 首次扫码点击后的受控恢复（build57，2026-10-30，验证中）

后台导航原本scanTap发出后只等待，未像原桌面诊断那样重新核实重试。复用既有3次/800ms预算：仅初次同component、camera known+closed且activeStreams=0、全新post-tap帧重新OCR核实受控home/menu入口才能重试；await后再核归属、帧和预算；未知页/相机正在打开/活动改变不重试，截止后不点。plus/discover不混入scan重试。仅改变显式后台诊断，正常产品输入不变。报告标last-verified-navigation-tap并同时给first tap→owner/首ACK/结果与重试延时，避免将丢失点击后的最后一次耗时冒充总体提速。新增纯状态反例验证已通过。

### build57 后台复测与保留失败（源码5bfc99a）

包SHA256 `fac1dfcabc1f20f6894301045a006cf8fcee77969af18abd95bb2025e9e590ac`。snapshot ABBA第一轮从已有相机恢复，严格识码2146.0ms，无实际scan tap起点，不能计打开扫码性能；第二轮在一次scan tap后仍未确认相机，整组导航失败并停止。重试安全条件未满足时没有放宽或强点。清理成功、无恢复记录、已有权限true；activationRequested=false但前台标识前后不同，不能据此认定测试抢前台或宣称整段PID不变。本轮缺少state细分，不能断言是丢点击、卡绘制或snapshot失败；后续只增加固定routeKind/ownerEvidence/stream计数，仍不导出App组件正文或任意画面。

## 启动入口按包核验（build58，2026-10-30，验证中）

发现launchApplication客户端复核与服务端camera bind都重新加载全目录/所有label。保留安全再校验，改为只查询所选包：提取LauncherCatalog共享同一MAIN+LAUNCHER、主用户、exported/enabled过滤和canonicalComponent精确比对；只用[Intent.setPackage](https://developer.android.com/reference/android/content/Intent#setPackage(java.lang.String))限制候选，不设component以免绕过IntentFilter。camera bind仍核owned display和声明CAMERA权限。原全目录入口/500上限/label清理不变；不缓存可能失效的授权结果。

认证command10空body仍全目录，1–255 bytes为严格UTF8 ASCII包名；component、控制字符、非法编码和超限拒绝。liveState显式packageLauncherQuerySupported时Mac才发包名，旧服务缺能力发原空body；能力不成为相机owner证据。连接初始state同时取得能力，退出清除；失败不自动忽略再校验。记录本次启动的实际validation耗时与scoped布尔，仅供内部诊断。

最初只读原型cold全目录262.6ms、后续11.3–18.4ms，所选包1.34–4.63ms；原型省略JSON且目标侧未loadLabel，不能当整体启动改善。随后用新提取的**实际函数**（含JSON/label）在手机同进程预热后做三组full/package/package/full，full分别11.22/13.51、12.03/9.99、11.50/14.18ms，package分别3.29/2.55、1.04/1.55、2.78/1.12ms。两包scoped成员与全目录按包过滤集合完全相同，非launcher扫码activity未出现，未知包为空；无App启动/相机/虚拟设备操作，只清理该探针生成的两个JAR。该结果只证明目录核验步骤减少开销，不推算完整扫码或物理响应提速。

### build58 最终包、回退与双App复测

运行源码`8b41393ae769980d0d79b8f7b42d5a4f99aecd8e`，包`build/MiraDroid-0.4.0-build58-8b41393-arm64.zip`，SHA256 `9ccbef3bd15b1e62701db04bd3de05ea21aec5239d97e11465ddb44788f06186`；源码/JAR/strict-deep签名及同designated requirement回读通过，安装版41未替换，未重置录屏授权。

首个双App轮在微信launch阶段失败，未进入导航/采集；后续不录屏的同源客户端单独复核有两次not_arrived（入口核验4.86/3.37ms，任务已在target，前台仍判other，listener却报requested），均正常恢复清理。不能将它归因于新package query、二维码或已证实为解析错误。后来结构观察连续三轮启动通过（约267.1/254.3/243.6ms、入口核验3.85/3.50/3.08ms），top记录对应target，未再复现该矛盾；三次成功不能清掉前两次失败。记录只有固定类别/计数/布尔，无组件正文、任务ID或手机像素。

同客户端配旧build57服务，显式capability回退为false，旧空body全目录核验31.72ms、启动通过约840.7ms，任务/前台对应且清理成功；此跨轮总耗时不作新旧整体A/B。随后同一最终包双App第二轮均严格识码并清理，现有录屏权限true、activationRequested=false、前后台标识前后相同：

|App|入口核验(ms)|完整launch确认(ms)|首次扫码tap→首ACK(ms)|首次tap→结果帧(ms)|QR显示请求→结果帧(ms)|
|---|---:|---:|---:|---:|---:|
|微信|5.37|199.13|727.18|2532.90|2125.22|
|支付宝|2.50|815.01|395.80|2587.30|2302.85|

两次scoped=true、scan tap均仅1次，源码、实际发送、原生文字结果严格匹配，均核known-scanner/target owner/1 stream。这里只验后台生产组件，未构造AppController或测物理拖动/前台动画，不称视频同等效果。Android官方[am start -W](https://developer.android.com/tools/adb)等待路径也仅做隐藏启动探针：微信启动通过804.0ms，其中该shell约52.3ms，不能据一轮认定它更快或解决首轮失败，产品尚未采用。
