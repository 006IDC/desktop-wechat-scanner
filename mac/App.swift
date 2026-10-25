import AppKit
import Vision
import ScreenCaptureKit
import CoreImage
import CoreVideo

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private enum Mode { case phone, wechat }
    private final class MirrorRoute {
        let session=MirrorSession(),frames=MirrorVideoMailbox()
        var startup:Task<Void,Error>?
        var failure:String?
        var incarnation=0
    }
    private let control=ControlWindowController(), capture=DesktopCapture()
    private let physicalMirror=MirrorRoute(), scannerMirror=MirrorRoute()
    private var activeRoute:MirrorRoute {mirrorDisplay == nil || mirrorDisplay == 0 ? physicalMirror:scannerMirror}
    private var mirror:MirrorSession {activeRoute.session}
    private var phoneSession:PhoneSession?
    private var phone:PhoneSession { phoneSession! } // Set before any connected operation.
    private var adbURL:URL?
    private var adbSettingsItem:NSMenuItem?
    private var connected=false, busy=false, paused=true, stopping=false
    private var cameraActive=false, cameraSuppressed=false, mode=Mode.phone
    private var cameraPump:CameraPumpMailbox?,cameraFramesBase=0
    private var nextCameraDiagnostic=0.0
    private var connectionTask:Task<Void,Never>?, operationTask:Task<Void,Never>?, loop:Task<Void,Never>?, cameraLoop:Task<Void,Never>?
    private var currentStatus="未连接", currentDetail="用 USB 连接并解锁手机，然后点击左上角连接。"
    private var model="", scanGeneration=1, mirrorGeneration=0
    private var relaunchAfterExit=false, lastUserInput=Date.distantPast
    private var framesSent=0, previewsReceived=0, cameraFPS=0.0
    private var latestPhoneFrame:CVPixelBuffer?
    private var mirrorDisplay:Int?
    private var scannerSwitchMilliseconds=0.0
    private var previewTimer:Timer?
    private var captureMilliseconds=0.0, transferMilliseconds=0.0, previewWaitMilliseconds=0.0
    private var droppedCameraFrames=0, maximumCameraGapMilliseconds=0.0

    func applicationDidFinishLaunching(_ notification:Notification) {
        buildMenu();control.window?.delegate=self
        let timer=Timer(timeInterval:1.0/60,target:self,selector:#selector(presentMirrorFrame),userInfo:nil,repeats:true)
        RunLoop.main.add(timer,forMode:.common);previewTimer=timer
        control.onConnect={ [weak self] in self?.connect() }
        control.onDisconnect={ [weak self] in self?.disconnect() }
        control.onScan={ [weak self] in self?.enterWechat(scan:true) }
        control.onPause={ [weak self] in self?.togglePause() }
        control.onBack={ [weak self] in self?.back() }
        control.onHome={ [weak self] in self?.home() }
        control.onWechat={ [weak self] in self?.enterWechat(scan:false) }
        control.onPermissionSettings={ [weak self] in self?.permissionSettings() }
        control.onRelaunch={ [weak self] in self?.relaunch() }
        control.onTap={ [weak self] x,y in self?.tap(x,y) }
        control.onSwipe={ [weak self] x1,y1,x2,y2 in
            guard let self,self.connected,!self.busy else{return}
            self.lastUserInput=Date();self.mirror.swipe(x1:x1,y1:y1,x2:x2,y2:y2)
        }
        control.showWindow(nil);refresh();writeDiagnosticState()
        NSApp.activate(ignoringOtherApps:true)
    }
    private func buildMenu(){
        let menu=NSMenu(),appItem=NSMenuItem(),appMenu=NSMenu()
        appMenu.autoenablesItems=false
        appMenu.addItem(withTitle:"关于桌面微信扫码",action:#selector(about),keyEquivalent:"").target=self
        adbSettingsItem=appMenu.addItem(withTitle:"设置 ADB…",action:#selector(configureADB),keyEquivalent:"")
        adbSettingsItem?.target=self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle:"隐藏桌面微信扫码",action:#selector(NSApplication.hide(_:)),keyEquivalent:"h").target=NSApp
        appMenu.addItem(withTitle:"退出桌面微信扫码",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        appItem.submenu=appMenu;menu.addItem(appItem)
        let item=NSMenuItem(),actions=NSMenu(title:"手机")
        for (title,key,action) in [("手机主屏幕","1",#selector(homeAction)),("打开微信","2",#selector(wechatAction)),("桌面扫码 / 再扫","r",#selector(scanAction)),("暂停 / 继续桌面相机","p",#selector(pauseAction))] {
            actions.addItem(withTitle:title,action:action,keyEquivalent:key).target=self
        }
        actions.addItem(.separator())
        actions.addItem(withTitle:"关闭窗口",action:#selector(NSWindow.performClose(_:)),keyEquivalent:"w")
        item.submenu=actions;menu.addItem(item);NSApp.mainMenu=menu
    }
    @objc private func about(){NSApp.orderFrontStandardAboutPanel(options:[.applicationName:"桌面微信扫码",.applicationVersion:"\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知"))",.credits:NSAttributedString(string:"Android 手机镜像与桌面扫码\n镜像采用 scrcpy 5.0.1（Apache 2.0）与 Mac 原生解码。")])}
    /// Selection stays on the main actor; executable validation runs off it.
    private func chooseADB() async throws -> URL? {
        while !Task.isCancelled {
            let panel=NSOpenPanel()
            panel.title="选择 Google Platform-Tools 中的 adb"
            panel.message="请选择解压后的 platform-tools 文件夹内的 adb 文件。"
            panel.canChooseFiles=true;panel.canChooseDirectories=false;panel.allowsMultipleSelection=false
            panel.prompt="选择 adb"
            let hints=ADBConfiguration.candidates(savedPath:UserDefaults.standard.string(forKey:ADBConfiguration.defaultsKey))
            if let hint=hints.first(where:{FileManager.default.fileExists(atPath:$0.path)}) {
                panel.directoryURL=hint.deletingLastPathComponent()
                panel.nameFieldStringValue="adb"
            }
            guard panel.runModal() == .OK,let url=panel.url else{return nil}
            try Task.checkCancellation()
            do {
                let selected=try await ADBConfiguration.validateAsync(url)
                UserDefaults.standard.set(selected.path,forKey:ADBConfiguration.defaultsKey)
                return selected
            } catch is CancellationError {throw CancellationError()}
            catch {
                try Task.checkCancellation()
                let alert=NSAlert();alert.messageText="无法使用此 ADB";alert.informativeText=error.localizedDescription
                alert.addButton(withTitle:"重新选择");alert.addButton(withTitle:"取消")
                guard alert.runModal() == .alertFirstButtonReturn else{return nil}
            }
        }
        throw CancellationError()
    }
    private func resolveADB() async throws -> URL? {
        if let selected=try await ADBConfiguration.discover(savedPath:UserDefaults.standard.string(forKey:ADBConfiguration.defaultsKey)) {
            UserDefaults.standard.set(selected.path,forKey:ADBConfiguration.defaultsKey)
            return selected
        }
        try Task.checkCancellation()
        let alert=NSAlert();alert.messageText="需要 Google Platform-Tools"
        alert.informativeText="此 App 不内置 ADB。请从 Google 官方网站下载适用于 Mac 的 Platform-Tools，自行阅读并接受其许可，解压后选择其中的 adb 文件。已有 Platform-Tools 可直接选择 adb。"
        alert.addButton(withTitle:"选择 adb…");alert.addButton(withTitle:"官方下载");alert.addButton(withTitle:"取消")
        let answer=alert.runModal()
        try Task.checkCancellation()
        if answer == .alertSecondButtonReturn {
            NSWorkspace.shared.open(ADBConfiguration.downloadURL)
            return nil
        }
        guard answer == .alertFirstButtonReturn else{return nil}
        return try await chooseADB()
    }
    @objc private func configureADB(){
        guard !connected,!busy,!stopping else{return}
        busy=true;refresh()
        connectionTask=Task {
            defer {if !stopping {busy=false;refresh()}}
            do {
                if let selected=try await chooseADB() {
                    adbURL=selected
                    status("ADB 已设置","已选择 \(selected.path)。可以连接手机。")
                }
            } catch is CancellationError {} catch {status("ADB 设置未完成",error.localizedDescription)}
        }
    }
    @objc private func homeAction(){home()}
    @objc private func wechatAction(){enterWechat(scan:false)}
    @objc private func scanAction(){enterWechat(scan:true)}
    @objc private func pauseAction(){togglePause()}
    private func status(_ title:String,_ detail:String){
        currentStatus=title;currentDetail=detail;refresh();writeDiagnosticState()
    }
    private func refresh(){
        adbSettingsItem?.isEnabled = !connected && !busy && !stopping
        control.update(status:currentStatus,detail:currentDetail,connected:connected,busy:busy,paused:paused)
        control.setCameraActive(cameraActive && !paused)
        // Keep the complete, interactive WeChat scanner. The transparent-only
        // experiment hides its controls and does not match the reference video.
        control.setLocalScanPreview(false)
        control.setMode(cameraActive ? "桌面相机" : (mode == .phone ? "手机镜像" : "微信"))
    }
    private func writeDiagnosticState(){
        let folder=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("006IDC/DesktopWeChatScanner")
        try? FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let value:[String:Any]=["status":currentStatus,"connected":connected,"paused":paused,"framesSent":framesSent,"previewsReceived":previewsReceived,"screenPermission":CGPreflightScreenCaptureAccess(),"mode":mode == .phone ? "phone" : "wechat","cameraActive":cameraActive,"cameraFPS":cameraFPS,"captureMilliseconds":captureMilliseconds,"transferMilliseconds":transferMilliseconds,"previewWaitMilliseconds":previewWaitMilliseconds,"droppedCameraFrames":droppedCameraFrames,"maximumCameraGapMilliseconds":maximumCameraGapMilliseconds,"scannerSwitchMilliseconds":scannerSwitchMilliseconds,"updatedAt":ISO8601DateFormatter().string(from:Date())]
        if let data=try? JSONSerialization.data(withJSONObject:value,options:.sortedKeys){try? data.write(to:folder.appendingPathComponent("diagnostic-state.json"),options:.atomic)}
    }
    private func connect(){
        guard !connected && !busy else{return}
        busy=true;status("正在连接","请解锁手机，并允许 USB 调试。")
        connectionTask=Task { [self] in
            do {
                let resolved=try await resolveADB()
                try Task.checkCancellation()
                guard let selected=resolved else {
                    busy=false;status("未连接","请下载并解压 Google Platform-Tools，然后再点连接选择 adb。已有 Platform-Tools 可再次连接后直接选择 adb。");return
                }
                try Task.checkCancellation()
                adbURL=selected;phoneSession=PhoneSession(resources:Bundle.main.resourceURL!,adbURL:selected)
                model=try await phone.connect(openWechatOnConnect:false){ [weak self] value in Task { @MainActor in self?.status("正在连接",value) } }
                try Task.checkCancellation();connected=true;mode = .phone;mirrorGeneration+=1
                try await showMirror(display:0)
                try Task.checkCancellation();busy=false
                status("已连接 · \(model)","直接点击或滑动手机画面；点微信后可在这里使用桌面扫码。")
                startLoop()
                // The empty secondary display is warmed while the user operates the
                // normal phone. Its frames never replace the active mirror.
                let epoch=mirrorGeneration
                Task { [weak self] in
                    guard let self else{return}
                    do {
                        let endpoint=try await self.phone.mirrorEndpoint()
                        guard self.connected,!self.stopping,self.mirrorGeneration==epoch else{return}
                        try await self.prepareMirror(display:endpoint.display)
                    } catch { /* Scan entry reports a warm-up failure without interrupting phone use. */ }
                }
            } catch {
                guard !stopping else{return}
                status("连接未完成",error.localizedDescription);disconnect(preserveError:true)
            }
        }
    }
    private func present(_ frame:MirrorVideoMailbox.Frame) {
        latestPhoneFrame=frame.pixelBuffer
        previewWaitMilliseconds=(ProcessInfo.processInfo.systemUptime-frame.receivedAt)*1000
        control.setPhonePixelBuffer(frame.pixelBuffer)
        previewsReceived+=1
        if previewsReceived%60==1 {writeDiagnosticState()}
    }
    @objc private func presentMirrorFrame(){
        updateCameraTick()
        guard connected,!stopping,mirrorDisplay != nil,let frame=activeRoute.frames.takeLatest(),frame.generation==activeRoute.incarnation else{return}
        present(frame)
    }
    private func prepareMirror(display:Int) async throws {
        let route=display==0 ? physicalMirror:scannerMirror
        if let startup=route.startup,route.failure==nil {
            try await startup.value
            if let failure=route.failure {throw ScanError(failure)}
            return
        }
        let generation=mirrorGeneration,needsStop=route.startup != nil || route.failure != nil
        route.incarnation+=1;let incarnation=route.incarnation
        route.failure=nil
        route.frames.reset(generation:incarnation)
        let task=Task { [self,route] in
            if needsStop {await route.session.stop()}
            let endpoint=try await phone.mirrorEndpoint(),resources=Bundle.main.resourceURL!
            try Task.checkCancellation()
            guard connected,!stopping,mirrorGeneration==generation else{throw CancellationError()}
            guard let adbURL else {throw ScanError("请先设置 ADB。")}
            try await route.session.startVideo(adbURL:adbURL,serverURL:resources.appendingPathComponent("scrcpy-server"),serial:endpoint.serial,displayID:display,onFrame:{ [frames=route.frames] pixels in
                frames.publish(pixels,generation:incarnation)
            },onFailure:{ [weak self,weak route] message in
                Task { @MainActor in
                    guard let self,let route,self.connected,self.mirrorGeneration==generation,route.incarnation==incarnation,!self.stopping else{return}
                    route.failure=message
                    if self.activeRoute === route {
                        self.status("镜像连接中断",message);self.disconnect(preserveError:true)
                    }
                }
            })
        }
        route.startup=task
        do {try await task.value}
        catch {
            if mirrorGeneration==generation,route.incarnation==incarnation {route.startup=nil;route.failure=error.localizedDescription}
            throw error
        }
    }
    private func showMirror(display:Int, after:TimeInterval?=nil) async throws {
        if mirrorDisplay==display,latestPhoneFrame != nil,after==nil {return}
        let generation=mirrorGeneration,route=display==0 ? physicalMirror:scannerMirror
        try await prepareMirror(display:display)
        let deadline=ProcessInfo.processInfo.systemUptime+10
        // Keep displaying the previous route until the target has a fresh frame.
        // A warm empty virtual screen must not flash over the real WeChat page.
        while ProcessInfo.processInfo.systemUptime<deadline {
            try Task.checkCancellation()
            guard connected,!stopping,mirrorGeneration==generation else{throw CancellationError()}
            if let failure=route.failure {throw ScanError(failure)}
            if let frame=route.frames.takeLatest(),frame.generation==route.incarnation,
               after == nil || frame.receivedAt >= after! {
                control.setPhonePixelBuffer(nil)
                mirrorDisplay=display;present(frame);return
            }
            try await Task.sleep(nanoseconds:16_000_000)
        }
        throw ScanError("手机镜像首帧未就绪，请解锁手机后重新连接。")
    }
    private func stopMirrors() async {
        physicalMirror.startup?.cancel();scannerMirror.startup?.cancel()
        physicalMirror.frames.stop();scannerMirror.frames.stop()
        async let physical:Void=physicalMirror.session.stop()
        async let scanner:Void=scannerMirror.session.stop()
        _=await (physical,scanner)
        physicalMirror.startup=nil;scannerMirror.startup=nil
        physicalMirror.failure=nil;scannerMirror.failure=nil
    }
    private func clearCamera() async {
        paused=true;cameraActive=false;scanGeneration+=1;cameraPump?.stop();cameraPump=nil;cameraLoop?.cancel();cameraFPS=0;refresh()
        await capture.stop()
        try? await phone.clear(epoch:scanGeneration)
    }
    private func enterWechat(scan:Bool){
        guard connected && !busy && !stopping else{return}
        busy=true;cameraSuppressed=false;operationTask?.cancel()
        status("正在打开微信","正在打开手机上的微信…")
        operationTask=Task {
            do {
                await clearCamera()
                if mode == .wechat {try await phone.moveWechat(toVirtualDisplay:false)}
                try await phone.openWechat(onVirtualDisplay:false);try Task.checkCancellation()
                mode = .phone;try await showMirror(display:0)
                try Task.checkCancellation()
                if scan {
                    let opened=try await openScanner();try Task.checkCancellation()
                    busy=false
                    if opened {activateDesktopScanner()}
                    else {status("微信","在微信中点“＋ → 扫一扫”，桌面相机会自动启用。")}
                } else {
                    busy=false;lastUserInput=Date()
                    status("微信","点“＋ → 扫一扫”，然后拖动窗口覆盖电脑二维码。")
                }
            } catch {
                guard !stopping && connected else{return}
                status("微信未打开",error.localizedDescription);disconnect(preserveError:true)
            }
        }
    }
    // Keep every ordinary WeChat screen on the physical display. Moving its
    // launcher to a secondary display produces duplicate headers on this phone.
    private func activateDesktopScanner(){
        guard connected && !busy && !stopping else{return}
        busy=true;cameraSuppressed=false
        status("正在打开扫一扫","正在准备桌面扫码…")
        operationTask=Task {
            var moved=false
            do {
                let switching=ProcessInfo.processInfo.systemUptime
                let endpoint=try await phone.mirrorEndpoint()
                try await prepareMirror(display:endpoint.display)
                let moving=ProcessInfo.processInfo.systemUptime
                try await phone.moveWechat(toVirtualDisplay:true);moved=true;mode = .wechat
                try Task.checkCancellation()
                try await showMirror(display:endpoint.display,after:moving)
                scannerSwitchMilliseconds=(ProcessInfo.processInfo.systemUptime-switching)*1000
                busy=false;startCamera()
            } catch {
                guard connected && !stopping && !Task.isCancelled else{return}
                let reason=error.localizedDescription
                if moved {
                    do {
                        try await phone.moveWechat(toVirtualDisplay:false)
                        try Task.checkCancellation();mode = .phone;try await showMirror(display:0)
                    } catch {
                        guard connected && !stopping && !Task.isCancelled else{return}
                        status("扫码切换未完成","恢复手机镜像失败，正在清理连接。"+error.localizedDescription)
                        disconnect(preserveError:true);return
                    }
                }
                busy=false;cameraSuppressed=true
                status("桌面相机未开启",reason)
            }
        }
    }
    private func returnToPhone(){
        guard connected && !busy && !stopping else{return}
        busy=true
        operationTask=Task {
            do {
                await clearCamera();try await phone.moveWechat(toVirtualDisplay:false)
                try Task.checkCancellation();mode = .phone;try await showMirror(display:0)
                cameraSuppressed=false;busy=false;lastUserInput = .distantPast
                status("微信","已回到真实手机镜像。扫码结果由你继续操作。")
            } catch {
                guard connected && !stopping else{return}
                status("返回手机未完成",error.localizedDescription);disconnect(preserveError:true)
            }
        }
    }
    private func home(){
        guard connected && !busy && !stopping else{return}
        busy=true;operationTask?.cancel()
        operationTask=Task {
            do {
                await clearCamera();cameraSuppressed=false
                if mode == .wechat {try await phone.moveWechat(toVirtualDisplay:false)}
                try await phone.mainHome();try Task.checkCancellation()
                mode = .phone;try await showMirror(display:0)
                busy=false;status("手机镜像","点击手机中的应用；微信桌面扫码会在同一个窗口打开。")
            } catch {
                guard !stopping && connected else{return}
                status("返回主屏幕未完成",error.localizedDescription);disconnect(preserveError:true)
            }
        }
    }
    private func startCamera(){
        guard connected && !busy && !stopping && !cameraSuppressed else{return}
        busy=true;operationTask?.cancel()
        operationTask=Task {
            do {
                await clearCamera();let generation=scanGeneration
                status("准备桌面相机","正在读取当前窗口后方的桌面画面…")
                try await capture.prepare();try Task.checkCancellation()
                guard connected && mode == .wechat && generation==scanGeneration else{return}
                cameraActive=true;paused=false;busy=false
                startCameraLoop()
                status("拖动窗口扫码","微信扫一扫正在读取窗口后方的桌面；拖动标题栏对准二维码，识别结果由你继续操作。")
            } catch {
                guard !stopping && connected else{return}
                busy=false;cameraSuppressed=true
                status("桌面相机未开启",error.localizedDescription)
                if await capture.permissionBlocked {
                    status("等待屏幕录制授权","请允许当前版本，随后点“授权后重启 App”。本次运行不会重复申请。")
                    control.showPermissionHelp(true)
                }
            }
        }
    }
    private func startLoop(){
        loop?.cancel()
        loop=Task {
            var nextActivity=Date.distantPast,nextHeartbeat=Date.distantPast,failures=0
            while connected && !Task.isCancelled {
                let generation=scanGeneration
                if Date()>=nextActivity && !busy && !Task.isCancelled {
                    do {
                        if mode == .wechat {
                            let component=try await phone.foreground(onVirtualDisplay:true)
                            guard connected && !busy && generation==scanGeneration && !Task.isCancelled else {continue}
                            let scanning=component?.hasPrefix("com.tencent.mm/")==true && component?.lowercased().contains("scanner")==true
                            if scanning && !cameraActive && !cameraSuppressed {startCamera()}
                            else if !scanning {
                                if component?.hasPrefix("com.tencent.mm/")==true {returnToPhone()}
                                else if cameraActive {await clearCamera();cameraSuppressed=true;status("桌面相机已停止","已离开微信扫一扫。")}
                            }
                        } else if Date().timeIntervalSince(lastUserInput)<12 {
                            let component=try await phone.foreground(onVirtualDisplay:false)
                            guard connected && !busy && generation==scanGeneration && !Task.isCancelled else {continue}
                            if component?.hasPrefix("com.tencent.mm/")==true && component?.lowercased().contains("scanner")==true {activateDesktopScanner()}
                        }
                        failures=0
                    } catch {failures+=1}
                    nextActivity=Date().addingTimeInterval(0.7)
                }
                if Date()>=nextHeartbeat && !Task.isCancelled {
                    do {try await phone.heartbeat();failures=0} catch {failures+=1}
                    nextHeartbeat=Date().addingTimeInterval(2)
                }
                if failures>=4 && !Task.isCancelled {
                    status("手机连接中断","请检查数据线与手机状态，再重新连接。")
                    disconnect(preserveError:true);break
                }
                try? await Task.sleep(nanoseconds:120_000_000)
            }
        }
    }
    private func updateCameraTick(){
        guard let pump=cameraPump,cameraActive,!paused else{return}
        do {pump.publish(try DesktopCaptureTarget.current(for:control.desktopCaptureRect))}
        catch {pump.fail(error)}
        let snapshot=pump.snapshot(),stats=snapshot.statistics
        framesSent=cameraFramesBase+stats.sent;cameraFPS=stats.fps
        captureMilliseconds=stats.captureMilliseconds;transferMilliseconds=stats.transferMilliseconds
        droppedCameraFrames=stats.dropped;maximumCameraGapMilliseconds=stats.maximumGapMilliseconds
        if let error=snapshot.failure {
            pump.stop();cameraPump=nil;cameraSuppressed=true;cameraLoop?.cancel()
            cameraActive=false;paused=true;busy=true;refresh()
            operationTask=Task {
                await clearCamera()
                guard connected,!stopping else{return}
                busy=false;status("桌面相机已暂停",error.localizedDescription)
                if await capture.permissionBlocked {control.showPermissionHelp(true)}
            }
        }
        let now=ProcessInfo.processInfo.systemUptime
        if now>=nextCameraDiagnostic {nextCameraDiagnostic=now+2;writeDiagnosticState()}
    }
    private func startCameraLoop(){
        cameraLoop?.cancel();cameraPump?.stop()
        let pump=CameraPumpMailbox(),generation=scanGeneration
        cameraPump=pump;cameraFramesBase=framesSent
        updateCameraTick()
        cameraLoop=Task.detached(priority:.userInitiated) { [capture,phone] in
            var stats=CameraPumpMailbox.Statistics()
            var measuredAt=ProcessInfo.processInfo.systemUptime,measuredFrames=0
            var transientFailureSince:TimeInterval?,lastSentAt:TimeInterval?
            while !Task.isCancelled,let target=pump.latest() {
                let began=ProcessInfo.processInfo.systemUptime
                do {
                    let image=try await capture.capture(target)
                    stats.captureMilliseconds=(ProcessInfo.processInfo.systemUptime-began)*1000
                    try Task.checkCancellation()
                    guard pump.latest() != nil else{break}
                    let sending=ProcessInfo.processInfo.systemUptime
                    // Freshness is checked again when the phone actor actually owns
                    // the socket, after any queued control command has completed.
                    try await phone.frame(image,epoch:generation,selectedAt:target.selectedAt)
                    let sentAt=ProcessInfo.processInfo.systemUptime
                    stats.sent+=1
                    if let previous=lastSentAt {stats.maximumGapMilliseconds=max(stats.maximumGapMilliseconds,(sentAt-previous)*1000)}
                    lastSentAt=sentAt;transientFailureSince=nil
                    stats.transferMilliseconds=(sentAt-sending)*1000
                    let duration=sentAt-measuredAt
                    if duration>=2 {
                        stats.fps=Double(stats.sent-measuredFrames)/duration
                        measuredFrames=stats.sent;measuredAt=sentAt
                    }
                    pump.update(stats)
                } catch {
                    guard !Task.isCancelled,pump.latest() != nil else{break}
                    if error is DesktopCaptureTransientError || error is CameraFrameExpiredError {
                        let now=ProcessInfo.processInfo.systemUptime
                        if transientFailureSince == nil {transientFailureSince=lastSentAt ?? began}
                        stats.dropped+=1;pump.update(stats)
                        if now-transientFailureSince! < 3 {
                            try? await Task.sleep(nanoseconds:33_000_000);continue
                        }
                    }
                    pump.fail(error)
                    // The UI owns stream stop/restart. A failed old worker must
                    // never stop a newer capture session during error recovery.
                    try? await phone.clear(epoch:generation)
                    break
                }
                let rest=max(0,1.0/30-(ProcessInfo.processInfo.systemUptime-began))
                if rest>0 {try? await Task.sleep(nanoseconds:UInt64(rest*1_000_000_000))}
            }
        }
    }
    private struct OCRText {let value:String;let rect:CGRect}
    private nonisolated static func textIn(_ pixels:CVPixelBuffer) throws -> [OCRText] {
        let request=VNRecognizeTextRequest()
        request.recognitionLevel = .accurate;request.recognitionLanguages=["zh-Hans","en-US"]
        try VNImageRequestHandler(cvPixelBuffer:pixels).perform([request])
        return (request.results ?? []).compactMap { item in
            guard let text=item.topCandidates(1).first?.string else{return nil}
            let b=item.boundingBox
            return OCRText(value:text,rect:CGRect(x:b.minX*720,y:(1-b.maxY)*1280,width:b.width*720,height:b.height*1280))
        }
    }
    /// Bounded navigation only: recognise the WeChat home/menu labels. Never
    /// click a scan result, authorization button, link, payment or chat item.
    private func openScanner() async throws -> Bool {
        let deadline=ProcessInfo.processInfo.systemUptime+4
        var openedMenu=false,tappedScanner=false
        while ProcessInfo.processInfo.systemUptime<deadline {
            try await Task.sleep(nanoseconds:120_000_000)
            guard let image=latestPhoneFrame else{continue}
            let words=try await Task.detached(priority:.userInitiated) {try Self.textIn(image)}.value
            try Task.checkCancellation()
            let scan=words.first{$0.value.replacingOccurrences(of:" ",with:"").contains("扫一扫")}
            if let scan,scan.rect.midY>950 {return true}
            if !tappedScanner,let scan,scan.rect.midY<950 && words.contains(where:{$0.value.contains("发起群聊") || $0.value.contains("添加朋友")}) {
                mirror.tap(x:Double(scan.rect.midX/720),y:Double(scan.rect.midY/1280))
                tappedScanner=true;continue
            }
            let home=words.contains{$0.value.contains("通讯录") && $0.rect.midY>1000} && words.contains{$0.value.contains("发现") && $0.rect.midY>1000}
            if !openedMenu,!tappedScanner,home,let title=words.filter({$0.value.hasPrefix("微信") && $0.rect.midY<250}).min(by:{$0.rect.minY<$1.rect.minY}) {
                mirror.tap(x:665.0/720,y:Double(title.rect.midY/1280))
                openedMenu=true
            }
            // Never repeat a tap against a not-yet-updated mirror frame, and
            // never navigate away from an unrecognised or scan-result page.
        }
        return false
    }
    private func togglePause(){
        guard connected && !busy else{return}
        guard mode == .wechat else{enterWechat(scan:true);return}
        if cameraActive {
            cameraSuppressed=true;busy=true;refresh()
            operationTask=Task {
                await clearCamera()
                guard connected && !stopping && !Task.isCancelled else{return}
                busy=false;status("桌面相机已暂停","镜像仍可操作，点桌面扫码可再次启动。")
            }
        } else {cameraSuppressed=false;startCamera()}
    }
    private func back(){
        guard connected && !busy else{return}
        busy=true;cameraSuppressed=true
        refresh()
        operationTask=Task {
            await clearCamera()
            guard connected && !stopping && !Task.isCancelled else{return}
            mirror.key(4)
            try? await Task.sleep(nanoseconds:250_000_000)
            guard connected && !stopping && !Task.isCancelled else{return}
            busy=false
            if mode == .phone {cameraSuppressed=false}
            refresh()
        }
    }
    private func tap(_ x:Double,_ y:Double){
        guard connected && !busy else{return}
        lastUserInput=Date();mirror.tap(x:x,y:y)
    }
    private func permissionSettings(){if let url=URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"){NSWorkspace.shared.open(url)}}
    private func relaunch(){relaunchAfterExit=true;NSApp.terminate(nil)}
    private func scheduleRelaunch(){
        let helper=Process();helper.executableURL=URL(fileURLWithPath:"/bin/sh")
        helper.arguments=["-c","while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; exec /usr/bin/open \"$2\"","scanner-relaunch",String(ProcessInfo.processInfo.processIdentifier),Bundle.main.bundleURL.path]
        helper.standardOutput=FileHandle.nullDevice;helper.standardError=FileHandle.nullDevice;try? helper.run()
    }
    private func disconnect(preserveError:Bool=false){
        guard !stopping else{return}
        stopping=true;busy=true;paused=true;cameraActive=false;scanGeneration+=1;mirrorGeneration+=1;physicalMirror.frames.stop();scannerMirror.frames.stop()
        connectionTask?.cancel();operationTask?.cancel();loop?.cancel();cameraPump?.stop();cameraPump=nil;cameraLoop?.cancel()
        refresh()
        if !preserveError {status("正在断开","正在结束手机镜像并清理临时连接…")}
        Task {
            await capture.stop();await stopMirrors()
            let problem=await phoneSession?.disconnect() ?? ""
            connected=false;busy=false;stopping=false;mirrorDisplay=nil;latestPhoneFrame=nil;control.setPhoneImage(nil)
            if !problem.isEmpty {status("需要重新连接以清理",problem)}
            else if !preserveError {status("已断开","可以拔线，下次直接连接即可。")}
            else {refresh();writeDiagnosticState()}
        }
    }
    func windowShouldClose(_ sender:NSWindow)->Bool {NSApp.terminate(nil);return false}
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {
        stopping=true;connectionTask?.cancel();operationTask?.cancel();loop?.cancel();cameraPump?.stop();cameraPump=nil;cameraLoop?.cancel()
        paused=true;cameraActive=false;scanGeneration+=1;mirrorGeneration+=1;busy=true
        physicalMirror.frames.stop();scannerMirror.frames.stop();previewTimer?.invalidate();previewTimer=nil
        status("正在退出","正在停止镜像并清理手机临时连接…")
        Task {
            await capture.stop();await stopMirrors()
            let problem=await phoneSession?.disconnect() ?? ""
            if !problem.isEmpty {
                let alert=NSAlert();alert.messageText="连接已停止，手机清理待恢复";alert.informativeText=problem
                alert.addButton(withTitle:"退出，下次连接时清理");alert.runModal()
            }
            if relaunchAfterExit {scheduleRelaunch()}
            NSApp.reply(toApplicationShouldTerminate:true)
        }
        return .terminateLater
    }
}
