import AppKit

/// One attempt owns its mirror callbacks, input and cleanup. The authenticated
/// virtual device outlives a window, but a failed mirror is never a camera target.
@MainActor
final class DetachedApplications: NSObject, NSWindowDelegate {
    enum DiagnosticStage:String {case creatingDisplay,connectingMirror,launchingApplication,waitingForFrame,ready,firstFramePresented,mirrorFailed,startupFailed,clearingCamera,cameraClearFailed,displayClosed,restoreFailed}
    enum DiagnosticFailure:String {case mirrorClosed,mirrorTimeout,mirrorOther,firstFrameTimeout,foregroundUnconfirmed,taskTreeInvalid,startupOther,uncertainCamera}
    private struct FirstFrameTimeout:LocalizedError {
        var errorDescription:String? {"应用已启动，但未收到当前手机画面；连接已停止，请从应用列表重新打开。"}
    }
    struct DiagnosticEvent {let attempt:Int;let stage:DiagnosticStage;let failure:DiagnosticFailure?;let validation:AndroidTaskSnapshot.ValidationError?}
    private enum Phase { case starting, ready, recovering, failed, closing, stopped }
    @MainActor private final class Entry {
        let app:AndroidApplication,ui:ControlWindowController
        let mirror=MirrorSession(),frames=MirrorVideoMailbox()
        var display:Int?,startup:Task<Void,Never>?,cleanup:Task<Bool,Never>?
        var phase=Phase.starting,epoch=0,retryRequested=false,requiresReconnect=false
        var availability:CameraWindowAvailability?
        var acceptedTouch:(x:Double,y:Double)?
        var failureDetail=""
        var firstFramePresented=false
        var acceptsInput:Bool {phase == .ready && display != nil && availability?.isAvailable==true}
        init(_ app:AndroidApplication) {self.app=app;ui=ControlWindowController(title:app.name,standalone:true)}
    }
    var onCameraCleanupFailure:((Error)->Void)?
    var onCameraReady:(()->Void)?
    /// Optional, fixed metadata only. Ordinary product construction has no observer.
    var onDiagnosticEvent:((DiagnosticEvent)->Void)?
    private func diagnostic(_ entry:Entry,_ stage:DiagnosticStage,_ failure:DiagnosticFailure?=nil,validation:AndroidTaskSnapshot.ValidationError?=nil) {
        onDiagnosticEvent?(DiagnosticEvent(attempt:entry.epoch,stage:stage,failure:failure,validation:validation))
    }
    /// Stops capture admission synchronously, then confirms asynchronous clear.
    /// The old display cannot be closed/reused until the returned task completes.
    var onCameraUnavailable:((Int)->Task<Bool,Never>)?
    private let phone:PhoneSession,adb:URL,server:URL
    private let serverSocket:String?
    private let frameTimeout:TimeInterval
    private let presentation:((ControlWindowController,NSPoint?)->Void)?
    private var entries=[String:Entry](),stopping=false
    init(phone:PhoneSession,adb:URL,server:URL,serverSocket:String?=nil,
         frameTimeout:TimeInterval=5,
         presentation:((ControlWindowController,NSPoint?)->Void)?=nil) {
        self.phone=phone;self.adb=adb;self.server=server;self.serverSocket=serverSocket;self.presentation=presentation
        self.frameTimeout=frameTimeout.isFinite ? max(0.01,min(10,frameTimeout)):5
    }
    private func show(_ entry:Entry,at point:NSPoint?) {
        // A backend integration test can suppress ordering its own windows.
        // Ordinary product construction keeps native presentation unchanged.
        if let presentation {presentation(entry.ui,point);return}
        if NSApp.activationPolicy() != .prohibited {NSApp.activate(ignoringOtherApps:true)}
        entry.ui.showWindow(nil)
        if let window=entry.ui.window {AppWindowMotion.reveal(window,from:point)}
    }
    func cameraWindows()->[(display:Int,window:ControlWindowController)] {
        entries.values.compactMap {entry in
            guard entry.acceptsInput,let display=entry.display else{return nil}
            return (display,entry.ui)
        }
    }
    func cameraAvailability(display:Int?,window:ControlWindowController)->CameraWindowAvailability? {
        entries.values.first{$0.display==display && $0.ui === window && $0.acceptsInput}?.availability
    }
    @discardableResult func open(_ app:AndroidApplication,at point:NSPoint?)->Bool {
        guard !stopping,app.isValid else{return false}
        if let entry=entries[app.packageName] {
            guard entry.phase != .closing,entry.phase != .stopped,!entry.requiresReconnect,
                  entry.ui.window != nil else{return false}
            show(entry,at:point)
            if entry.phase == .failed || entry.phase == .recovering {
                entry.retryRequested=true
                if entry.phase == .failed {
                    deactivate(entry,phase:.recovering)
                    entry.ui.update(status:"正在重试 \(app.name)",detail:"先确认旧窗口已清理，再重新打开。",connected:false,busy:true,paused:true)
                    recover(entry)
                }
            }
            return true
        }
        guard entries.count<4 else {
            let alert=NSAlert();alert.messageText="最多同时打开 4 个独立应用";alert.informativeText="请关闭一个应用窗口后再打开。";alert.runModal();return false
        }
        let entry=Entry(app);entries[app.packageName]=entry
        guard let window=entry.ui.window else{entries.removeValue(forKey:app.packageName);return false}
        window.isReleasedWhenClosed=false;window.delegate=self
        entry.ui.onTouch={ [weak entry] action,x,y in
            guard let entry else{return}
            // A release may end an already-forwarded gesture after the attempt
            // fence closes. It cannot begin or move a new gesture.
            if action==1 {
                guard entry.acceptedTouch != nil else{return}
                entry.acceptedTouch=nil;entry.mirror.touch(action:action,x:x,y:y);return
            }
            guard entry.acceptsInput,((action==0 && entry.acceptedTouch == nil) || (action==2 && entry.acceptedTouch != nil)) else{return}
            entry.acceptedTouch=(x,y);entry.mirror.touch(action:action,x:x,y:y)
        }
        entry.ui.onTap={ [weak entry] x,y in
            guard let entry,entry.acceptsInput else{return};entry.mirror.tap(x:x,y:y)
        }
        entry.ui.onSwipe={ [weak entry] x1,y1,x2,y2 in
            guard let entry,entry.acceptsInput else{return};entry.mirror.swipe(x1:x1,y1:y1,x2:x2,y2:y2)
        }
        entry.ui.onBack={ [weak entry] in
            guard let entry,entry.acceptsInput else{return};entry.mirror.key(4)
        }
        entry.ui.setPhoneInteractionEnabled(false)
        show(entry,at:point)
        start(entry)
        return true
    }
    private func start(_ entry:Entry) {
        guard !stopping,entry.display==nil,entry.cleanup==nil,!entry.requiresReconnect else{return}
        entry.epoch &+= 1
        let epoch=entry.epoch
        let availability=CameraWindowAvailability();entry.availability=availability;entry.acceptedTouch=nil
        entry.phase = .starting;entry.retryRequested=false;entry.failureDetail=""
        entry.firstFramePresented=false;diagnostic(entry,.creatingDisplay)
        entry.frames.reset(generation:epoch);entry.ui.setPhonePixelBuffer(nil);entry.ui.setPhoneInteractionEnabled(false)
        entry.ui.update(status:"正在打开 \(entry.app.name)",detail:"应用仍在手机运行，画面即将在这里出现。",connected:false,busy:true,paused:true)
        entry.startup=Task { [weak self,entry] in
            guard let self else{return}
            defer {if entry.epoch==epoch {entry.startup=nil}}
            do {
                let display=try await phone.createAppDisplay()
                // Record even a late result: the cleanup owner awaits this task.
                entry.display=display.id
                try Task.checkCancellation()
                diagnostic(entry,.connectingMirror)
                let endpoint=try await phone.mirrorEndpoint(display:display.id)
                let direct=try await phone.directMirror(display:display.id)
                try Task.checkCancellation()
                try await entry.mirror.startVideo(adbURL:adb,serverURL:server,serial:endpoint.serial,
                    displayID:display.id,serverSocket:serverSocket,direct:direct,
                    onFrame:{ [frames=entry.frames] pixels in
                        guard availability.isAvailable else{return};frames.publish(pixels,generation:epoch)
                    },
                    onFailure:{ [weak self,weak entry,frames=entry.frames] detail in
                        availability.invalidate();frames.stop(generation:epoch)
                        Task { @MainActor in
                            guard let self,let entry else{return}
                            guard entry.epoch==epoch else{return}
                            let reason:DiagnosticFailure=detail.contains("超时") ? .mirrorTimeout:(detail=="手机镜像连接中断。" ? .mirrorClosed:.mirrorOther)
                            self.diagnostic(entry,.mirrorFailed,reason)
                            self.fail(entry,epoch:epoch,detail:"画面连接中断，请从应用列表重新打开以重试。")
                        }
                    })
                try Task.checkCancellation()
                diagnostic(entry,.launchingApplication)
                let launchBegan=ProcessInfo.processInfo.systemUptime
                let cameraReady=try await phone.launchApplication(entry.app,on:display.id)
                try Task.checkCancellation()
                diagnostic(entry,.waitingForFrame)
                let frameDeadline=ProcessInfo.processInfo.systemUptime+frameTimeout
                while !entry.frames.receivedFrame(generation:epoch,since:launchBegan) {
                    try Task.checkCancellation()
                    guard !stopping,entry.epoch==epoch,entry.phase == .starting,availability.isAvailable else{return}
                    guard ProcessInfo.processInfo.systemUptime<frameDeadline else{throw FirstFrameTimeout()}
                    try await Task.sleep(nanoseconds:20_000_000)
                }
                guard !stopping,entry.epoch==epoch,entry.phase == .starting,availability.isAvailable else{return}
                entry.phase = .ready;entry.ui.setPhoneInteractionEnabled(true)
                diagnostic(entry,.ready)
                if cameraReady {onCameraReady?()}
                entry.ui.update(status:entry.app.name,detail:cameraReady ? "桌面相机已绑定；在此应用内打开相机即可取景。":"独立应用窗口 · 关闭后移回手机；黄色按钮使用系统程序坞动画。",connected:true,busy:false,paused:true)
            } catch {
                guard !stopping,entry.epoch==epoch,entry.phase == .starting else{return}
                let validation=error as? AndroidTaskSnapshot.ValidationError
                let reason:DiagnosticFailure=error is DesktopCameraLaunchFailure ? .uncertainCamera:(error is FirstFrameTimeout ? .firstFrameTimeout:(validation != nil ? .taskTreeInvalid:(error.localizedDescription=="应用未出现在指定屏幕；已保留恢复记录。" ? .foregroundUnconfirmed:.startupOther)))
                diagnostic(entry,.startupFailed,reason,validation:validation)
                fail(entry,epoch:epoch,detail:error.localizedDescription,uncertainCamera:error is DesktopCameraLaunchFailure)
            }
        }
    }
    private func deactivate(_ entry:Entry,phase:Phase) {
        // End an existing gesture while its old ready gate still accepts UP.
        // There is no suspension point allowing a new gesture between these steps.
        entry.ui.setPhoneInteractionEnabled(false)
        if let touch=entry.acceptedTouch {
            entry.acceptedTouch=nil;entry.mirror.touch(action:1,x:touch.x,y:touch.y)
        }
        entry.availability?.invalidate()
        entry.phase=phase;entry.frames.stop();entry.startup?.cancel()
    }
    private func fail(_ entry:Entry,epoch:Int,detail:String,uncertainCamera:Bool=false) {
        guard !stopping,entry.epoch==epoch,entry.phase == .starting || entry.phase == .ready else{return}
        entry.failureDetail=detail;entry.requiresReconnect=uncertainCamera
        deactivate(entry,phase:.recovering)
        entry.ui.update(status:"正在清理中断窗口",detail:detail,connected:false,busy:true,paused:true)
        recover(entry)
        if uncertainCamera {onCameraCleanupFailure?(ScanError(detail))}
    }
    private func recover(_ entry:Entry) {
        guard entry.cleanup==nil else{return}
        let startup=entry.startup,initialDisplay=entry.display
        diagnostic(entry,.clearingCamera)
        // Calling this hook must stop any active/startup camera before the first await.
        let initialCameraClear=initialDisplay.flatMap{onCameraUnavailable?($0)}
        entry.cleanup=Task { [self,entry] in
            await entry.mirror.stop();await startup?.value
            var cameraClear=await initialCameraClear?.value ?? true
            if let display=entry.display,display != initialDisplay {
                cameraClear=await onCameraUnavailable?(display).value ?? true
            }
            guard !stopping else{entry.cleanup=nil;return false}
            var clean=cameraClear && !entry.requiresReconnect
            if clean,let display=entry.display {
                do {try await phone.closeAppDisplay(display);entry.display=nil;diagnostic(entry,.displayClosed)}
                catch {clean=false;diagnostic(entry,.restoreFailed);entry.failureDetail="旧窗口尚未清理完成："+error.localizedDescription}
            }
            if !cameraClear {
                diagnostic(entry,.cameraClearFailed)
                let alreadyUncertain=entry.requiresReconnect
                entry.requiresReconnect=true
                entry.failureDetail="桌面相机清理未确认，请断开手机后重新连接。"
                if !alreadyUncertain {onCameraCleanupFailure?(ScanError(entry.failureDetail))}
            }
            entry.cleanup=nil
            guard !stopping,entries[entry.app.packageName] === entry else{return false}
            if entry.phase == .closing,clean {
                entry.phase = .stopped;entries.removeValue(forKey:entry.app.packageName);entry.ui.window?.orderOut(nil)
            } else if clean,entry.retryRequested,!entry.requiresReconnect {
                start(entry)
            } else {
                entry.phase = .failed;entry.retryRequested=false
                entry.ui.update(status:clean ? "应用打开失败":"旧窗口清理未完成",detail:entry.failureDetail,connected:false,busy:false,paused:true)
            }
            return clean
        }
    }
    func present() {
        for entry in entries.values where (entry.phase == .starting || entry.phase == .ready) && entry.availability?.isAvailable==true && entry.ui.window?.isMiniaturized != true {
            if let frame=entry.frames.takeLatest(),frame.generation==entry.epoch {
                entry.ui.setPhonePixelBuffer(frame.pixelBuffer)
                if !entry.firstFramePresented {entry.firstFramePresented=true;diagnostic(entry,.firstFramePresented)}
            }
        }
    }
    func windowShouldClose(_ sender:NSWindow)->Bool {
        guard let entry=entries.values.first(where:{$0.ui.window === sender}),entry.phase != .closing,entry.phase != .stopped else{return false}
        entry.retryRequested=false;deactivate(entry,phase:.closing)
        entry.ui.update(status:"正在返回手机",detail:"正在收起这个应用窗口…",connected:false,busy:true,paused:true)
        recover(entry)
        return false
    }
    func stop() async {
        stopping=true
        let current=Array(entries.values)
        for entry in current {entry.retryRequested=false;deactivate(entry,phase:.stopped)}
        for entry in current {
            _=await entry.cleanup?.value
            await entry.mirror.stop();await entry.startup?.value
            // PhoneSession.disconnect restores all owned displays together.
            entry.ui.window?.orderOut(nil)
        }
        entries.removeAll()
    }
}
