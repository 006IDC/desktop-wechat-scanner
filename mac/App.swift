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
        control.onApplications={ [weak self] in self?.showApplications() }
        control.onPermissionSettings={ [weak self] in self?.permissionSettings() }
        control.onRelaunch={ [weak self] in self?.relaunch() }
        control.onTouch={ [weak self] action,x,y in
            guard let self,self.connected,!self.stopping,!self.primaryLocked else{return}
            self.lastUserInput=Date();self.physicalMirror.session.touch(action:action,x:x,y:y)
        }
        control.onTap={ [weak self] x,y in
            guard let self,self.connected,!self.stopping,!self.primaryLocked else{return}
            self.lastUserInput=Date();self.physicalMirror.session.tap(x:x,y:y)
        }
        control.onSwipe={ [weak self] x1,y1,x2,y2 in
            guard let self,self.connected,!self.busy,!self.primaryLocked else{return}
            self.lastUserInput=Date();self.physicalMirror.session.swipe(x1:x1,y1:y1,x2:x2,y2:y2)
        }
        control.showWindow(nil);refresh();writeDiagnosticState()
        NSApp.activate(ignoringOtherApps:true)
        refreshScreenAccess()
        if CommandLine.arguments.contains("--run-scan-diagnostic") {
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
            guard let remembered=WirelessReconnectStore().load() else{throw ScanError("没有已选择的无线手机，诊断不自动配对新设备。")}
            guard let resources=Bundle.main.resourceURL else{throw ScanError("随包资源不可用。")}
            let adb=try await ADBConfiguration.validateAsync(resources.appendingPathComponent("adb/bin/adb"))
            try check()
            let owned=try await ADBManagedServer.start(adbURL:adb)
            do {try check()} catch {await owned.stop();throw error}
            wirelessServer=owned;adbServerSocket=owned.socket;wirelessEndpoint=remembered.endpoint;adbURL=adb
            let manager=ADBConnectionManager(adbURL:adb,serverSocket:owned.socket)
            try await manager.connect(endpoint:remembered.endpoint);try check()
            let devices=try await manager.devices();try check()
            guard let device=devices.first(where:{$0.authorization == .authorized && $0.serial==remembered.endpoint}) else{throw ScanError("此前配对的手机当前不可连接。")}
            connectDevice(device,adb:adb,allowLockedApplications:UserDefaults.standard.bool(forKey:"allowsLockedApplications.v1"),diagnostic:true)
            await connectionTask?.value;try check()
            guard connected,!busy,!stopping else{throw ScanError("手机诊断连接未就绪。")}
            runPerformanceCheck()
            await performanceTask?.value;try check()
        } catch is CancellationError {return} catch {
            let folder=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("006IDC/DesktopWeChatScanner")
            let report:[String:Any]=["qrRecognized":false,"failure":error.localizedDescription,"updatedAt":ISO8601DateFormatter().string(from:Date())]
            if let data=try? JSONSerialization.data(withJSONObject:report,options:.sortedKeys){try? data.write(to:folder.appendingPathComponent("performance-last.json"),options:.atomic)}
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
        for (title,key,action) in [("手机主屏幕","1",#selector(homeAction)),("打开微信","2",#selector(wechatAction)),("桌面扫码 / 再扫","r",#selector(scanAction)),("暂停 / 继续桌面相机","p",#selector(pauseAction))] {
            actions.addItem(withTitle:title,action:action,keyEquivalent:key).target=self
        }
        actions.addItem(.separator())
        actions.addItem(withTitle:"关闭窗口",action:#selector(NSWindow.performClose(_:)),keyEquivalent:"w")
        actions.addItem(withTitle:"手机应用…",action:#selector(applicationsAction),keyEquivalent:"l").target=self
        actions.addItem(withTitle:"运行扫码流畅度检查",action:#selector(runPerformanceCheck),keyEquivalent:"").target=self
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
        control.setCameraActive(cameraActive && !paused)
        // Composite only the camera aperture locally. Real WeChat controls and
        // result frames remain in the decoded video, with the same input mapping.
        control.setLocalScanPreview(cameraActive && !paused && !busy && mode == .wechat)
        if wechatWindow != nil {
            mainControl.update(status:primaryLocked ? "手机主屏已锁定" : (connected ? "手机镜像 · \(model)" : currentStatus),detail:primaryLocked ? "独立应用仍可使用；正常解锁手机后恢复主屏镜像。" : "通过应用列表拖出应用，分别在 Mac 窗口里使用。",connected:connected,busy:stopping,paused:true)
        }
        control.setMode(cameraActive ? "桌面相机" : (mode == .phone ? "手机镜像" : "微信"))
    }
    private func writeDiagnosticState(){
        let folder=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("006IDC/DesktopWeChatScanner")
        try? FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let ticks=cameraTickGaps.sorted()
        let tickP95=ticks.isEmpty ? 0:ticks[min(ticks.count-1,Int(Double(ticks.count)*0.95))]
        var value:[String:Any]=["status":currentStatus,"connected":connected,"paused":paused,"framesSent":framesSent,"previewsReceived":previewsReceived,"screenPermission":screenAccessGranted,"mode":mode == .phone ? "phone" : "wechat","cameraActive":cameraActive,"localCameraPreview":cameraActive && !paused && !busy && mode == .wechat,"independentApplicationsWhenLocked":independentApplicationsWhenLocked,"primaryLocked":primaryLocked,"cameraFPS":cameraFPS,"captureMilliseconds":captureMilliseconds,"transferMilliseconds":transferMilliseconds,"previewWaitMilliseconds":previewWaitMilliseconds,"droppedCameraFrames":droppedCameraFrames,"maximumCameraGapMilliseconds":maximumCameraGapMilliseconds,"scannerSwitchMilliseconds":scannerSwitchMilliseconds,"cameraTickP95Milliseconds":tickP95,"maximumCameraTickMilliseconds":maximumCameraTickMilliseconds,"updatedAt":ISO8601DateFormatter().string(from:Date())]
        let mirrorStats=scannerMirror.session.timingSnapshot
        value["mirrorRelativeBacklogP95Milliseconds"]=mirrorStats.relativeBacklogP95Milliseconds
        value["mirrorRelativeBacklogMaxMilliseconds"]=mirrorStats.relativeBacklogMaxMilliseconds
        value["mirrorDecodeP95Milliseconds"]=mirrorStats.decodeP95Milliseconds
        value["mirrorVideoPacketCount"]=mirrorStats.videoPacketCount
        value["mirrorDecodedFrameCount"]=mirrorStats.decodedFrameCount
        if let data=try? JSONSerialization.data(withJSONObject:value,options:.sortedKeys){try? data.write(to:folder.appendingPathComponent("diagnostic-state.json"),options:.atomic)}
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
                model=try await phone.connect(openWechatOnConnect:false,selectedSerial:device.serial,allowLockedApplications:allowLockedApplications){ [weak self] value in Task { @MainActor in self?.status("正在连接",value) } }
                try Task.checkCancellation();connected=true;mode = .phone;mirrorGeneration+=1
                independentApplicationsWhenLocked=await phone.independentApplicationsWhenLocked
                primaryLocked=independentApplicationsWhenLocked ? !(try await phone.primaryUserUnlocked()) : false
                if !primaryLocked {try await showMirror(display:0)}
                try Task.checkCancellation();busy=false
                status(primaryLocked ? "手机主屏已锁定" : "已连接 · \(model)",primaryLocked ? "可以直接打开微信或手机应用；主屏镜像将在手机正常解锁后恢复。" : "直接点击或滑动手机画面；点微信后可在这里使用桌面扫码。")
                detachedApplications=DetachedApplications(phone:phone,adb:selected,server:Bundle.main.resourceURL!.appendingPathComponent("scrcpy-server"),serverSocket:adbServerSocket)
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
        performanceCheck?.tick(at:ProcessInfo.processInfo.systemUptime)
        updateCameraTick();detachedApplications?.present()
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
    private func clearCamera() async {
        paused=true;cameraActive=false;scanGeneration+=1;cameraPump?.stop();cameraPump=nil;cameraLoop?.cancel();cameraFPS=0;refresh()
        await capture.stop()
        try? await phone.clear(epoch:scanGeneration)
    }
    private func showApplications(){
        guard connected,!stopping else{return}
        if let library=applicationLibrary {library.showWindow(nil);library.window?.makeKeyAndOrderFront(nil);return}
        let library=ApplicationLibrary();applicationLibrary=library
        library.onOpen={ [weak self,weak library] app,point in
            guard let self,self.connected,!self.stopping else {
                library?.showError("手机尚未连接或正在断开，请连接后再打开应用。");return
            }
            if app.packageName=="com.tencent.mm" {
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
            // Finish the real gesture before restoring the full phone view.
            // Menus/gallery can remain in ScannerUI, so activity polling alone
            // cannot know that the transparent aperture would hide them.
            if action==1,self.cameraActive,ScanPreviewAperture.isControl(at:CGPoint(x:x,y:y)) {
                self.togglePause()
            }
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
        if !primaryLocked {physicalMirror.session.key(3)}
        showMainWindow()
    }
    private func startCamera(){
        guard connected && !busy && !stopping && !cameraSuppressed else{return}
        guard control.window?.isVisible == true,control.window?.isMiniaturized == false else{return}
        busy=true;operationTask?.cancel()
        operationTask=Task {
            do {
                await clearCamera();let generation=scanGeneration
                status("准备桌面相机","正在读取当前窗口后方的桌面画面…")
                try await capture.prepare();try Task.checkCancellation()
                screenAccessGranted=true
                control.showPermissionHelp(false)
                guard connected && mode == .wechat && generation==scanGeneration else{return}
                guard control.window?.isVisible == true,control.window?.isMiniaturized == false else {
                    await capture.stop();busy=false;cameraSuppressed=true;status("桌面相机已暂停","恢复窗口后点扫码继续。");return
                }
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
                    nextActivity=Date().addingTimeInterval(mode == .wechat ? 0.25:0.7)
                }
                if Date()>=nextHeartbeat && !Task.isCancelled {
                    do {try await phone.heartbeat();failures=0} catch {failures+=1}
                    // A physical mirror failure does not invalidate the authenticated
                    // virtual-device heartbeat or close independent windows.
                    if !busy {try? await updatePrimaryLock()}
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
    func windowWillMiniaturize(_ notification:Notification) {
        if notification.object as? NSWindow === wechatWindow?.window {suspendHiddenCamera()}
    }
    private func suspendHiddenCamera(){
        guard connected,!stopping,!busy,cameraActive else{return}
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
        guard control.window?.isVisible == true,control.window?.isMiniaturized == false else {
            suspendHiddenCamera();return
        }
        let tick=ProcessInfo.processInfo.systemUptime
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
                let rect=control.desktopCaptureRect
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
        if let error=snapshot.failure {
            let checking=performanceTask;checking?.cancel()
            pump.stop();cameraPump=nil;cameraSuppressed=true;cameraLoop?.cancel()
            cameraActive=false;paused=true;busy=true;refresh()
            operationTask=Task {
                await checking?.value
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
        cameraTickAt=nil;cameraTickGaps.removeAll(keepingCapacity:true);maximumCameraTickMilliseconds=0
        let pump=CameraPumpMailbox(),generation=scanGeneration
        let diagnosticQRStart=performanceCheck == nil ? Double.infinity:ProcessInfo.processInfo.systemUptime+6.2
        let saveSyntheticPattern=performanceCheck != nil && CommandLine.arguments.contains("--diagnostic-pattern")
        cameraPump=pump;cameraFramesBase=framesSent
        updateCameraTick()
        cameraLoop=Task.detached(priority:.userInitiated) { [capture,phone] in
            var stats=CameraPumpMailbox.Statistics()
            var measuredAt=ProcessInfo.processInfo.systemUptime,measuredFrames=0
            var transientFailureSince:TimeInterval?,lastSentAt:TimeInterval?
            var lastQRCheck=0.0,savedPattern=false
            while !Task.isCancelled,let target=pump.latest() {
                let began=ProcessInfo.processInfo.systemUptime
                do {
                    let image=try await capture.capture(target,maximumDimension:1280)
                    stats.captureMilliseconds=(ProcessInfo.processInfo.systemUptime-began)*1000
                    try Task.checkCancellation()
                    guard pump.latest() != nil else{break}
                    let sending=ProcessInfo.processInfo.systemUptime
                    // Freshness is checked again when the phone actor actually owns
                    // the socket, after any queued control command has completed.
                    let receipt=try await phone.frame(image,epoch:generation,selectedAt:target.selectedAt)
                    let sentAt=ProcessInfo.processInfo.systemUptime
                    stats.sent+=1
                    if let previous=lastSentAt {stats.maximumGapMilliseconds=max(stats.maximumGapMilliseconds,(sentAt-previous)*1000)}
                    lastSentAt=sentAt;transientFailureSince=nil
                    stats.transferMilliseconds=(sentAt-sending)*1000
                    stats.imageBytes=image.count
                    stats.phoneProcessingMilliseconds=receipt.processingMilliseconds
                    stats.requestMilliseconds=receipt.requestMilliseconds
                    stats.actorWaitMilliseconds=max(0,stats.transferMilliseconds-receipt.requestMilliseconds)
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
            // MIUI can render two identical WeChat toolbar rows. The top
            // visible row is the active navigation bar; the repeated lower
            // row did not respond to either the mirror or shell input path.
            if (!openedMenu || retryDue),!tappedScanner,home,let title=words.filter({
                $0.value.replacingOccurrences(of:" ",with:"")=="微信" &&
                $0.rect.midY<170 && (300...420).contains($0.rect.midX)
            }).min(by:{$0.rect.minY<$1.rect.minY}) {
                if menuAttempts==2 {
                    // A bounded compatibility fallback, only after the exact
                    // home screen survives two direct-channel attempts.
                    try await phone.tap(x:665,y:Int(title.rect.midY))
                } else {mirror.tap(x:665.0/720,y:Double(title.rect.midY/1280))}
                openedMenu=true;menuAttempts+=1;lastMenuTap=ProcessInfo.processInfo.systemUptime
            }
            // A launch transition may discard the first input. Retry only the
            // same plus button after re-confirming the home screen and waiting
            // 700ms; never navigate an unrecognised page or any scan result.
        }
        return false
    }
    private func togglePause(){
        guard connected && !busy else{return}
        guard mode == .wechat else{enterWechat(scan:true);return}
        if cameraActive {
            let checking=performanceTask;checking?.cancel()
            cameraSuppressed=true;busy=true;refresh()
            operationTask=Task {
                await checking?.value
                await clearCamera()
                guard connected && !stopping && !Task.isCancelled else{return}
                busy=false;status("桌面相机已暂停","镜像仍可操作，点桌面扫码可再次启动。")
            }
        } else {cameraSuppressed=false;startCamera()}
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
        launchDiagnosticGeneration+=1;launchDiagnosticTask?.cancel();launchDiagnosticTask=nil
        let checking=performanceTask;checking?.cancel()
        stopping=true;busy=true;paused=true;cameraActive=false;scanGeneration+=1;mirrorGeneration+=1;physicalMirror.frames.stop();scannerMirror.frames.stop()
        let chooser=connectionWindow;chooser?.close();connectionWindow=nil
        connectionTask?.cancel();catalogTask?.cancel();operationTask?.cancel();loop?.cancel();cameraPump?.stop();cameraPump=nil;cameraLoop?.cancel()
        refresh()
        if !preserveError {status("正在断开","正在结束手机镜像并清理临时连接…")}
        Task {
            await checking?.value
            let chooserClean=await chooser?.waitForCleanup() ?? true
            await capture.stop();await detachedApplications?.stop();detachedApplications=nil;await stopMirrors()
            var problem=await phoneSession?.disconnect() ?? ""
            let networkProblem=await disconnectWireless()
            if !networkProblem.isEmpty {problem += " " + networkProblem}
            if !chooserClean {problem += " 部分未选中的无线连接未清理，请在手机关闭无线调试。"}
            wechatWindow?.window?.orderOut(nil);wechatWindow=nil;applicationLibrary?.close();applicationLibrary=nil
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
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {
        if terminationReady {return .terminateNow}
        guard !terminating else{return .terminateCancel}
        terminating=true
        launchDiagnosticGeneration+=1;launchDiagnosticTask?.cancel();launchDiagnosticTask=nil
        let checking=performanceTask;checking?.cancel()
        stopping=true;let chooser=connectionWindow;chooser?.close();connectionWindow=nil
        connectionTask?.cancel();catalogTask?.cancel();operationTask?.cancel();loop?.cancel();cameraPump?.stop();cameraPump=nil;cameraLoop?.cancel()
        paused=true;cameraActive=false;scanGeneration+=1;mirrorGeneration+=1;busy=true
        physicalMirror.frames.stop();scannerMirror.frames.stop();previewTimer?.invalidate();previewTimer=nil
        status("正在退出","正在停止镜像并清理手机临时连接…")
        Task {
            await checking?.value
            let chooserClean=await chooser?.waitForCleanup() ?? true
            await capture.stop();await detachedApplications?.stop();detachedApplications=nil;await stopMirrors()
            var problem=await phoneSession?.disconnect() ?? ""
            let networkProblem=await disconnectWireless()
            if !networkProblem.isEmpty {problem += " " + networkProblem}
            if !chooserClean {problem += " 部分未选中的无线连接未清理，请在手机关闭无线调试。"}
            if !problem.isEmpty {
                let alert=NSAlert();alert.messageText="连接已停止，手机清理待恢复";alert.informativeText=problem
                alert.addButton(withTitle:"退出，下次连接时清理");alert.runModal()
            }
            if relaunchAfterExit {scheduleRelaunch()}
            terminationReady=true
            NSApp.terminate(nil)
        }
        // Returning cancel lets the normal event loop service MainActor cleanup.
        // A later terminate returns immediately once resources are released.
        return .terminateCancel
    }
}
