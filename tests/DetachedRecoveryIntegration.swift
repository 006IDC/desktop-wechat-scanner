import AppKit
import Darwin

/// Explicit USB test of the real manager/phone/mirror with its own windows never
/// ordered. Only the owned video stream is interrupted. No desktop capture,
/// synthetic user input, scanner navigation, saved image or arbitrary OCR.
@main enum DetachedRecoveryIntegration {
    enum Failure:Error {case prerequisites,firstWindow,firstFrame,sourceFence,retry,secondFrame,foreground,visibleWindow}
    @MainActor private final class Probe {
        var clears=0,clearAcknowledged=false,wrongDisplay=false
        var expectedDisplay:Int?
    }
    static func option(_ flag:String)->String? {
        guard let i=CommandLine.arguments.firstIndex(of:flag),CommandLine.arguments.indices.contains(i+1) else{return nil}
        return CommandLine.arguments[i+1]
    }
    @MainActor static func wait(_ manager:DetachedApplications,until condition:()->Bool) async throws {
        let deadline=ProcessInfo.processInfo.systemUptime+15
        while !condition() {
            try Task.checkCancellation();manager.present()
            guard ProcessInfo.processInfo.systemUptime<deadline else{throw Failure.retry}
            try await Task.sleep(nanoseconds:30_000_000)
        }
    }
    @MainActor static func receivedPhonePixels(_ view:NSView?)->Bool {
        guard let view else{return false}
        if view.layer?.sublayers?.contains(where:{$0.name=="phone.video" && !$0.isHidden})==true{return true}
        return view.subviews.contains{receivedPhonePixels($0)}
    }
    private static func privateReport(_ path:String)->FileHandle? {
        let project=URL(fileURLWithPath:FileManager.default.currentDirectoryPath,isDirectory:true).resolvingSymlinksInPath()
        let local=project.appendingPathComponent(".local",isDirectory:true)
        let root=local.appendingPathComponent("generic-camera-tests",isDirectory:true)
        let requested=URL(fileURLWithPath:path).standardizedFileURL
        guard FileManager.default.fileExists(atPath:project.appendingPathComponent("mac/DetachedApplications.swift").path),
              requested.deletingLastPathComponent()==root,
              requested.lastPathComponent.range(of:"^[A-Za-z0-9][A-Za-z0-9._-]{0,100}\\.json$",options:.regularExpression) != nil else{return nil}
        let projectFD=open(project.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW)
        guard projectFD>=0 else{return nil};defer{close(projectFD)}
        let localFD=openat(projectFD,".local",O_RDONLY|O_DIRECTORY|O_NOFOLLOW)
        guard localFD>=0 else{return nil};defer{close(localFD)}
        var localMetadata=stat()
        guard fstat(localFD,&localMetadata)==0,localMetadata.st_uid==getuid(),localMetadata.st_mode & 0o022==0 else{return nil}
        let directoryFD=openat(localFD,"generic-camera-tests",O_RDONLY|O_DIRECTORY|O_NOFOLLOW)
        guard directoryFD>=0 else{return nil};defer{close(directoryFD)}
        var metadata=stat()
        guard fstat(directoryFD,&metadata)==0,metadata.st_uid==getuid(),metadata.st_mode & 0o077==0 else{return nil}
        let fd=openat(directoryFD,requested.lastPathComponent,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,S_IRUSR|S_IWUSR)
        guard fd>=0 else{return nil}
        return FileHandle(fileDescriptor:fd,closeOnDealloc:true)
    }
    @MainActor static func main() async {
        guard CommandLine.arguments.contains("--run-device-test"),CommandLine.arguments.contains("--locked-applications"),
              let directory=option("--resources"),let reportPath=option("--report") else {
            print("Requires --run-device-test --locked-applications --resources <bundle Resources> --report <new private JSON>");exit(2)
        }
        guard let output=privateReport(reportPath) else{
            print("Run from the repo root; report must be a new JSON in owned mode-700 .local/generic-camera-tests");exit(2)
        }
        let support=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/006IDC/DesktopWeChatScanner")
        let journal=support.appendingPathComponent("session.json")
        guard !FileManager.default.fileExists(atPath:journal.path),NSRunningApplication.runningApplications(withBundleIdentifier:"com.idc006.DesktopWeChatScanner").isEmpty else{
            print("Existing app/session must finish first");exit(2)
        }
        _=NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
        let resources=URL(fileURLWithPath:directory),adb=resources.appendingPathComponent("adb/bin/adb")
        let phone=PhoneSession(resources:resources,adbURL:adb),probe=Probe()
        let manager=DetachedApplications(phone:phone,adb:adb,server:resources.appendingPathComponent("scrcpy-server"),presentation:{_,_ in})
        var report:[String:Any]=["test":"hidden-detached-mirror-recovery","liveDesktopCaptureTested":false,"inputInjected":false]
        var stage="prerequisites",passed=false
        var windows=[NSWindow]()
        var replacementAvailability:CameraWindowAvailability?
        do {
            let devices=try await ADBConnectionManager(adbURL:adb).devices().filter{$0.transport == .usb && $0.authorization == .authorized}
            guard devices.count==1 else{throw Failure.prerequisites}
            stage="connect"
            _=try await phone.connect(openWechatOnConnect:false,selectedSerial:devices[0].serial,allowLockedApplications:true,desktopHome:true,genericDesktopCamera:true){_ in}
            guard await phone.independentApplicationsWhenLocked else{throw Failure.prerequisites}
            let apps=try await phone.applications()
            guard let app=apps.first(where:{$0.packageName=="com.tencent.mm"}) else{throw Failure.prerequisites}
            manager.onCameraUnavailable={display in
                probe.clears+=1
                if probe.expectedDisplay != display {probe.wrongDisplay=true}
                return Task {
                    do {try await phone.clear(epoch:42,requireConnection:true);probe.clearAcknowledged=true;return true}
                    catch{return false}
                }
            }
            stage="first-window"
            guard manager.open(app,at:nil) else{throw Failure.firstWindow}
            try await wait(manager){manager.cameraWindows().count==1}
            let first=manager.cameraWindows()[0]
            guard let window=first.window.window,let oldAvailability=manager.cameraAvailability(display:first.display,window:first.window) else{throw Failure.firstWindow}
            windows.append(window)
            stage="first-frame"
            try await wait(manager){receivedPhonePixels(window.contentView)}
            guard !window.isVisible else{throw Failure.visibleWindow}
            report["firstPhoneFrameReceived"]=true;probe.expectedDisplay=first.display
            stage="interrupt-owned-stream"
            try await phone.stopDirectMirror(display:first.display)
            try await wait(manager){probe.clears>0 && !oldAvailability.isAvailable}
            report["oldAttemptInvalidated"] = !oldAvailability.isAvailable
            guard manager.cameraWindows().isEmpty else{throw Failure.sourceFence}
            stage="retry"
            guard manager.open(app,at:nil) else{throw Failure.retry}
            try await wait(manager){manager.cameraWindows().count==1}
            let second=manager.cameraWindows()[0]
            guard second.display != first.display,second.window === first.window,
                  probe.clearAcknowledged,!probe.wrongDisplay,
                  let availability=manager.cameraAvailability(display:second.display,window:second.window),availability.isAvailable else{throw Failure.retry}
            replacementAvailability=availability
            stage="second-frame"
            try await wait(manager){receivedPhonePixels(window.contentView)}
            let state=try await phone.cameraState()
            guard state.activities.first(where:{$0.displayId==second.display})?.package==app.packageName else{throw Failure.foreground}
            guard windows.allSatisfy({!$0.isVisible}) else{throw Failure.visibleWindow}
            report["sameMacWindowReused"]=true;report["replacementDisplayCreated"]=true
            report["cameraClearAcknowledged"]=true;report["secondPhoneFrameReceived"]=true
            report["selectedApplicationForeground"]=true;report["allWindowsUnordered"]=true
            passed=true
        }catch{
            report["failureStage"]=stage
            report["failureCode"]=(error as? Failure).map{String(describing:$0)} ?? "backend"
            report["cameraTargetsAtFailure"]=manager.cameraWindows().count
            report["replacementAvailable"]=replacementAvailability?.isAvailable ?? false
            report["phonePixelsAtFailure"]=windows.last.map{receivedPhonePixels($0.contentView)} ?? false
            report["windowsUnorderedAtFailure"]=windows.allSatisfy{!$0.isVisible}
        }
        report["clearCallbacks"]=probe.clears;report["clearAcknowledged"]=probe.clearAcknowledged;report["wrongDisplayCallback"]=probe.wrongDisplay
        await manager.stop()
        let cleanup=await phone.disconnect()
        report["cleanupSucceeded"]=cleanup.isEmpty
        report["sessionRecordAbsent"] = !FileManager.default.fileExists(atPath:journal.path)
        report["passed"]=passed && cleanup.isEmpty && !FileManager.default.fileExists(atPath:journal.path)
        if let data=try? JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted]){output.write(data)}
        try? output.close()
        for window in windows{window.orderOut(nil)}
        print("Hidden recovery result saved; no pixels or page text exported")
        exit(report["passed"] as? Bool == true ? 0:1)
    }
}
