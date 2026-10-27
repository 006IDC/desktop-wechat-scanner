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
    private let mainControl=ControlWindowController(), capture=DesktopCapture()
    private var desktopMode=false
    private var applicationPickerVisible=false
    private var cachedApplications:[AndroidApplication]?
    private var cameraWindow:ControlWindowController?
    private var cameraDisplay:Int?
    private var captureControl:ControlWindowController {cameraWindow ?? control}
    private var wechatWindow:ControlWindowController?
    private var control:ControlWindowController {wechatWindow ?? mainControl}
    private var connectionWindow:ConnectionWindowController?
    private var applicationLibrary:ApplicationLibrary?
    private var detachedApplications:DetachedApplications?
    private var catalogTask:Task<Void,Never>?
    private var physicalFrame:CVPixelBuffer?
    private var nextCameraGeometry=0.0
    private let physicalMirror=MirrorRoute(), scannerMirror=MirrorRoute()
    private var activeRoute:MirrorRoute {mirrorDisplay == nil || mirrorDisplay == 0 ? physicalMirror:scannerMirror}
    private var mirror:MirrorSession {activeRoute.session}
    private var phoneSession:PhoneSession?
    private var phone:PhoneSession { phoneSession! } // Set before any connected operation.
    private var adbURL:URL?
    private var adbServerSocket:String?
    private var wirelessServer:ADBManagedServer?
    private var wirelessEndpoint:String?
    private var adbSettingsItem:NSMenuItem?
    private var connected=false, busy=false, paused=true, stopping=false
    private var independentApplicationsWhenLocked=false, primaryLocked=false
    private var cameraActive=false, cameraSuppressed=false, mode=Mode.phone
    private var cameraPump:CameraPumpMailbox?,cameraFramesBase=0
    private var cameraActivity:NSObjectProtocol?
    private var localScanFrame:ScanFrameController?
    private var localScanRect:CGRect?
    private var localCameraMode=false
    private let nativeScannerRequested=CommandLine.arguments.contains("--native-camera-preview")
    private var nativeScannerOverlay:NativeScannerOverlay?
    private var nextCameraDiagnostic=0.0
    private var connectionTask:Task<Void,Never>?, operationTask:Task<Void,Never>?, loop:Task<Void,Never>?, cameraLoop:Task<Void,Never>?
    private var currentStatus="未连接", currentDetail="点击连接，选择 USB 手机或设置无线连接。"
    private var model="", scanGeneration=1, mirrorGeneration=0
    private var relaunchAfterExit=false, lastUserInput=Date.distantPast
    private var terminationReady=false,terminating=false
    private var framesSent=0, previewsReceived=0, cameraFPS=0.0
    private var latestPhoneFrame:CVPixelBuffer?
    private var mirrorDisplay:Int?
    private var scannerSwitchMilliseconds=0.0
    private var previewTimer:Timer?
    private var captureMilliseconds=0.0, transferMilliseconds=0.0, previewWaitMilliseconds=0.0
    private var droppedCameraFrames=0, maximumCameraGapMilliseconds=0.0
    private var screenAccessGranted=false
    private var permissionCheck:Task<Void,Never>?
    private var cameraTickAt:TimeInterval?,cameraTickGaps:[Double]=[]
    private var maximumCameraTickMilliseconds=0.0
    private var performanceCheck: ScanPerformanceCheck?
    private var performanceTask: Task<Void,Never>?
    private var launchDiagnosticTask: Task<Void,Never>?
    private var launchDiagnosticGeneration=0
    private var scanNavigation:[[String:Any]]=[]
    private var scannerNavigationMilliseconds=0.0
    private var savedDiagnosticToolbar=false
    private var diagnosticExitStatus:Int32=0
    private let diagnosticWriter=DiagnosticStateWriter(fileURL:FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
        .appendingPathComponent("006IDC/DesktopWeChatScanner/diagnostic-state.json"))

    func applicationDidFinishLaunching(_ notification:Notification) {
        buildMenu();control.window?.delegate=self
        if nativeScannerRequested {Task.detached(priority:.utility) {
            try? NativeScannerMatte.prewarm();try? NativeCalibrationImages.prewarm()
        }}
        let timer=Timer(timeInterval:1.0/60,target:self,selector:#selector(presentMirrorFrame),userInfo:nil,repeats:true)
        RunLoop.main.add(timer,forMode:.common);previewTimer=timer
        control.onConnect={ [weak self] in self?.connect() }
        control.onDisconnect={ [weak self] in self?.disconnect() }
        control.onScan={ [weak self] in self?.enterWechat(scan:true) }
        control.onPause={ [weak self] in self?.togglePause() }
        control.onBack={ [weak self] in self?.back() }
        control.onHome={ [weak self] in self?.home() }
        control.onWechat={ [weak self] in self?.enterWechat(scan:false) }
        control.onApplications={ [weak self] in self?.showApplications() }
        control.onPermissionSettings={ [weak self] in self?.permissionSettings() }
        control.onRelaunch={ [weak self] in self?.relaunch() }
        control.onTouch={ [weak self] action,x,y in
            guard let self,self.connected,!self.stopping,(self.desktopMode || !self.primaryLocked) else{return}
            self.lastUserInput=Date();self.activeRoute.session.touch(action:action,x:x,y:y)
        }
        control.onTap={ [weak self] x,y in
            guard let self,self.connected,!self.stopping,(self.desktopMode || !self.primaryLocked) else{return}
            self.lastUserInput=Date();self.activeRoute.session.tap(x:x,y:y)
        }
        control.onSwipe={ [weak self] x1,y1,x2,y2 in
            guard let self,self.connected,!self.busy,(self.desktopMode || !self.primaryLocked) else{return}
            self.lastUserInput=Date();self.activeRoute.session.swipe(x1:x1,y1:y1,x2:x2,y2:y2)
        }
        control.showWindow(nil);refresh();writeDiagnosticState()
        NSApp.activate(ignoringOtherApps:true)
        refreshScreenAccess()
        if CommandLine.arguments.contains("--run-scan-diagnostic") || CommandLine.arguments.contains("--run-desktop-diagnostic") {
            launchDiagnosticGeneration+=1
            let generation=launchDiagnosticGeneration
            launchDiagnosticTask=Task { await runLaunchDiagnostic(generation:generation) }
        }
    }

    /// Explicit native integration-test entry. Reuses only a previously chosen
    /// paired device and permission; never requests access, accepts a dialog or
    /// synthesizes OS input. The ordinary launch path is unchanged.
    private func runLaunchDiagnostic(generation:Int) async {
        func check() throws {
            try Task.checkCancellation()
            guard generation==launchDiagnosticGeneration,!stopping else{throw CancellationError()}
        }
        do {
            await permissionCheck?.value;try check()
            guard screenAccessGranted else{throw ScanError("诊断需要既有录屏授权，不会自动申请。")}
            let others=NSWorkspace.shared.runningApplications.filter {
                $0.bundleIdentifier==Bundle.main.bundleIdentifier && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
            }
            guard others.isEmpty else{throw ScanError("请先退出另一个扫码实例，诊断不共享正在运行的手机会话。")}
            guard let resources=Bundle.main.resourceURL else{throw ScanError("随包资源不可用。")}
            let adb=try await ADBConfiguration.validateAsync(resources.appendingPathComponent("adb/bin/adb"))
            try check()
            let device:ADBDevice
            if CommandLine.arguments.contains("--diagnostic-usb") {
                let devices=try await ADBConnectionManager(adbURL:adb).devices();try check()
                let authorized=devices.filter {$0.transport == .usb && $0.authorization == .authorized}
                guard authorized.count==1 else{throw ScanError("USB诊断要求唯一已授权手机。")}
                device=authorized[0];adbURL=adb
            } else {
                guard let remembered=WirelessReconnectStore().load() else{throw ScanError("没有已选择的无线手机，诊断不自动配对新设备。")}
                let owned=try await ADBManagedServer.start(adbURL:adb)
                do {try check()} catch {await owned.stop();throw error}
                let services=(try? await BonjourADBDiscovery().discover(seconds:3)) ?? []
                let endpoint=remembered.preferredEndpoint(in:services)
                wirelessServer=owned;adbServerSocket=owned.socket;wirelessEndpoint=endpoint;adbURL=adb
                let manager=ADBConnectionManager(adbURL:adb,serverSocket:owned.socket)
                try await manager.connect(endpoint:endpoint);try check()
                let devices=try await manager.devices();try check()
                guard let selected=devices.first(where:{$0.authorization == .authorized && $0.serial==endpoint}) else{throw ScanError("此前配对的手机当前不可连接。")}
                device=selected
            }
            let desktopDiagnostic=CommandLine.arguments.contains("--run-desktop-diagnostic")
            connectDevice(device,adb:adb,allowLockedApplications:UserDefaults.standard.bool(forKey:"allowsLockedApplications.v1"),diagnostic:!desktopDiagnostic)
            await connectionTask?.value;try check()
            guard connected,!busy,!stopping else{throw ScanError("手机诊断连接未就绪。")}
            if desktopDiagnostic {await runDesktopDiagnostic()}
            else {runPerformanceCheck();await performanceTask?.value}
            try check()
        } catch is CancellationError {return} catch {
            diagnosticExitStatus=1
            let folder=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("006IDC/DesktopWeChatScanner")
            let report:[String:Any]=["qrRecognized":false,"failure":error.localizedDescription,"updatedAt":ISO8601DateFormatter().string(from:Date())]
            let file=CommandLine.arguments.contains("--run-desktop-diagnostic") ? "desktop-performance-last.json":"performance-last.json"
            if let data=try? JSONSerialization.data(withJSONObject:report,options:.sortedKeys){try? data.write(to:folder.appendingPathComponent(file),options:.atomic)}
        }
        guard generation==launchDiagnosticGeneration,!stopping,!Task.isCancelled else{return}
        launchDiagnosticTask=nil
        // NSApp.terminate enters a nested AppKit run loop. Call it outside a
        // Swift MainActor task so the asynchronous cleanup can still execute.
        DispatchQueue.main.async {NSApp.terminate(nil)}
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
        for (title,key,action) in [("手机桌面","1",#selector(homeAction)),("暂停 / 继续桌面相机","p",#selector(pauseAction))] {
            actions.addItem(withTitle:title,action:action,keyEquivalent:key).target=self
        }
        actions.addItem(.separator())
        actions.addItem(withTitle:"关闭窗口",action:#selector(NSWindow.performClose(_:)),keyEquivalent:"w")
        actions.addItem(withTitle:"手机应用…",action:#selector(applicationsAction),keyEquivalent:"l").target=self
        item.submenu=actions;menu.addItem(item)
        let windowItem=NSMenuItem(),windows=NSMenu(title:"窗口")
        windows.addItem(withTitle:"最小化",action:#selector(NSWindow.performMiniaturize(_:)),keyEquivalent:"m")
        windows.addItem(withTitle:"手机镜像",action:#selector(showMainWindow),keyEquivalent:"0").target=self
        windowItem.submenu=windows;menu.addItem(windowItem);NSApp.windowsMenu=windows;NSApp.mainMenu=menu
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
        if let adbURL {return try await ADBConfiguration.validateAsync(adbURL)}
        if let bundled=Bundle.main.resourceURL?.appendingPathComponent("adb/bin/adb"),FileManager.default.isExecutableFile(atPath:bundled.path) {
            return try await ADBConfiguration.validateAsync(bundled)
        }
        if let selected=try await ADBConfiguration.discover(savedPath:UserDefaults.standard.string(forKey:ADBConfiguration.defaultsKey)) {
            UserDefaults.standard.set(selected.path,forKey:ADBConfiguration.defaultsKey)
            return selected
        }
        try Task.checkCancellation()
        let alert=NSAlert();alert.messageText="需要 Google Platform-Tools"
        alert.informativeText="此构建缺少随包 ADB。请重新安装完整发行包，或选择已有的 adb。也可以从 Google 官方网站下载 Platform-Tools，阅读并接受其许可后使用。"
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
    @objc private func applicationsAction(){showApplications()}
    @objc private func showMainWindow(){NSApp.activate(ignoringOtherApps:true);mainControl.window?.deminiaturize(nil);mainControl.showWindow(nil);mainControl.window?.makeKeyAndOrderFront(nil)}
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
        control.setCameraActive(cameraActive && (cameraWindow == nil || cameraWindow === control),paused:paused)
        if let cameraWindow,cameraWindow !== control {
            cameraWindow.update(status:cameraActive ? (paused ? "桌面相机已暂停":"拖动窗口扫码") : "手机应用",detail:currentDetail,connected:connected,busy:busy,paused:paused)
            cameraWindow.setCameraActive(cameraActive,paused:paused)
        }
        // Keep the complete native WeChat image. The desktop is supplied to
        // Android's virtual camera; no local aperture or replacement controls.
        control.setLocalScanPreview(false)
        if localCameraMode,paused {cameraWindow?.setLocalScanReview(true)}
        if wechatWindow != nil {
            mainControl.update(status:primaryLocked ? "手机主屏已锁定" : (connected ? "手机镜像 · \(model)" : currentStatus),detail:primaryLocked ? "独立应用仍可使用；正常解锁手机后恢复主屏镜像。" : "通过应用列表拖出应用，分别在 Mac 窗口里使用。",connected:connected,busy:stopping,paused:true)
        }
        control.setMode(cameraActive ? "桌面相机" : (desktopMode ? "手机桌面" : (mode == .phone ? "手机镜像" : "手机应用")))
    }
    private func writeDiagnosticState(){
        let ticks=cameraTickGaps.sorted()
        let tickP95=ticks.isEmpty ? 0:ticks[min(ticks.count-1,Int(Double(ticks.count)*0.95))]
        var value:[String:Any]=["status":currentStatus,"connected":connected,"paused":paused,"framesSent":framesSent,"previewsReceived":previewsReceived,"screenPermission":screenAccessGranted,"mode":mode == .phone ? "phone" : "wechat","cameraActive":cameraActive,"localCameraPreview":false,"independentApplicationsWhenLocked":independentApplicationsWhenLocked,"primaryLocked":primaryLocked,"cameraFPS":cameraFPS,"captureMilliseconds":captureMilliseconds,"transferMilliseconds":transferMilliseconds,"previewWaitMilliseconds":previewWaitMilliseconds,"droppedCameraFrames":droppedCameraFrames,"maximumCameraGapMilliseconds":maximumCameraGapMilliseconds,"scannerSwitchMilliseconds":scannerSwitchMilliseconds,"cameraTickP95Milliseconds":tickP95,"maximumCameraTickMilliseconds":maximumCameraTickMilliseconds,"updatedAt":ISO8601DateFormatter().string(from:Date())]
        let mirrorStats=scannerMirror.session.timingSnapshot
        value["cameraActivityActive"]=cameraActivity != nil
        value["localScanFrameVisible"]=localScanFrame?.window?.isVisible == true
        value["localCameraMode"]=localCameraMode
        value["desktopMode"]=desktopMode
        value["applicationPickerVisible"]=applicationPickerVisible
        value["mirrorRelativeBacklogP95Milliseconds"]=mirrorStats.relativeBacklogP95Milliseconds
        value["mirrorRelativeBacklogMaxMilliseconds"]=mirrorStats.relativeBacklogMaxMilliseconds
        value["mirrorDecodeP95Milliseconds"]=mirrorStats.decodeP95Milliseconds
        value["mirrorVideoPacketCount"]=mirrorStats.videoPacketCount
        value["mirrorDecodedFrameCount"]=mirrorStats.decodedFrameCount
        diagnosticWriter.submit(value)
    }
    private func connect(){
        guard !connected && !busy else{return}
        busy=true;status("选择手机","正在准备连接…")
        connectionTask=Task { [weak self] in
            guard let self else{return}
            do {
                guard let selected=try await resolveADB() else {busy=false;status("未连接","可以重新选择手机连接。");return}
                try Task.checkCancellation()
                let chooser=ConnectionWindowController(adbURL:selected) { [weak self] device in
                    guard let self else{return}
                    let window=self.connectionWindow
                    let allowLockedApplications=window?.allowsLockedApplications ?? false
                    self.status("正在连接","正在收束连接设置…")
                    self.connectionTask=Task {
                        let clean=await window?.waitForCleanup() ?? true
                        let ownedServer=window?.takeSelectedWirelessServer()
                        guard !self.stopping,!Task.isCancelled else{await ownedServer?.stop();return}
                        self.connectionWindow=nil
                        if clean {self.wirelessServer=ownedServer;self.connectDevice(device,adb:selected,allowLockedApplications:allowLockedApplications)}
                        else {
                            await ownedServer?.stop()
                            if device.serverSocket == nil,device.transport == .wireless,let endpoint=try? ADBEndpoint(device.serial).value {
                                try? await ADBConnectionManager(adbURL:selected).disconnect(endpoint:endpoint)
                            }
                            self.busy=false;self.status("无线连接未完全清理","请在手机关闭无线调试，再重新连接。配对信任不会自动撤销。")
                        }
                    }
                }
                chooser.onCancel={ [weak self] in
                    guard let self,!self.stopping else{return}
                    let window=self.connectionWindow
                    self.connectionTask=Task {
                        let clean=await window?.waitForCleanup() ?? true
                        guard !self.stopping else{return}
                        self.connectionWindow=nil;self.busy=false
                        self.status(clean ? "未连接":"无线连接未完全清理",clean ? "USB 和无线连接都可以在连接窗口设置。":"请在手机关闭无线调试，再重新连接。")
                    }
                }
                connectionWindow=chooser;chooser.show()
            } catch is CancellationError {} catch {busy=false;status("连接未完成",error.localizedDescription)}
        }
    }
    private func connectDevice(_ device:ADBDevice,adb selected:URL,allowLockedApplications:Bool,diagnostic:Bool=false){
        guard !connected,!stopping else{return}
        busy=true;status("正在连接",allowLockedApplications ? "正在确认手机的独立应用锁屏支持…" : "请保持手机解锁。")
        connectionTask=Task { [self] in
            do {
                guard device.serverSocket == nil || wirelessServer?.socket == device.serverSocket else {throw ScanError("无线服务已结束，请重新建立连接。")}
                adbServerSocket=device.serverSocket
                wirelessEndpoint=device.transport == .wireless ? (try? ADBEndpoint(device.serial).value):nil
                adbURL=selected;phoneSession=PhoneSession(resources:Bundle.main.resourceURL!,adbURL:selected,serverSocket:adbServerSocket)
                model=try await phone.connect(openWechatOnConnect:false,selectedSerial:device.serial,allowLockedApplications:allowLockedApplications,desktopHome:!diagnostic,realtimeVideo:nativeScannerRequested && !diagnostic){ [weak self] value in Task { @MainActor in self?.status("正在连接",value) } }
                try Task.checkCancellation();connected=true;mode = .phone;mirrorGeneration+=1
                independentApplicationsWhenLocked=await phone.independentApplicationsWhenLocked
                primaryLocked=independentApplicationsWhenLocked ? !(try await phone.primaryUserUnlocked()) : false
                desktopMode = !diagnostic
                mainControl.setPhoneDesktopMode(desktopMode)
                if desktopMode {
                    let endpoint=try await phone.mirrorEndpoint()
                    try await showMirror(display:endpoint.display)
                } else if !primaryLocked {try await showMirror(display:0)}
                try Task.checkCancellation();busy=false
                status(desktopMode ? "手机桌面" : (primaryLocked ? "手机主屏已锁定" : "已连接 · \(model)"),desktopMode ? "选择手机应用；微信和支付宝的扫一扫可自动读取窗口后方的电脑画面。" : "直接点击或滑动手机画面。")
                detachedApplications=DetachedApplications(phone:phone,adb:selected,server:Bundle.main.resourceURL!.appendingPathComponent("scrcpy-server"),serverSocket:adbServerSocket)
                detachedApplications?.beforeClose={ [weak self] display in
                    guard let self,self.cameraDisplay==display else{return}
                    await self.clearCamera()
                }
                startLoop()
                if desktopMode {return}
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
                status("连接未完成",error.localizedDescription)
                if diagnostic {busy=false;connected=false} else {disconnect(preserveError:true)}
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
        let check=performanceCheck
        var stage=ProcessInfo.processInfo.systemUptime
        check?.tick(at:stage)
        check?.recordPresentation("windowMotion",since:stage)
        stage=ProcessInfo.processInfo.systemUptime
        updateCameraTick()
        check?.recordPresentation("captureGeometry",since:stage)
        stage=ProcessInfo.processInfo.systemUptime
        detachedApplications?.present()
        check?.recordPresentation("detachedPresentation",since:stage)
        stage=ProcessInfo.processInfo.systemUptime
        defer {check?.recordPresentation("mirrorPresentation",since:stage)}
        if primaryLocked {_=physicalMirror.frames.takeLatest()}
        else if wechatWindow != nil,let frame=physicalMirror.frames.takeLatest(),frame.generation==physicalMirror.incarnation {
            physicalFrame=frame.pixelBuffer;mainControl.setPhonePixelBuffer(frame.pixelBuffer)
        }
        guard connected,!stopping,mirrorDisplay != nil,!(primaryLocked && mirrorDisplay == 0),let frame=activeRoute.frames.takeLatest(),frame.generation==activeRoute.incarnation else{return}
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
            let direct=try await phone.directMirror(display:display)
            try Task.checkCancellation()
            guard connected,!stopping,mirrorGeneration==generation,route.incarnation==incarnation else {throw CancellationError()}
            try await route.session.startVideo(adbURL:adbURL,serverURL:resources.appendingPathComponent("scrcpy-server"),serial:endpoint.serial,displayID:display,serverSocket:adbServerSocket,direct:direct,onFrame:{ [frames=route.frames] pixels in
                frames.publish(pixels,generation:incarnation)
            },onFailure:{ [weak self,weak route] message in
                Task { @MainActor in
                    guard let self,let route,self.connected,self.mirrorGeneration==generation,route.incarnation==incarnation,!self.stopping else{return}
                    route.failure=message
                    // A main-screen stream cannot take independent applications down.
                    if self.independentApplicationsWhenLocked,route === self.physicalMirror {
                        self.physicalFrame=nil;self.mainControl.setPhonePixelBuffer(nil)
                        return
                    }
                    if self.activeRoute === route {
                        self.status("镜像连接中断",message);self.disconnect(preserveError:true)
                    }
                }
            })
        }
        route.startup=task
        do {try await task.value}
        catch {
            if mirrorGeneration==generation,route.incarnation==incarnation {
                if display>0 {try? await phone.stopDirectMirror(display:display)}
                route.startup=nil;route.failure=error.localizedDescription
            }
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
                mirrorDisplay=display;present(frame);return
            }
            try await Task.sleep(nanoseconds:16_000_000)
        }
        throw ScanError("手机镜像首帧未就绪，请解锁手机后重新连接。")
    }
    /// Poll only the primary user's state. Never dismiss keyguard or inject an unlock.
    private func updatePrimaryLock() async throws {
        guard independentApplicationsWhenLocked else{return}
        let wasLocked=primaryLocked
        let locked = !(try await phone.pollPrimaryUserUnlocked())
        guard connected,!stopping,!Task.isCancelled else{return}
        primaryLocked=locked
        if desktopMode {return}
        if locked {
            physicalFrame=nil;mainControl.setPhonePixelBuffer(nil)
            if mode == .phone {latestPhoneFrame=nil;mirrorDisplay=nil}
            if !wasLocked,mode == .phone {status("手机主屏已锁定","独立应用仍可使用；正常解锁手机后恢复主屏镜像。")}
        } else {
            // Retry only the physical stream; independent windows retain their session.
            try await prepareMirror(display:0)
            guard connected,!stopping,!Task.isCancelled else{return}
            if mode == .phone {mirrorDisplay=0}
            if wasLocked,mode == .phone {status("手机镜像","手机已解锁，正在恢复主屏画面。")}
        }
        refresh()
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
    private func endCameraActivity() {
        guard let activity=cameraActivity else{return}
        cameraActivity=nil;ProcessInfo.processInfo.endActivity(activity)
    }
    private func showLocalScanFrame(for owner:ControlWindowController) {
        let frame=ScanFrameController();localScanFrame=frame;localScanRect=nil
        frame.onClose={ [weak self] in self?.returnLocalScanToApplication(retainImage:false) }
        frame.onPause={ [weak self] in self?.toggleLocalScanPause() }
        frame.onRescan={ [weak self] in
            guard let self,!self.paused else{return}
            self.localScanRect=nil
            self.cameraPump?.delayCapture(until:ProcessInfo.processInfo.systemUptime+0.18)
        }
        frame.onMoved={ [weak self] _ in
            guard let self else{return}
            self.localScanRect=nil
            self.cameraPump?.delayCapture(until:ProcessInfo.processInfo.systemUptime+0.18)
        }
        frame.show(near:owner.desktopCaptureRect)
        owner.window?.orderOut(nil)
    }
    private func dismissLocalScanFrame(restoring:Bool) {
        guard let frame=localScanFrame else{return}
        localScanFrame=nil;localScanRect=nil
        frame.onClose=nil;frame.onMoved=nil;frame.onPause=nil;frame.onRescan=nil
        frame.window?.orderOut(nil);frame.close()
        if restoring,let window=cameraWindow?.window {
            window.alphaValue=1;window.makeKeyAndOrderFront(nil)
        }
    }
    /// A QR presence check is only a handoff trigger. The native application
    /// alone decides what it means; no result or authorization is clicked here.
    private func returnLocalScanToApplication(retainImage:Bool) {
        guard connected,!stopping,localScanFrame != nil || nativeScannerOverlay != nil else{return}
        nativeScannerOverlay?.noteEnd(retainImage ? .qrHandoff:.returnedToApplication)
        nativeScannerOverlay?.freeze();cameraWindow?.freezeNativeScanner()
        let previousOperation=operationTask;previousOperation?.cancel()
        busy=true;paused=true;cameraSuppressed=true
        let previous=cameraLoop;cameraLoop=nil;previous?.cancel()
        cameraPump?.stop();cameraPump=nil;endCameraActivity()
        if !retainImage {scanGeneration+=1}
        let generation=scanGeneration
        dismissLocalScanFrame(restoring:true);refresh()
        operationTask=Task {
            await previousOperation?.value
            await previous?.value;await capture.stop()
            guard connected,!stopping,!Task.isCancelled,scanGeneration==generation else{return}
            if !retainImage {
                await stopNativeScannerOverlay()
                do {try await phone.clear(epoch:generation,requireConnection:true)}
                catch {localScanClearFailed();return}
            } else if let overlay=nativeScannerOverlay {
                let deadline=ProcessInfo.processInfo.systemUptime+3
                while connected,!stopping,!Task.isCancelled,scanGeneration==generation,
                      ProcessInfo.processInfo.systemUptime<deadline {
                    if let state=try? await phone.cameraState(),!overlay.matches(state) {break}
                    try? await Task.sleep(nanoseconds:50_000_000)
                }
                await stopNativeScannerOverlay()
            }
            guard connected,!stopping,!Task.isCancelled,scanGeneration==generation else{return}
            busy=false;cameraFPS=0
            status(retainImage ? "已送入手机识别":"已返回手机应用",
                   retainImage ? "识别与后续操作由手机应用完成；换二维码可点“重新框选”。":"手机画面可直接操作；需要桌面扫码时点“重新框选”。")
        }
    }
    private func localScanClearFailed() {
        guard connected,!stopping,!Task.isCancelled else{return}
        busy=false
        status("扫码清理未确认","手机未确认清除上一张桌面图，正在安全结束临时连接。")
        disconnect(preserveError:true)
    }
    private func toggleLocalScanPause() {
        guard connected,!stopping,!busy,let frame=localScanFrame else{return}
        busy=true
        if paused {
            let generation=scanGeneration
            operationTask=Task {
                do {
                    try await capture.prepare();try Task.checkCancellation()
                    guard connected,!stopping,localScanFrame === frame,scanGeneration==generation else{return}
                    paused=false;busy=false;frame.setPaused(false);localScanRect=nil
                    startCameraLoop();refresh();writeDiagnosticState()
                } catch {
                    guard connected,!stopping,!Task.isCancelled else{return}
                    busy=false;frame.setMessage("采集未恢复，请返回应用");refresh()
                }
            }
        } else {
            paused=true;scanGeneration+=1
            let generation=scanGeneration,previous=cameraLoop;cameraLoop=nil
            cameraPump?.stop();cameraPump=nil;previous?.cancel();endCameraActivity()
            frame.setPaused(true);refresh()
            operationTask=Task {
                await previous?.value;await capture.stop()
                guard connected,!stopping,!Task.isCancelled,localScanFrame === frame,scanGeneration==generation else{return}
                do {try await phone.clear(epoch:generation,requireConnection:true)}
                catch {localScanClearFailed();return}
                guard connected,!stopping,!Task.isCancelled,localScanFrame === frame,scanGeneration==generation else{return}
                busy=false;refresh();writeDiagnosticState()
            }
        }
    }
    @discardableResult private func clearCamera() async -> Bool {
        let clearingLocal=localCameraMode
        dismissLocalScanFrame(restoring:true)
        localCameraMode=false
        endCameraActivity()
        let previousCamera=cameraLoop;cameraLoop=nil
        paused=true;cameraActive=false;scanGeneration+=1;cameraPump?.stop();cameraPump=nil;previousCamera?.cancel();cameraFPS=0;refresh()
        await stopNativeScannerOverlay()
        await capture.stop()
        await previousCamera?.value
        let confirmed:Bool
        do {try await phone.clear(epoch:scanGeneration,requireConnection:true);confirmed=true}
        catch {confirmed=false}
        cameraWindow?.setCameraActive(false);cameraWindow=nil;cameraDisplay=nil
        if clearingLocal,!confirmed {localScanClearFailed()}
        return confirmed
    }
    private func stopNativeScannerOverlay() async {
        guard let overlay=nativeScannerOverlay else{return}
        let window=cameraWindow
        nativeScannerOverlay=nil;overlay.freeze();window?.freezeNativeScanner()
        await overlay.stop();window?.endNativeScanner()
    }
    private func showApplications(){
        guard connected,!stopping else{return}
        if let library=applicationLibrary {library.showWindow(nil);library.window?.makeKeyAndOrderFront(nil);return}
        let library=ApplicationLibrary();applicationLibrary=library
        library.onOpen={ [weak self,weak library] app,point in
            guard let self,self.connected,!self.stopping else {
                library?.showError("手机尚未连接或正在断开，请连接后再打开应用。");return
            }
            if app.packageName=="com.tencent.mm" && !self.desktopMode {
                guard !self.busy else {library?.showError("正在准备手机，请稍候再打开微信。");return}
                self.enterWechat(scan:false,at:point)
            } else if self.detachedApplications?.open(app,at:point) != true {
                library?.showError("暂时无法打开此应用。请等待正在关闭的窗口完成，或关闭一个独立窗口后重试。")
            }
        }
        library.showWindow(nil)
        catalogTask=Task { [weak self,weak library] in
            guard let self else{return}
            do {let apps=try await phone.applications();try Task.checkCancellation();library?.setApplications(apps)}
            catch {if !Task.isCancelled {library?.showError(error.localizedDescription)}}
        }
    }
    private func configureWechatWindow(at point:NSPoint?){
        NSApp.activate(ignoringOtherApps:true)
        if let window=wechatWindow?.window {window.deminiaturize(nil);window.makeKeyAndOrderFront(nil);return}
        let window=ControlWindowController(title:"微信 · 手机应用",standalone:true,scanner:true)
        wechatWindow=window;window.window?.delegate=self
        window.onTouch={ [weak self] action,x,y in
            guard let self,self.connected,!self.stopping else{return}
            self.lastUserInput=Date();self.scannerMirror.session.touch(action:action,x:x,y:y)

        }
        window.onTap={ [weak self] x,y in self?.tap(x,y) }
        window.onSwipe={ [weak self] x1,y1,x2,y2 in
            guard let self,self.connected,!self.busy else{return}
            self.lastUserInput=Date();self.scannerMirror.session.swipe(x1:x1,y1:y1,x2:x2,y2:y2)
        }
        window.onBack={ [weak self] in self?.back() }
        window.onScan={ [weak self] in self?.enterWechat(scan:true) }
        window.onPause={ [weak self] in self?.togglePause() }
        window.onPermissionSettings={ [weak self] in self?.permissionSettings() }
        window.onRelaunch={ [weak self] in self?.relaunch() }
        if let native=window.window {AppWindowMotion.reveal(native,from:point)}
    }
    private func enterWechat(scan:Bool,at point:NSPoint?=nil){
        guard connected && !busy && !stopping else{return}
        let alreadyOpen=wechatWindow != nil && mode == .wechat && mirrorDisplay != nil
        configureWechatWindow(at:point)
        if alreadyOpen,scan,cameraActive,!paused {
            status("拖动窗口扫码","桌面相机已运行，移动窗口即可扫码。");return
        }
        busy=true;cameraSuppressed=false;operationTask?.cancel()
        status("正在打开微信","微信会保留在这个独立窗口里。")
        operationTask=Task {
            do {
                let endpoint=try await phone.mirrorEndpoint()
                try await prepareMirror(display:endpoint.display)
                // A retained Mac window is not proof that Android still has a
                // resumed WeChat task (the phone can reclaim/move it meanwhile).
                let foreground=alreadyOpen ? try await phone.foreground(onVirtualDisplay:true) : nil
                if !alreadyOpen || foreground?.hasPrefix("com.tencent.mm/") != true {
                    let began=ProcessInfo.processInfo.systemUptime
                    let apps=try await phone.applications()
                    guard let wechat=apps.first(where:{$0.packageName=="com.tencent.mm"}) else {throw ScanError("手机中没有找到微信入口。")}
                    try await phone.launchApplication(wechat,on:endpoint.display)
                    try Task.checkCancellation();mode = .wechat
                    try await showMirror(display:endpoint.display,after:began)
                    scannerSwitchMilliseconds=(ProcessInfo.processInfo.systemUptime-began)*1000
                }
                try Task.checkCancellation()
                if scan {
                    let opened=try await openScanner();try Task.checkCancellation();busy=false
                    if opened {startCamera()}
                    else {status("微信","在微信中点“＋ → 扫一扫”，桌面相机会自动启用。")}
                } else {busy=false;status("微信","独立窗口已打开；扫一扫会使用窗口后方的桌面画面。")}
            } catch {
                guard !stopping && connected && !Task.isCancelled else{return}
                busy=false;status("微信未打开",error.localizedDescription)
                // Keep the window and ownership available for retry or safe close.
            }
        }
    }
    private func activateDesktopScanner(){
        if wechatWindow == nil {enterWechat(scan:true)}
        else {startCamera()}
    }
    private func returnToPhone(){
        guard connected && !stopping else{return}
        let checking=performanceTask;checking?.cancel()
        busy=true;refresh();let opening=operationTask;opening?.cancel()
        operationTask=Task {
            await checking?.value
            await opening?.value
            do {
                await clearCamera();try await phone.restoreScannerApplications();try Task.checkCancellation()
                wechatWindow?.window?.orderOut(nil);wechatWindow=nil;mode = .phone;mirrorDisplay=primaryLocked ? nil : 0
                if let physicalFrame {latestPhoneFrame=physicalFrame;mainControl.setPhonePixelBuffer(physicalFrame)}
                cameraSuppressed=false;busy=false;status(primaryLocked ? "手机主屏已锁定" : "手机镜像",primaryLocked ? "微信已移回手机；可再次打开独立应用，或正常解锁手机查看主屏。" : "微信已移回手机。")
            } catch {
                guard connected && !stopping && !Task.isCancelled else{return}
                busy=false;status("返回手机未完成",error.localizedDescription)
            }
        }
    }
    private func home(){
        guard connected && !stopping else{return}
        if desktopMode {scannerMirror.session.key(3)}
        else if !primaryLocked {physicalMirror.session.key(3)}
        showMainWindow()
    }
    private func startCamera(in requestedWindow:ControlWindowController?=nil,display requestedDisplay:Int?=nil){
        let targetWindow=requestedWindow ?? control
        let targetDisplay=requestedDisplay ?? mirrorDisplay
        guard connected && !busy && !stopping && !cameraSuppressed else{return}
        guard targetWindow.window?.isVisible == true,targetWindow.window?.isMiniaturized == false else{return}
        busy=true;operationTask?.cancel()
        operationTask=Task { [self] in
            do {
                guard await clearCamera() else{localScanClearFailed();return}
                let generation=scanGeneration
                status("准备桌面相机","正在读取当前窗口后方的桌面画面…")
                try await capture.prepare();try Task.checkCancellation()
                screenAccessGranted=true
                targetWindow.showPermissionHelp(false)
                guard connected && (desktopMode || mode == .wechat) && generation==scanGeneration else{busy=false;return}
                if desktopMode {
                    let current=try await phone.cameraState()
                    guard let scanner=current.scannerActivity(),scanner.displayId==targetDisplay else {
                        await capture.stop();busy=false;return
                    }
                }
                guard targetWindow.window?.isVisible == true,targetWindow.window?.isMiniaturized == false else {
                    await capture.stop();busy=false;cameraSuppressed=true;status("桌面相机已暂停","恢复窗口后点扫码继续。");return
                }
                cameraWindow=targetWindow;cameraDisplay=targetDisplay
                targetWindow.onPause={ [weak self] in self?.togglePause() }
                targetWindow.onPermissionSettings={ [weak self] in self?.permissionSettings() }
                targetWindow.onRelaunch={ [weak self] in self?.relaunch() }
                cameraActive=true;paused=false
                localCameraMode=desktopMode
                if localCameraMode,nativeScannerRequested,let targetDisplay {
                    let state=try await phone.cameraState()
                    if let scanner=state.scannerActivity(),scanner.displayId==targetDisplay {
                        let overlay=NativeScannerOverlay(display:targetDisplay,package:scanner.package,
                            fastCalibration:CommandLine.arguments.contains("--native-fast-calibration"))
                        nativeScannerOverlay=overlay;targetWindow.prepareNativeScanner(overlay)
                        status("准备原生扫码预览","正在校准手机应用自己的相机背景…")
                        try await overlay.prepare(phone:phone,epoch:generation)
                        try Task.checkCancellation()
                        guard connected,!stopping,generation==scanGeneration,nativeScannerOverlay === overlay else{throw CancellationError()}
                        targetWindow.showNativeScanner(overlay)
                    } else {showLocalScanFrame(for:targetWindow)}
                } else if localCameraMode {showLocalScanFrame(for:targetWindow)}
                busy=false
                startCameraLoop()
                status(nativeScannerOverlay != nil ? "原生扫一扫" : (localCameraMode ? "拖动扫码框":"拖动窗口扫码"),nativeScannerOverlay != nil ? "拖动窗口对准二维码；原生手机控件和识别结果保持在此窗口。" : (localCameraMode ? "透明框直接显示桌面；停稳后送入手机，结果在原应用中显示。":"拖动窗口对准二维码，由真实手机应用识别。"))
            } catch {
                guard !stopping && connected else{return}
                if nativeScannerOverlay != nil {_=await clearCamera()}
                busy=false;cameraSuppressed=true
                status("桌面相机未开启",error.localizedDescription)
                if await capture.permissionBlocked {
                    status("等待屏幕录制授权","请允许当前版本，随后点“授权后重启 App”。本次运行不会重复申请。")
                    targetWindow.showPermissionHelp(true)
                }
            }
        }
    }

    /// Explicit integration test of the ordinary HOME -> application -> native
    /// scanner route. Only our own window moves; no OS input is synthesized.
    /// Capture is restricted to the synthetic board before a scanner opens.
    private func runDesktopDiagnostic() async {
        var report:[String:Any]=["test":"desktop-native-app-flow","physicalMouseDragMeasured":false]
        var applications=[[String:Any]]()
        let activeExit=CommandLine.arguments.contains("--diagnostic-active-scanner-exit")
        if activeExit {report["test"]="desktop-native-active-scanner-exit"}
        do {
            guard desktopMode,screenAccessGranted else{throw ScanError("通用桌面诊断尚未就绪。")}
            report["primaryLockedBefore"]=try await !phone.primaryUserUnlocked()
            let homeDeadline=ProcessInfo.processInfo.systemUptime+10
            while !applicationPickerVisible && ProcessInfo.processInfo.systemUptime<homeDeadline {
                try Task.checkCancellation();try await Task.sleep(nanoseconds:100_000_000)
            }
            report["applicationPickerVisible"]=applicationPickerVisible
            let apps=try await phone.applications()
            for package in (activeExit ? ["com.tencent.mm"]:["com.tencent.mm","com.eg.android.AlipayGphone"]) {
                try Task.checkCancellation()
                guard let app=apps.first(where:{$0.packageName==package}) else{throw ScanError("测试应用未安装。")}
                var item:[String:Any]=["package":package,"qrRecognized":false]
                var observedOverlay:NativeScannerOverlay?
                do {
                    cameraSuppressed=true
                    try await performMainApplicationOpen(app)
                    try Task.checkCancellation()
                    guard connected,!busy,!stopping else{throw ScanError("测试应用未打开。")}
                    let check=try ScanPerformanceCheck(scanner:mainControl);performanceCheck=check
                    await capture.setDiagnosticBoard(CGWindowID(check.board.windowNumber))
                    cameraSuppressed=false
                    try await navigateDiagnosticScanner(package:package,evidence:&item)
                    let deadline=ProcessInfo.processInfo.systemUptime+12
                    while (!cameraActive || busy || cameraPump==nil) && ProcessInfo.processInfo.systemUptime<deadline {
                        try Task.checkCancellation();try await Task.sleep(nanoseconds:100_000_000)
                    }
                    guard cameraActive,!busy,cameraPump != nil,cameraWindow === mainControl else{throw ScanError("应用内扫一扫未自动启用桌面相机。")}
                    let nativeOverlay=nativeScannerOverlay;observedOverlay=nativeOverlay
                    item["nativeScannerPreviewVisible"]=mainControl.nativeScannerVisible
                    if let nativeOverlay {item["nativeCalibration"]=nativeOverlay.calibrationTiming}
                    if nativeOverlay != nil,CommandLine.arguments.contains("--diagnostic-native-hold") {
                        // Bounded observation window for real CUA pointer dragging;
                        // only the synthetic board remains eligible for capture.
                        item["interactivePreviewHoldSeconds"]=60
                        let input=mainControl.window.map {OwnWindowInputDiagnostic(window:$0)}
                        defer {_=input?.finish()}
                        if CommandLine.arguments.contains("--diagnostic-primary-screen"),
                           let screen=NSScreen.screens.first(where:{
                               ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value==CGMainDisplayID()
                           }),let window=mainControl.window {
                            let area=screen.visibleFrame,size=window.frame.size
                            window.setFrameOrigin(NSPoint(x:area.midX-size.width/2,y:area.midY-size.height/2))
                        }
                        let initial=mainControl.window?.frame.origin ?? .zero
                        let initialDragRequests=mainControl.nativeTitleDragRequests
                        let until=ProcessInfo.processInfo.systemUptime+60
                        var maximumDisplacement=0.0
                        while ProcessInfo.processInfo.systemUptime<until {
                            try Task.checkCancellation()
                            if let origin=mainControl.window?.frame.origin {
                                maximumDisplacement=max(maximumDisplacement,hypot(origin.x-initial.x,origin.y-initial.y))
                            }
                            try await Task.sleep(nanoseconds:50_000_000)
                        }
                        item["observedHoldWindowDisplacementPoints"]=maximumDisplacement
                        item["observedOwnWindowInput"]=input?.finish()
                        item["nativeTitleDragRequests"]=mainControl.nativeTitleDragRequests-initialDragRequests
                        guard cameraActive,!busy,nativeScannerOverlay === nativeOverlay else {
                            throw ScanError("原生预览在观察期间已结束，诊断不继续点击。")
                        }
                    }
                    item["automaticCameraStarted"]=true
                    item["encoderReportedLatencyFrames"]=await phone.encoderLatencyFrames()
                    item["localFrameVisible"]=localScanFrame?.window?.isVisible == true
                    if localScanFrame != nil {
                        toggleLocalScanPause();await operationTask?.value
                        guard paused,localScanFrame?.window?.isVisible == true,cameraPump==nil else{throw ScanError("透明框暂停未完成。")}
                        item["localPausePassed"]=true
                        toggleLocalScanPause();await operationTask?.value
                        guard !paused,cameraPump != nil else{throw ScanError("透明框恢复未完成。")}
                        item["localResumePassed"]=true
                        try await phone.discardFrame(epoch:scanGeneration)
                        item["sameEpochDiscardAcknowledged"]=true
                        returnLocalScanToApplication(retainImage:false);await operationTask?.value
                        guard paused,localScanFrame==nil,mainControl.window?.isVisible == true else{throw ScanError("透明框返回未完成。")}
                        item["localCancelPassed"]=true
                        togglePause();await operationTask?.value
                        guard localScanFrame?.window?.isVisible == true,!paused else{throw ScanError("重新框选未完成。")}
                        item["localReopenPassed"]=true
                    }
                    if let frame=localScanFrame {check.bindLocalFrame(frame)}
                    if activeExit {
                        let state=try await phone.cameraState()
                        item["activeScannerBeforeExit"]=nativeOverlay != nil && state.scannerActivity()?.package==package
                        item["activeStreamCountBeforeExit"]=state.activeStreams
                    } else {
                    let started=ProcessInfo.processInfo.systemUptime
                    check.start(at:started)
                    while ProcessInfo.processInfo.systemUptime-started<14 {
                        try Task.checkCancellation();try await Task.sleep(nanoseconds:200_000_000)
                        if check.qrVisible,let pixels=latestPhoneFrame {
                            let found=try await Task.detached {
                                try ScannerNavigationOCR.recognize(pixels).contains {
                                    $0.value.replacingOccurrences(of:" ",with:"").contains(ScanPerformanceCheck.payload)
                                }
                            }.value
                            if found {
                                item["qrRecognized"]=true
                                item["returnedToNativeWindow"]=mainControl.window?.isVisible == true && localScanFrame == nil
                                break
                            }
                        }
                    }
                    }
                    if let nativeOverlay {
                        item["nativePresentation"]=nativeOverlay.statistics.snapshot()
                    }
                } catch {item["failure"]=error.localizedDescription}
                if let check=performanceCheck {item.merge(check.finish()){_,new in new}}
                performanceCheck=nil;cameraSuppressed=true
                await clearCamera();await capture.setDiagnosticBoard(nil)
                if let observedOverlay {
                    item["nativePresentation"]=observedOverlay.statistics.snapshot()
                    item["nativeTermination"]=observedOverlay.termination
                }
                applications.append(item)
                if activeExit {break} // Keep the real scanner open for owned-device teardown.
                // This is the same Home command as the ordinary toolbar.
                home();try await Task.sleep(nanoseconds:500_000_000)
            }
            report["primaryLockedAfter"]=try await !phone.primaryUserUnlocked()
        } catch {report["failure"]=error.localizedDescription}
        if let check=performanceCheck {_=check.finish()};performanceCheck=nil
        cameraSuppressed=true;await clearCamera();await capture.setDiagnosticBoard(nil)
        report["applications"]=applications
        let passed:Bool
        if activeExit {
            passed=applications.count==1 && applications[0]["activeScannerBeforeExit"] as? Bool == true &&
                applications[0]["failure"] == nil && report["failure"] == nil
        } else {
            passed=applications.count==2 && applications.allSatisfy {
                $0["automaticCameraStarted"] as? Bool == true && $0["qrRecognized"] as? Bool == true && $0["failure"] == nil
            } && report["failure"] == nil
        }
        report["passed"]=passed
        if !passed {diagnosticExitStatus=1}
        report["screenPermission"]=screenAccessGranted
        report["updatedAt"]=ISO8601DateFormatter().string(from:Date())
        let folder=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("006IDC/DesktopWeChatScanner")
        if let data=try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]) {
            try? data.write(to:folder.appendingPathComponent("desktop-performance-last.json"),options:.atomic)
        }
    }
    private func navigateDiagnosticScanner(package:String,evidence:inout [String:Any]) async throws {
        let connectionGeneration=mirrorGeneration
        func checkNavigation() throws {
            try Task.checkCancellation()
            guard connected,!stopping,mirrorGeneration==connectionGeneration else{throw CancellationError()}
        }
        if CommandLine.arguments.contains("--diagnostic-manual-navigation") {
            evidence["manualNavigationRequested"]=true
            evidence["automaticNavigationDisabled"]=true
            let deadline=ProcessInfo.processInfo.systemUptime+90
            while ProcessInfo.processInfo.systemUptime<deadline {
                try checkNavigation()
                let state=try await phone.cameraState();try checkNavigation()
                if state.scannerActivity()?.package==package {return}
                try await Task.sleep(nanoseconds:150_000_000)
            }
            throw ScanError("等待界面工具打开真实扫一扫超时；诊断未自动点击。")
        }
        var plusTapped=false,scanTapped=false,returnedFromResult=false
        var scanAttempts=0,lastScanTap=0.0
        var observedHomeLabels=Set<String>()
        var stateSamples=0,targetActivitySamples=0,frameSamples=0
        defer {
            evidence["navigationStateSamples"]=stateSamples
            evidence["navigationTargetActivitySamples"]=targetActivitySamples
            evidence["navigationFrameSamples"]=frameSamples
            evidence["navigationPlusTapped"]=plusTapped
            evidence["navigationScanTapped"]=scanTapped
            evidence["navigationScanAttempts"]=scanAttempts
            evidence["navigationKnownLabels"]=observedHomeLabels.sorted()
        }
        let deadline=ProcessInfo.processInfo.systemUptime+30
        try await Task.sleep(nanoseconds:500_000_000)
        while ProcessInfo.processInfo.systemUptime<deadline {
            try checkNavigation()
            let state=try await phone.cameraState()
            try checkNavigation()
            stateSamples+=1
            if let scanner=state.scannerActivity(),scanner.component.hasPrefix(package+"/") {return}
            guard let display=await phone.scannerDisplay()?.id,
                  state.activities.contains(where:{$0.displayId==display && $0.component.hasPrefix(package+"/")}) else {
                try await Task.sleep(nanoseconds:120_000_000);continue
            }
            targetActivitySamples+=1
            let retryScan=scanTapped && scanAttempts<3 && ProcessInfo.processInfo.systemUptime-lastScanTap>=0.8
            if let pixels=latestPhoneFrame,!scanTapped || retryScan {
                frameSamples+=1
                let point=try await Task.detached(priority:.userInitiated) { () -> (CGPoint?,Bool,Bool,[String]) in
                    let words=try ScannerNavigationOCR.recognize(pixels)
                    let known=["首页","消息","生活","理财","我的","支付宝","收付款","收付钱","扫一扫","微信","通讯录","发现","我"]
                    let labels=words.filter{known.contains($0.value)}.map(\.value)
                    let ownResult=words.contains{$0.value.replacingOccurrences(of:" ",with:"").contains(ScanPerformanceCheck.payload)}
                    if ownResult {return (nil,false,true,labels)}
                    // Alipay business pages may also contain this text. Require
                    // its home navigation and payment toolbar before any tap.
                    let alipayTabs=Set(words.filter{$0.rect.midY>1000 && ["消息","理财","生活"].contains($0.value)}.map(\.value))
                    let alipayHome=package != "com.eg.android.AlipayGphone" || (
                        (words.contains{$0.value=="首页" && $0.rect.midY>1000} || alipayTabs.count>=2) &&
                        words.contains{$0.value=="我的" && $0.rect.midY>1000} &&
                        words.contains{["收付款","收付钱"].contains($0.value) && $0.rect.midY<400})
                    if alipayHome,let scan=words.first(where:{$0.value.replacingOccurrences(of:" ",with:"")=="扫一扫" && $0.rect.midY<(package=="com.eg.android.AlipayGphone" ? 400:800)}) {
                        return (CGPoint(x:scan.rect.midX/720,y:scan.rect.midY/1280),false,false,labels)
                    }
                    if package=="com.tencent.mm",let plus=try ScannerNavigationOCR.plusButton(in:pixels,homeWords:words) {
                        return (CGPoint(x:plus.x/720,y:plus.y/1280),true,false,labels)
                    }
                    return (nil,false,false,labels)
                }.value
                try checkNavigation()
                guard ProcessInfo.processInfo.systemUptime<deadline else{break}
                observedHomeLabels.formUnion(point.3)
                if point.2,!returnedFromResult {
                    try checkNavigation();scannerMirror.session.key(4);returnedFromResult=true
                }
                else if let target=point.0,!(point.1 && plusTapped) {
                    let current=try await phone.cameraState()
                    try checkNavigation()
                    guard current.scannerActivity()==nil,
                          current.activities.first(where:{$0.displayId==display})?.component == state.activities.first(where:{$0.displayId==display})?.component else {
                        continue
                    }
                    try checkNavigation();scannerMirror.session.tap(x:target.x,y:target.y)
                    if point.1 {plusTapped=true}else{scanTapped=true;scanAttempts+=1;lastScanTap=ProcessInfo.processInfo.systemUptime}
                    try await Task.sleep(nanoseconds:400_000_000)
                }
            }
            try await Task.sleep(nanoseconds:120_000_000)
        }
        if let foreground=try? await phone.foreground(onVirtualDisplay:true) {
            evidence["navigationForegroundMatchesPackage"]=foreground.hasPrefix(package+"/")
        }
        throw ScanError("未确认真实应用的扫一扫入口，测试未点击其他内容。已见固定标签："+observedHomeLabels.sorted().joined(separator:","))
    }

    @objc private func runPerformanceCheck() {
        guard performanceTask == nil,connected,!busy,!stopping,screenAccessGranted else {
            status("自检尚未开始","请先连接手机并打开已授权的桌面扫码窗口。");return
        }
        performanceTask=Task { [weak self] in
            guard let self else{return}
            var report:[String:Any]=["qrRecognized":false]
            do {
                if !cameraActive { enterWechat(scan:true) }
                let ready=ProcessInfo.processInfo.systemUptime+12
                while !cameraActive && ProcessInfo.processInfo.systemUptime<ready {
                    try Task.checkCancellation();try await Task.sleep(nanoseconds:100_000_000)
                }
                guard cameraActive,let scanner=wechatWindow else{throw ScanError("微信尚未进入扫一扫；未运行移动测试。")}
                busy=true
                await clearCamera()
                let check=try ScanPerformanceCheck(scanner:scanner);performanceCheck=check
                await capture.setDiagnosticBoard(CGWindowID(check.board.windowNumber))
                // Capture starts only now, after the synthetic board is visible.
                try await capture.prepare();try Task.checkCancellation()
                cameraSuppressed=false;cameraActive=true;paused=false;busy=false
                startCameraLoop();status("正在检查流畅度","先往返移动 6 秒，再验证纯文本测试二维码；不会操作登录或支付。")
                let started=ProcessInfo.processInfo.systemUptime
                check.start(at:started)
                while ProcessInfo.processInfo.systemUptime-started<14 {
                    try Task.checkCancellation()
                    try await Task.sleep(nanoseconds:200_000_000)
                    if check.qrVisible,let pixels=latestPhoneFrame {
                        let result=try await Task.detached {
                            let words=try Self.textIn(pixels)
                            let barcode=VNDetectBarcodesRequest();barcode.symbologies=[.qr]
                            try VNImageRequestHandler(cvPixelBuffer:pixels).perform([barcode])
                            let visible=barcode.results?.contains{$0.payloadStringValue==ScanPerformanceCheck.payload} ?? false
                            return (words.contains{$0.value.replacingOccurrences(of:" ",with:"").contains(ScanPerformanceCheck.payload)},visible)
                        }.value
                        report["phoneSyntheticQRVisible"]=(report["phoneSyntheticQRVisible"] as? Bool == true) || result.1
                        // A plain-text result can stay in the scanner activity.
                        // The exact payload is never printed on the Mac test board.
                        if result.0 {
                            report["qrRecognized"]=true
                            report["qrRecognitionMilliseconds"]=(ProcessInfo.processInfo.systemUptime-started-6)*1000
                            break
                        }
                    }
                }
            } catch { report["failure"]=error.localizedDescription }
            if let check=performanceCheck {report.merge(check.finish()){_,new in new}}
            performanceCheck=nil
            report["navigation"]=scanNavigation
            report["scannerNavigationMilliseconds"]=scannerNavigationMilliseconds
            report["captureMilliseconds"]=captureMilliseconds
            report["transferMilliseconds"]=transferMilliseconds
            report["cameraFPS"]=cameraFPS
            report["maximumSendGapMilliseconds"]=maximumCameraGapMilliseconds
            let mirrorStats=scannerMirror.session.timingSnapshot
            report["mirrorRelativeBacklogP95Milliseconds"]=mirrorStats.relativeBacklogP95Milliseconds
            report["mirrorDecodeP95Milliseconds"]=mirrorStats.decodeP95Milliseconds
            report["mirrorReceivedBytes"]=mirrorStats.receivedBytes
            report["mirrorReceiveBytesPerSecond"]=mirrorStats.receivedBytesPerSecond
            cameraSuppressed=true
            if connected {await clearCamera()}
            await capture.setDiagnosticBoard(nil)
            let folder=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("006IDC/DesktopWeChatScanner")
            report["updatedAt"]=ISO8601DateFormatter().string(from:Date())
            if let data=try? JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted]) {
                try? data.write(to:folder.appendingPathComponent("performance-last.json"),options:.atomic)
            }
            performanceTask=nil
            guard connected,!stopping,!Task.isCancelled else{return}
            busy=false
            let recognized=report["qrRecognized"] as? Bool == true
            status("流畅度检查已结束",recognized ? "测试二维码已由手机微信识别，性能数据已保存；桌面相机已暂停。" : "性能数据已保存；本轮未确认手机识别结果，桌面相机已暂停。")
        }
    }
    private func followCameraState(_ state:PhoneCameraState) async {
        guard connected,!stopping,!busy else{return}
        if let overlay=nativeScannerOverlay,!overlay.matches(state) {
            overlay.noteStateChange(state)
            _=await clearCamera()
            guard connected,!stopping,!Task.isCancelled else{return}
        }
        let mainDisplay=await phone.scannerDisplay()?.id
        if let mainDisplay {try? await followDesktopHome(state,display:mainDisplay)}
        let windows=detachedApplications?.cameraWindows() ?? []
        guard let activity=state.scannerActivity(),
              let target=activity.displayId==mainDisplay ? mainControl : windows.first(where:{$0.display==activity.displayId})?.window else {
            if cameraActive {
                await clearCamera()
                guard connected,!stopping,!Task.isCancelled else{return}
                status("手机桌面","在应用里打开扫一扫，桌面相机会自动出现。")
            }
            if state.activeStreams==0 || !state.activities.contains(where:{DesktopScannerRoute.isScanner($0.component)}) {cameraSuppressed=false}
            return
        }
        if cameraActive,cameraDisplay != activity.displayId {await clearCamera()}
        guard connected,!stopping,!Task.isCancelled,!cameraActive,!cameraSuppressed,!busy,target.window?.isVisible==true,
              target.window?.isMiniaturized==false else{return}
        startCamera(in:target,display:activity.displayId)
    }
    private func followDesktopHome(_ state:PhoneCameraState,display:Int) async throws {
        guard let activity=state.activities.first(where:{$0.displayId==display}) else{return}
        // This ROM's native secondary HOME was tested: it resumes but draws a
        // blank page. Show a clearly labelled Mac app picker, never a fake HOME.
        let needsPicker=activity.component=="com.miui.home/com.miui.home.launcher.SecondaryDisplayLauncher"
        guard needsPicker != applicationPickerVisible else{return}
        if needsPicker {
            let apps:[AndroidApplication]
            if let cachedApplications {apps=cachedApplications}
            else {apps=try await phone.applications();cachedApplications=apps}
            guard connected,!stopping,!Task.isCancelled else{return}
            let current=try await phone.cameraState()
            guard current.activities.first(where:{$0.displayId==display})?.component==activity.component else{return}
            applicationPickerVisible=true
            mainControl.showApplicationPicker(apps,onOpen:{ [weak self] app in self?.openMainApplication(app) },
                onDetach:{ [weak self] app,point in _=self?.detachedApplications?.open(app,at:point) })
            if !cameraActive {status("手机应用","选择应用后显示真实手机画面；已适配微信与支付宝的扫一扫入口。")}
        } else {
            applicationPickerVisible=false;mainControl.hideApplicationPicker()
        }
    }
    private func openMainApplication(_ app:AndroidApplication) {
        guard connected,!busy,!stopping else{return}
        busy=true;refresh()
        operationTask=Task { [self] in
            do {
                try await performMainApplicationOpen(app)
            } catch {
                guard connected,!stopping,!Task.isCancelled else{return}
                busy=false;status("应用打开未完成",error.localizedDescription)
            }
        }
    }
    /// Shared by a user selection and the explicit integration diagnostic. An
    /// unsuccessful launch must propagate before any scanner navigation begins.
    private func performMainApplicationOpen(_ app:AndroidApplication) async throws {
        try Task.checkCancellation()
        guard connected,!stopping else{throw ScanError("手机暂时无法打开应用。")}
        let generation=mirrorGeneration
        busy=true;status("正在打开 \(app.name)","应用在手机运行，画面保留在当前窗口。")
        defer {if connected,!stopping,mirrorGeneration==generation {busy=false;refresh()}}
        await clearCamera()
        try Task.checkCancellation()
        guard connected,!stopping,mirrorGeneration==generation else{throw CancellationError()}
        guard let display=await phone.scannerDisplay()?.id else{throw ScanError("手机桌面尚未准备好。")}
        try Task.checkCancellation()
        guard connected,!stopping,mirrorGeneration==generation else{throw CancellationError()}
        try await phone.launchApplication(app,on:display);try Task.checkCancellation()
        guard connected,!stopping,mirrorGeneration==generation else{throw CancellationError()}
        applicationPickerVisible=false;mainControl.hideApplicationPicker()
        status(app.name,"直接操作手机应用。")
    }
    private func startLoop(){
        loop?.cancel()
        loop=Task {
            var nextActivity=Date.distantPast,nextHeartbeat=Date.distantPast,failures=0
            while connected && !Task.isCancelled {
                let generation=scanGeneration
                if Date()>=nextActivity && !busy && !Task.isCancelled {
                    do {
                        if desktopMode {
                            let state=try await phone.cameraState()
                            guard connected,!stopping,!Task.isCancelled else{continue}
                            await followCameraState(state)
                        } else if mode == .wechat {
                            let component=try await phone.foreground(onVirtualDisplay:true)
                            guard connected && !busy && generation==scanGeneration && !Task.isCancelled else {continue}
                            let scanning=component?.hasPrefix("com.tencent.mm/")==true && component?.lowercased().contains("scanner")==true
                            if scanning && !cameraActive && !cameraSuppressed {startCamera()}
                            else if !scanning {
                                if cameraActive {
                                    // During the QR phase, leaving Scanner is the
                                    // expected result. Earlier navigation aborts the test.
                                    if performanceCheck?.qrVisible != true {
                                        let checking=performanceTask;checking?.cancel();await checking?.value
                                    }
                                    await clearCamera();cameraSuppressed=false;status("微信","已离开扫一扫；结果保留在此窗口中。")
                                }
                            }
                        } else if Date().timeIntervalSince(lastUserInput)<12 {
                            let component=try await phone.foreground(onVirtualDisplay:false)
                            guard connected && !busy && generation==scanGeneration && !Task.isCancelled else {continue}
                            if component?.hasPrefix("com.tencent.mm/")==true && component?.lowercased().contains("scanner")==true {activateDesktopScanner()}
                        }
                        failures=0
                    } catch {failures+=1}
                    // An active scanner shares this socket with desktop frames.
                    // Keep entry detection quick, but avoid ten competing state
                    // round trips per second while scanning. Android still
                    // invalidates ownership/activity on every submitted frame.
                    nextActivity=Date().addingTimeInterval(desktopMode ? (cameraActive ? 0.25:0.1) : (mode == .wechat ? 0.25:0.7))
                }
                if Date()>=nextHeartbeat && !Task.isCancelled {
                    do {try await phone.heartbeat();failures=0} catch {failures+=1}
                    // A physical mirror failure does not invalidate the authenticated
                    // virtual-device heartbeat or close independent windows.
                    if !busy && !desktopMode {try? await updatePrimaryLock()}
                    nextHeartbeat=Date().addingTimeInterval(2)
                }
                if failures>=4 && !Task.isCancelled {
                    status("手机连接中断","请检查数据线与手机状态，再重新连接。")
                    disconnect(preserveError:true);break
                }
                try? await Task.sleep(nanoseconds:desktopMode ? 60_000_000:120_000_000)
            }
        }
    }
    func windowWillMiniaturize(_ notification:Notification) {
        if notification.object as? NSWindow === wechatWindow?.window {suspendHiddenCamera()}
    }
    private func suspendHiddenCamera(){
        guard connected,!stopping,!busy,cameraActive else{return}
        nativeScannerOverlay?.noteEnd(.windowHidden)
        let checking=performanceTask;checking?.cancel()
        busy=true;cameraSuppressed=true;cameraPump?.stop();refresh()
        operationTask=Task {
            await checking?.value
            await clearCamera()
            guard connected,!stopping,!Task.isCancelled else{return}
            busy=false;status("桌面相机已暂停","窗口已收起；恢复窗口后点扫码继续。")
        }
    }
    private func updateCameraTick(){
        guard let pump=cameraPump,cameraActive,!paused else{return}
        let visible=localCameraMode && nativeScannerOverlay == nil ? localScanFrame?.window?.isVisible == true :
            (captureControl.window?.isVisible == true && captureControl.window?.isMiniaturized == false)
        guard visible else {
            suspendHiddenCamera();return
        }
        let tick=ProcessInfo.processInfo.systemUptime
        if let failure=nativeScannerOverlay?.failure {pump.fail(ScanError(failure))}
        if let previous=cameraTickAt {
            let gap=(tick-previous)*1000
            cameraTickGaps.append(gap)
            if cameraTickGaps.count>180 {cameraTickGaps.removeFirst()}
            maximumCameraTickMilliseconds=max(maximumCameraTickMilliseconds,gap)
        }
        cameraTickAt=tick
        if tick>=nextCameraGeometry {
            nextCameraGeometry=tick+1.0/30
            do {
                let rect=localScanFrame?.captureRect ?? captureControl.desktopCaptureRect
                if localCameraMode,localScanRect != rect {
                    localScanRect=rect;pump.delayCapture(until:tick+0.18)
                }
                performanceCheck?.recordCaptureRect(rect,at:tick)
                pump.publish(try DesktopCaptureTarget.current(for:rect))
            }
            catch {pump.fail(error)}
        }
        let snapshot=pump.snapshot(),stats=snapshot.statistics
        performanceCheck?.recordPump(stats,at:tick)
        framesSent=cameraFramesBase+stats.sent;cameraFPS=stats.fps
        captureMilliseconds=stats.captureMilliseconds;transferMilliseconds=stats.transferMilliseconds
        droppedCameraFrames=stats.dropped;maximumCameraGapMilliseconds=stats.maximumGapMilliseconds
        if localCameraMode,pump.canHandoff(at:tick) {
            returnLocalScanToApplication(retainImage:true)
            return
        }
        if let error=snapshot.failure {
            nativeScannerOverlay?.notePumpFailure(error)
            let checking=performanceTask;checking?.cancel()
            pump.stop();cameraPump=nil;cameraSuppressed=true;cameraLoop?.cancel()
            cameraActive=false;paused=true;busy=true;refresh()
            operationTask=Task {
                await checking?.value
                let cleared=await clearCamera()
                guard connected,!stopping else{return}
                if !cleared {localScanClearFailed();return}
                busy=false;status("桌面相机已暂停",error.localizedDescription)
                if await capture.permissionBlocked {captureControl.showPermissionHelp(true)}
            }
        }
        let now=ProcessInfo.processInfo.systemUptime
        if now>=nextCameraDiagnostic {nextCameraDiagnostic=now+2;writeDiagnosticState()}
    }
    private func startCameraLoop(){
        cameraLoop?.cancel();cameraPump?.stop()
        // A live, user-requested scanner must keep receiving presentation ticks
        // when the user focuses the QR in another app. Scope the activity to the
        // active camera, and still allow ordinary idle system/display sleep.
        if cameraActivity == nil {
            cameraActivity=ProcessInfo.processInfo.beginActivity(options:.userInitiatedAllowingIdleSystemSleep,
                reason:"实时手机桌面相机")
        }
        cameraTickAt=nil;cameraTickGaps.removeAll(keepingCapacity:true);maximumCameraTickMilliseconds=0
        let pump=CameraPumpMailbox(),generation=scanGeneration
        let diagnosticQRStart=performanceCheck == nil ? Double.infinity:ProcessInfo.processInfo.systemUptime+6.2
        let saveSyntheticPattern=performanceCheck != nil && CommandLine.arguments.contains("--diagnostic-pattern")
        cameraPump=pump;cameraFramesBase=framesSent
        let localFrameMode=localCameraMode
        if localFrameMode {localScanRect=nil}
        updateCameraTick()
        cameraLoop=Task.detached(priority:.userInitiated) { [capture,phone] in
            var stats=CameraPumpMailbox.Statistics()
            var measuredAt=ProcessInfo.processInfo.systemUptime,measuredFrames=0
            var transientFailureSince:TimeInterval?,lastSentAt:TimeInterval?
            var lastQRCheck=0.0,savedPattern=false
            while !Task.isCancelled,let selection=pump.selection() {
                let target=selection.target
                let began=ProcessInfo.processInfo.systemUptime
                if localFrameMode,!pump.captureReady(at:began) {
                    try? await Task.sleep(nanoseconds:25_000_000);continue
                }
                do {
                    let image=try await capture.capture(target,maximumDimension:1280)
                    stats.captureMilliseconds=(ProcessInfo.processInfo.systemUptime-began)*1000
                    try Task.checkCancellation()
                    guard pump.latest() != nil else{break}
                    if localFrameMode,(!pump.captureReady(at:ProcessInfo.processInfo.systemUptime) || !pump.isCurrent(selection)) {continue}
                    var localCodeVisible=false
                    if localFrameMode {
                        let request=VNDetectBarcodesRequest();request.symbologies=[.qr]
                        try VNImageRequestHandler(data:image).perform([request])
                        // Presence only: never read or follow a real QR payload.
                        localCodeVisible = !(request.results?.isEmpty ?? true)
                        if !pump.captureReady(at:ProcessInfo.processInfo.systemUptime) || !pump.isCurrent(selection) {continue}
                        if !localCodeVisible {
                            pump.update(stats)
                            try await Task.sleep(nanoseconds:250_000_000)
                            continue
                        }
                    }
                    let sending=ProcessInfo.processInfo.systemUptime
                    // Freshness is checked again when the phone actor actually owns
                    // the socket, after any queued control command has completed.
                    let validator:(@Sendable ()->Bool)?
                    if localFrameMode {
                        validator={pump.isCurrent(selection) && pump.captureReady(at:ProcessInfo.processInfo.systemUptime)}
                    } else {validator=nil}
                    let receipt=try await phone.frame(image,epoch:generation,selectedAt:target.selectedAt,isCurrent:validator)
                    let sentAt=ProcessInfo.processInfo.systemUptime
                    if localFrameMode,!pump.isCurrent(selection) {
                        try await phone.discardFrame(epoch:generation)
                        stats.dropped+=1;pump.update(stats);continue
                    }
                    stats.sent+=1
                    if let previous=lastSentAt {stats.maximumGapMilliseconds=max(stats.maximumGapMilliseconds,(sentAt-previous)*1000)}
                    lastSentAt=sentAt;transientFailureSince=nil
                    stats.transferMilliseconds=(sentAt-sending)*1000
                    stats.imageBytes=image.count
                    stats.phoneProcessingMilliseconds=receipt.processingMilliseconds
                    stats.requestMilliseconds=receipt.requestMilliseconds
                    stats.actorWaitMilliseconds=max(0,stats.transferMilliseconds-receipt.requestMilliseconds)
                    stats.sendMilliseconds=receipt.sendMilliseconds
                    stats.responseWaitMilliseconds=receipt.responseWaitMilliseconds
                    stats.responseBodyMilliseconds=receipt.responseBodyMilliseconds
                    if localFrameMode,localCodeVisible {
                        stats.localQRSubmitted=true;stats.localSubmission=selection
                    }
                    let duration=sentAt-measuredAt
                    if duration>=2 {
                        stats.fps=Double(stats.sent-measuredFrames)/duration
                        measuredFrames=stats.sent;measuredAt=sentAt
                    }
                    if !stats.syntheticQRVisible,sentAt>=diagnosticQRStart,sentAt-lastQRCheck>=1 {
                        lastQRCheck=sentAt
                        if saveSyntheticPattern,!savedPattern {
                            savedPattern=true
                            let folder=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("006IDC/DesktopWeChatScanner")
                            try? image.write(to:folder.appendingPathComponent("diagnostic-board-crop.jpg"),options:.atomic)
                        }
                        let barcode=VNDetectBarcodesRequest();barcode.symbologies=[.qr]
                        try? VNImageRequestHandler(data:image).perform([barcode])
                        stats.syntheticQRVisible=barcode.results?.contains{$0.payloadStringValue==ScanPerformanceCheck.payload} ?? false
                    }
                    pump.update(stats)
                    if stats.localQRSubmitted {
                        // Wait for the main actor to accept this exact selection.
                        // Movement/retry during or after ACK invalidates it, even
                        // if the frame returns to the same screen coordinates.
                        while !Task.isCancelled,pump.isCurrent(selection) {
                            try await Task.sleep(nanoseconds:20_000_000)
                        }
                        guard !Task.isCancelled,pump.latest() != nil else{break}
                        try await phone.discardFrame(epoch:generation)
                        stats.localQRSubmitted=false;stats.localSubmission=nil
                        stats.dropped+=1;pump.update(stats)
                        continue
                    }
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
                let rest=max(0,(localFrameMode ? 0.25:1.0/30)-(ProcessInfo.processInfo.systemUptime-began))
                if rest>0 {try? await Task.sleep(nanoseconds:UInt64(rest*1_000_000_000))}
            }
        }
    }
    private nonisolated static func textIn(_ pixels:CVPixelBuffer,region:ScannerNavigationOCR.Region = .full) throws -> [ScannerNavigationOCR.Text] {
        try ScannerNavigationOCR.recognize(pixels,region:region)
    }
    /// Bounded navigation only: recognise the WeChat home/menu labels. Never
    /// click a scan result, authorization button, link, payment or chat item.
    private func openScanner() async throws -> Bool {
        scanNavigation=[]
        let navigationStarted=ProcessInfo.processInfo.systemUptime
        defer {scannerNavigationMilliseconds=(ProcessInfo.processInfo.systemUptime-navigationStarted)*1000}
        if let foreground=try await phone.foreground(onVirtualDisplay:true),
           foreground.hasPrefix("com.tencent.mm/"),foreground.lowercased().contains("scanner") {return true}
        let deadline=ProcessInfo.processInfo.systemUptime+4
        var openedMenu=false,tappedScanner=false,menuAttempts=0
        var returnedFromOwnResult=false
        var lastMenuTap=0.0
        var recognisedFrame = -1
        while ProcessInfo.processInfo.systemUptime<deadline {
            try await Task.sleep(nanoseconds:120_000_000)
            guard let image=latestPhoneFrame else{continue}
            let retryDue=openedMenu && !tappedScanner && menuAttempts<3 && ProcessInfo.processInfo.systemUptime-lastMenuTap>0.7
            guard previewsReceived != recognisedFrame || retryDue else{continue}
            recognisedFrame=previewsReceived
            let ocrStarted=ProcessInfo.processInfo.systemUptime
            let region:ScannerNavigationOCR.Region=tappedScanner ? .scanner : (openedMenu && !retryDue ? .menu:.full)
            let words=try await Task.detached(priority:.userInitiated) {try Self.textIn(image,region:region)}.value
            try Task.checkCancellation()
            // Wait for a fresh rendered frame before dismissing our own prior
            // diagnostic result. A launch's first frame can still be blank.
            if !returnedFromOwnResult,CommandLine.arguments.contains("--run-scan-diagnostic"),
               words.contains(where:{$0.value.replacingOccurrences(of:" ",with:"").contains(ScanPerformanceCheck.payload)}) {
                returnedFromOwnResult=true;mirror.key(4)
                try await Task.sleep(nanoseconds:350_000_000);continue
            }
            // Persist only the fixed navigation-label allowlist, never chat text.
            let labels:Set<String>=["微信","通讯录","发现","我","扫一扫","发起群聊","添加朋友"]
            let allowed=words.filter{labels.contains($0.value.replacingOccurrences(of:" ",with:""))}
            if scanNavigation.count<32 {scanNavigation.append(["ocrMilliseconds":(ProcessInfo.processInfo.systemUptime-ocrStarted)*1000,
                "labels":allowed.map{["label":$0.value.replacingOccurrences(of:" ",with:""),"x":Int($0.rect.midX),"y":Int($0.rect.midY)]},
                "region":region.rawValue,"menuTapped":openedMenu,"menuAttempts":menuAttempts,"scannerTapped":tappedScanner,"frame":previewsReceived])}
            let scan=words.first{$0.value.replacingOccurrences(of:" ",with:"").contains("扫一扫")}
            if let scan,scan.rect.midY>950 {return true}
            if !tappedScanner,let scan,scan.rect.midY<950 && words.contains(where:{$0.value.contains("发起群聊") || $0.value.contains("添加朋友")}) {
                guard try await phone.foreground(onVirtualDisplay:true)=="com.tencent.mm/.ui.LauncherUI" else{return false}
                try Task.checkCancellation()
                guard connected,!stopping else{return false}
                mirror.tap(x:Double(scan.rect.midX/720),y:Double(scan.rect.midY/1280))
                tappedScanner=true;continue
            }
            let home=words.contains{$0.value.contains("通讯录") && $0.rect.midY>1000} && words.contains{$0.value.contains("发现") && $0.rect.midY>1000}
            if home,!savedDiagnosticToolbar,CommandLine.arguments.contains("--diagnostic-toolbar"),CommandLine.arguments.contains("--run-scan-diagnostic") {
                // Explicit local developer artifact: only the top 11% toolbar,
                // never the chat list, desktop or a scan-result page.
                savedDiagnosticToolbar=true
                let source=CIImage(cvPixelBuffer:image)
                let crop=CGRect(x:0,y:source.extent.height*0.89,width:source.extent.width,height:source.extent.height*0.11)
                if let toolbar=CIContext().createCGImage(source,from:crop),let data=NSBitmapImageRep(cgImage:toolbar).representation(using:.png,properties:[:]) {
                    let folder=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("006IDC/DesktopWeChatScanner")
                    try data.write(to:folder.appendingPathComponent("diagnostic-toolbar.png"),options:.atomic)
                }
            }
            // MIUI can show a repeated title without repeating its controls.
            // Confirm the actual plus on the same frame as the home evidence.
            if (!openedMenu || retryDue),!tappedScanner,home {
                let currentImage=image
                guard let plus=try await Task.detached(priority:.userInitiated,operation:{
                    try ScannerNavigationOCR.plusButton(in:currentImage,homeWords:words)
                }).value else{continue}
                guard try await phone.foreground(onVirtualDisplay:true)=="com.tencent.mm/.ui.LauncherUI" else{return false}
                try Task.checkCancellation()
                guard connected,!stopping else{return false}
                if menuAttempts==2 {
                    try await phone.tap(x:Int(plus.x),y:Int(plus.y))
                } else {mirror.tap(x:Double(plus.x/720),y:Double(plus.y/1280))}
                openedMenu=true;menuAttempts+=1;lastMenuTap=ProcessInfo.processInfo.systemUptime
            }
            // A launch transition may discard the first input. Retry only the
            // same plus button after re-confirming the home screen and waiting
            // 700ms; never navigate an unrecognised page or any scan result.
        }
        return false
    }
    private func togglePause(){
        if localScanFrame != nil {toggleLocalScanPause();return}
        guard connected,!busy,cameraActive,let window=cameraWindow,let display=cameraDisplay else{return}
        if !paused {
            nativeScannerOverlay?.noteEnd(.pausedByControl)
            let checking=performanceTask;checking?.cancel()
            cameraSuppressed=true;busy=true;refresh()
            operationTask=Task {
                await checking?.value
                await clearCamera()
                guard connected,!stopping,!Task.isCancelled else{return}
                cameraWindow=window;cameraDisplay=display;cameraActive=true;paused=true;busy=false
                status("桌面相机已暂停","手机画面仍可操作，点继续恢复桌面画面。")
            }
        } else {cameraSuppressed=false;startCamera(in:window,display:display)}
    }
    private func back(){
        guard connected && !busy else{return}
        let checking=performanceTask;checking?.cancel()
        busy=true;cameraSuppressed=true
        refresh()
        operationTask=Task {
            await checking?.value
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
    private func disconnectWireless() async -> String {
        var problem=""
        if let endpoint=wirelessEndpoint,let adbURL {
            do {try await ADBConnectionManager(adbURL:adbURL,serverSocket:adbServerSocket).disconnect(endpoint:endpoint)}
            catch {problem="应用会话已关闭，但无线调试连接未断开。可在手机关闭无线调试。"}
        }
        if let server=wirelessServer {
            await server.stop();wirelessServer=nil;problem=""
        }
        wirelessEndpoint=nil;adbServerSocket=nil
        return problem
    }
    private func disconnect(preserveError:Bool=false){
        guard !stopping else{return}
        dismissLocalScanFrame(restoring:true);localCameraMode=false
        nativeScannerOverlay?.freeze();cameraWindow?.freezeNativeScanner()
        endCameraActivity()
        launchDiagnosticGeneration+=1
        let launchCheck=launchDiagnosticTask;launchCheck?.cancel();launchDiagnosticTask=nil
        let checking=performanceTask;checking?.cancel()
        stopping=true;busy=true;paused=true;cameraActive=false;scanGeneration+=1;mirrorGeneration+=1;physicalMirror.frames.stop();scannerMirror.frames.stop()
        let chooser=connectionWindow;chooser?.close();connectionWindow=nil
        let previousCamera=cameraLoop;cameraLoop=nil
        connectionTask?.cancel();catalogTask?.cancel();operationTask?.cancel();loop?.cancel();cameraPump?.stop();cameraPump=nil;previousCamera?.cancel()
        refresh()
        if !preserveError {status("正在断开","正在结束手机镜像并清理临时连接…")}
        Task {
            await launchCheck?.value
            await checking?.value
            await stopNativeScannerOverlay()
            let chooserClean=await chooser?.waitForCleanup() ?? true
            await capture.stop();await previousCamera?.value
            await detachedApplications?.stop();detachedApplications=nil;await stopMirrors()
            var problem=await phoneSession?.disconnect() ?? ""
            let networkProblem=await disconnectWireless()
            if !networkProblem.isEmpty {problem += " " + networkProblem}
            if !chooserClean {problem += " 部分未选中的无线连接未清理，请在手机关闭无线调试。"}
            wechatWindow?.window?.orderOut(nil);wechatWindow=nil;applicationLibrary?.close();applicationLibrary=nil
            cameraWindow?.setCameraActive(false);cameraWindow=nil;cameraDisplay=nil;desktopMode=false;mainControl.setPhoneDesktopMode(false)
            applicationPickerVisible=false;cachedApplications=nil;mainControl.hideApplicationPicker()
            connected=false;busy=false;stopping=false;independentApplicationsWhenLocked=false;primaryLocked=false;mirrorDisplay=nil;latestPhoneFrame=nil;control.setPhoneImage(nil)
            if !problem.isEmpty {status("需要重新连接以清理",problem)}
            else if !preserveError {status("已断开","可以拔线，下次直接连接即可。")}
            else {refresh();writeDiagnosticState()}
        }
    }
    func windowShouldClose(_ sender:NSWindow)->Bool {
        if sender === wechatWindow?.window {returnToPhone();return false}
        sender.orderOut(nil);return false
    }
    func applicationDidBecomeActive(_ notification:Notification) {
        refreshScreenAccess()
    }
    private func refreshScreenAccess() {
        // A TCC query is synchronous IPC. Keep it out of the presentation tick,
        // and never request permission just because this window became active.
        guard permissionCheck == nil else{return}
        permissionCheck=Task { [weak self] in
            let granted=await Task.detached(priority:.utility) {CGPreflightScreenCaptureAccess()}.value
            guard let self else{return}
            self.screenAccessGranted=granted || self.cameraActive
            if granted {self.mainControl.showPermissionHelp(false);self.wechatWindow?.showPermissionHelp(false)}
            self.permissionCheck=nil;self.refresh();self.writeDiagnosticState()
        }
    }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows:Bool)->Bool {showMainWindow();return true}
    func applicationWillTerminate(_ notification:Notification) {
        if diagnosticExitStatus != 0 {exit(diagnosticExitStatus)}
    }
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {
        if terminationReady {return .terminateNow}
        guard !terminating else{return .terminateCancel}
        dismissLocalScanFrame(restoring:false);localCameraMode=false
        endCameraActivity()
        terminating=true
        nativeScannerOverlay?.freeze();cameraWindow?.freezeNativeScanner()
        launchDiagnosticGeneration+=1
        let launchCheck=launchDiagnosticTask;launchCheck?.cancel();launchDiagnosticTask=nil
        let checking=performanceTask;checking?.cancel()
        stopping=true;let chooser=connectionWindow;chooser?.close();connectionWindow=nil
        let previousCamera=cameraLoop;cameraLoop=nil
        connectionTask?.cancel();catalogTask?.cancel();operationTask?.cancel();loop?.cancel();cameraPump?.stop();cameraPump=nil;previousCamera?.cancel()
        paused=true;cameraActive=false;scanGeneration+=1;mirrorGeneration+=1;busy=true
        physicalMirror.frames.stop();scannerMirror.frames.stop();previewTimer?.invalidate();previewTimer=nil
        status("正在退出","正在停止镜像并清理手机临时连接…")
        Task {
            await launchCheck?.value
            await checking?.value
            await stopNativeScannerOverlay()
            let chooserClean=await chooser?.waitForCleanup() ?? true
            await capture.stop();await previousCamera?.value
            await detachedApplications?.stop();detachedApplications=nil;await stopMirrors()
            var problem=await phoneSession?.disconnect() ?? ""
            let networkProblem=await disconnectWireless()
            if !networkProblem.isEmpty {problem += " " + networkProblem}
            if !chooserClean {problem += " 部分未选中的无线连接未清理，请在手机关闭无线调试。"}
            if !problem.isEmpty {
                let diagnostic=CommandLine.arguments.contains("--run-desktop-diagnostic") || CommandLine.arguments.contains("--run-scan-diagnostic")
                if diagnostic {diagnosticExitStatus=1}
                else {
                    let alert=NSAlert();alert.messageText="连接已停止，手机清理待恢复";alert.informativeText=problem
                    alert.addButton(withTitle:"退出，下次连接时清理");alert.runModal()
                }
            }
            if CommandLine.arguments.contains("--run-desktop-diagnostic") {
                let file=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
                    .appendingPathComponent("006IDC/DesktopWeChatScanner/desktop-performance-last.json")
                if let data=try? Data(contentsOf:file),var report=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] {
                    report["cleanupSucceeded"]=problem.isEmpty
                    report["cleanupStage"]=await phoneSession?.cleanupStage
                    report["cleanupCameraStreamsBeforeSleep"]=await phoneSession?.cleanupCameraStreamsBeforeSleep
                    report["cleanupCameraClosureConfirmed"]=await phoneSession?.cleanupCameraClosureConfirmed
                    report["cleanupScannerBeforeSleep"]=await phoneSession?.cleanupScannerBeforeSleep
                    if report["test"] as? String == "desktop-native-active-scanner-exit" {
                        let beforeSleepScanner=await phoneSession?.cleanupScannerBeforeSleep
                        let beforeSleepStreams=await phoneSession?.cleanupCameraStreamsBeforeSleep
                        let closureConfirmed=await phoneSession?.cleanupCameraClosureConfirmed
                        let verified=problem.isEmpty && beforeSleepScanner==true && (beforeSleepStreams ?? 0)>0 && closureConfirmed==true
                        report["activeScannerExitVerified"]=verified
                        if !verified {report["passed"]=false;diagnosticExitStatus=1}
                    }
                    if !problem.isEmpty {report["passed"]=false}
                    let writer=DiagnosticStateWriter(fileURL:file);writer.submit(report);await writer.flush()
                }
            }
            connected=false;busy=false
            status(problem.isEmpty ? "已退出":"已退出，清理待恢复",problem)
            await diagnosticWriter.flush()
            if relaunchAfterExit {scheduleRelaunch()}
            terminationReady=true
            NSApp.terminate(nil)
        }
        // Returning cancel lets the normal event loop service MainActor cleanup.
        // A later terminate returns immediately once resources are released.
        return .terminateCancel
    }
}
