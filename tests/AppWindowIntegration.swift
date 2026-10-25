import Foundation
import CoreVideo

private final class MirrorObservation: @unchecked Sendable {
    private let lock=NSLock()
    private var frames=0, failure:String?
    private var visualSignature:UInt64?
    let route:String
    init(_ route:String) {self.route=route}
    func add(){lock.withLock{frames+=1}}
    /// Sample the middle of the Settings list in memory; never retain/export pixels.
    func observeSettings(_ pixels:CVPixelBuffer){
        CVPixelBufferLockBaseAddress(pixels,.readOnly)
        defer {CVPixelBufferUnlockBaseAddress(pixels,.readOnly)}
        let planar=CVPixelBufferIsPlanar(pixels)
        guard let base=planar ? CVPixelBufferGetBaseAddressOfPlane(pixels,0) : CVPixelBufferGetBaseAddress(pixels) else {add();return}
        let width=planar ? CVPixelBufferGetWidthOfPlane(pixels,0) : CVPixelBufferGetWidth(pixels)
        let height=planar ? CVPixelBufferGetHeightOfPlane(pixels,0) : CVPixelBufferGetHeight(pixels)
        let stride=planar ? CVPixelBufferGetBytesPerRowOfPlane(pixels,0) : CVPixelBufferGetBytesPerRow(pixels)
        let bytes=base.assumingMemoryBound(to:UInt8.self),pixelStride=planar ? 1:4
        var signature:UInt64=14695981039346656037
        for y in Swift.stride(from:height/4,to:height*3/4,by:max(1,height/100)) {
            for x in Swift.stride(from:width/5,to:width*4/5,by:max(1,width/100)) {
                signature=(signature ^ UInt64(bytes[y*stride+x*pixelStride])) &* 1099511628211
            }
        }
        lock.withLock{frames+=1;visualSignature=signature}
    }
    var signature:UInt64? {lock.withLock{visualSignature}}
    func failed(_ message:String){
        let category=AppWindowIntegration.failureCategory(message)
        lock.withLock{failure=category}
        AppWindowIntegration.emit("EVENT mirror_failure route=\(route) category=\(category)")
    }
    var count:Int {lock.withLock{frames}}
    func requireHealthy() throws {
        if let category=lock.withLock({failure}) {throw ScanError("mirror_\(route)_\(category)")}
    }
}

/// Explicit device test. Does not export images, identifiers or application catalog.
@main struct AppWindowIntegration {
    private static let outputLock=NSLock()
    static func emit(_ value:String){outputLock.withLock{print(value);fflush(stdout)}}
    /// Report useful failure classes without ADB endpoints, paths, identifiers or raw output.
    static func failureCategory(_ message:String)->String {
        let lower=message.lowercased()
        if lower.contains("h.264") || lower.contains("解码") {return "codec"}
        if lower.contains("超时") || lower.contains("timeout") {return "timeout"}
        if lower.contains("未启动") || lower.contains("尚未就绪") {return "startup"}
        if lower.contains("中断") || lower.contains("断开") {return "transport"}
        if lower.contains("锁屏") || lower.contains("解锁") {return "locked_or_unconfirmed"}
        if lower.contains("恢复") || lower.contains("清理") {return "recovery"}
        return "operation"
    }
    private static func requirePrimaryLocked(_ phone:PhoneSession,checkpoint:String) async throws {
        guard try await !phone.primaryUserUnlocked() else {throw ScanError("手机主屏必须保持锁屏；本次锁屏应用测试未通过。")}
        emit("PASS primary_display_locked checkpoint=\(checkpoint)")
    }
    private static func cleanup(mirrors:[MirrorSession],phone:PhoneSession?,manager:ADBConnectionManager?,endpoint:String?,server:ADBManagedServer?,locked:Bool=false) async -> Bool {
        emit("STAGE cleanup_mirrors")
        for mirror in mirrors {await mirror.stop()}
        var lockOK=true
        if locked,let phone {
            do {try await requirePrimaryLocked(phone,checkpoint:"before_session_cleanup")}
            catch {lockOK=false;emit("EVENT primary_lock_unconfirmed checkpoint=before_session_cleanup")}
        }
        emit("STAGE cleanup_phone")
        let phoneOK=await phone?.disconnect() ?? ""
        var wirelessOK=true
        if let endpoint,let manager {
            do {try await manager.disconnect(endpoint:endpoint)}
            catch {wirelessOK=false;emit("EVENT wireless_cleanup_failure category=\(failureCategory(error.localizedDescription))")}
        }
        emit("STAGE cleanup_owned_server")
        await server?.stop()
        emit("CLEANUP phone_ok=\(phoneOK.isEmpty) wireless_ok=\(wirelessOK)")
        return phoneOK.isEmpty && wirelessOK && lockOK
    }
    private static func awaitFrames(_ observations:[(MirrorObservation,Int)],timeout:TimeInterval=10) async throws {
        let deadline=ProcessInfo.processInfo.systemUptime+timeout
        while ProcessInfo.processInfo.systemUptime<deadline {
            for (observation,_) in observations {try observation.requireHealthy()}
            if observations.allSatisfy({$0.0.count>$0.1}) {return}
            try await Task.sleep(nanoseconds:25_000_000)
        }
        throw ScanError("镜像首帧超时。")
    }
    static func main() async {
        guard CommandLine.arguments.contains("--run-device-test") else {emit("Explicit --run-device-test required");return}
        let concurrent=CommandLine.arguments.contains("--concurrent-mirrors")
        let locked=CommandLine.arguments.contains("--locked-applications")
        let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        let adb=root.appendingPathComponent(".local/adb-bundle/bin/adb")
        let serverJar=root.appendingPathComponent(".tools/scrcpy/scrcpy-server-v5.0.1")
        var cleanupSession:PhoneSession?,server:ADBManagedServer?,wirelessManager:ADBConnectionManager?,wirelessEndpoint:String?
        let mirror=MirrorSession(),physicalMirror=MirrorSession(),settingsMirror=MirrorSession()
        let reserved=MirrorObservation("reserved"),physical=MirrorObservation("physical"),settingsFrames=MirrorObservation("settings")
        var phase="arguments"
        func stage(_ value:String){phase=value;emit("STAGE \(value)")}
        do {
            guard !(locked && concurrent) else {throw ScanError("--locked-applications cannot be combined with --concurrent-mirrors")}
            emit("MODE concurrent_mirrors=\(concurrent) locked_applications=\(locked)")
            let requestedEndpoint:String?
            if let index=CommandLine.arguments.firstIndex(of:"--wireless-endpoint") {
                guard CommandLine.arguments.indices.contains(index+1) else {throw ScanError("Missing wireless endpoint")}
                requestedEndpoint=try ADBEndpoint(CommandLine.arguments[index+1]).value
            } else {requestedEndpoint=nil}
            stage("connect_transport")
            let manager:ADBConnectionManager
            if let requestedEndpoint {
                let owned=try await ADBManagedServer.start(adbURL:adb);server=owned
                manager=ADBConnectionManager(adbURL:adb,serverSocket:owned.socket)
                wirelessManager=manager;wirelessEndpoint=requestedEndpoint
                try await manager.connect(endpoint:requestedEndpoint)
            } else {manager=ADBConnectionManager(adbURL:adb)}
            let listed=try await manager.devices()
            let devices=listed.filter {device in
                guard device.authorization == .authorized else{return false}
                if let requestedEndpoint {return device.transport == .wireless && device.serial == requestedEndpoint}
                return device.transport == .usb
            }
            guard devices.count==1 else {throw ScanError("Need exactly one selected authorized phone")}
            // Before connect records selectedSerial, the lock query has no -s.
            // Refuse ambiguity on this route rather than querying another phone.
            if locked {guard listed.filter({$0.authorization == .authorized}).count==1 else {throw ScanError("Locked mode requires exactly one authorized device on its ADB route")}}
            let phone=PhoneSession(resources:root.appendingPathComponent("build"),adbURL:adb,serverSocket:server?.socket)
            cleanupSession=phone
            if locked {
                stage("primary_lock_initial")
                try await requirePrimaryLocked(phone,checkpoint:"initial")
            }
            stage("connect_phone")
            _=try await phone.connect(openWechatOnConnect:false,selectedSerial:devices[0].serial,allowLockedApplications:locked){_ in}
            let apps=try await phone.applications()
            guard let wechat=apps.first(where:{$0.packageName=="com.tencent.mm"}),let scanner=await phone.scannerDisplay() else {throw ScanError("WeChat scanner target unavailable")}
            if locked {guard scanner.independentLock==true else {throw ScanError("Scanner display did not confirm independent lock policy")};emit("PASS scanner independent_lock=true")}
            emit("PASS authenticated application catalog and reserved display")
            stage("extra_display")
            let extra=try await phone.createAppDisplay()
            if locked {guard extra.independentLock==true else {throw ScanError("Extra display did not confirm independent lock policy")};emit("PASS extra independent_lock=true")}
            if let settings=apps.first(where:{$0.packageName=="com.android.settings"}) {
                try await phone.launchApplication(settings,on:extra.id)
                guard try await phone.foreground(display:extra.id)?.hasPrefix("com.android.settings/")==true else {throw ScanError("Settings not on app display")}
                emit("PASS independent Settings application display")
                if locked {
                    stage("locked_settings_mirror")
                    let route=try await phone.mirrorEndpoint(display:extra.id)
                    let direct=try await phone.directMirror(display:extra.id)
                    try await settingsMirror.startVideo(adbURL:adb,serverURL:serverJar,serial:route.serial,displayID:extra.id,serverSocket:server?.socket,direct:direct,onFrame:{settingsFrames.observeSettings($0)},onFailure:{settingsFrames.failed($0)})
                    try await awaitFrames([(settingsFrames,0)])
                    try await requirePrimaryLocked(phone,checkpoint:"settings_first_frame")
                    try await Task.sleep(nanoseconds:1_000_000_000)
                    let baseline=settingsFrames.count
                    let before=settingsFrames.signature
                    settingsMirror.swipe(x1:0.5,y1:0.8,x2:0.5,y2:0.3)
                    try await Task.sleep(nanoseconds:1_000_000_000)
                    try await awaitFrames([(settingsFrames,baseline)])
                    guard try await phone.foreground(display:extra.id)?.hasPrefix("com.android.settings/")==true else {throw ScanError("Settings input route lost its application focus")}
                    guard before != nil,settingsFrames.signature != before else {throw ScanError("Settings did not visibly change after input")}
                    // A settled list before input must visibly change after a swipe.
                    // This checks real rendered response, not an injection ACK or FPS.
                    emit("PASS Settings swipe visible_content_changed=true fresh_frames=\(settingsFrames.count-baseline) focus_settings=true")
                    await settingsMirror.stop()
                }
            } else if locked {
                throw ScanError("Settings required for locked application input test")
            }
            if locked {try await requirePrimaryLocked(phone,checkpoint:"before_extra_restore")}
            try await phone.closeAppDisplay(extra.id)
            emit("PASS extra display task restoration and release")
            let endpoint=try await phone.mirrorEndpoint()
            if concurrent {
                stage("physical_mirror_start")
                try await physicalMirror.startVideo(adbURL:adb,serverURL:serverJar,serial:endpoint.serial,displayID:0,serverSocket:server?.socket,onFrame:{_ in physical.add()},onFailure:{physical.failed($0)})
                stage("physical_mirror_first_frame")
                try await awaitFrames([(physical,0)])
                emit("PASS physical display decoded frames=\(physical.count)")
                stage("reserved_empty_mirror_start")
                try await mirror.startVideo(adbURL:adb,serverURL:serverJar,serial:endpoint.serial,displayID:scanner.id,serverSocket:server?.socket,onFrame:{_ in reserved.add()},onFailure:{reserved.failed($0)})
                // GUI prewarms this route before the user's later WeChat action.
                // Empty-screen frames are optional; any asynchronous failure is retained.
                stage("reserved_empty_mirror_observe")
                try await Task.sleep(nanoseconds:1_000_000_000)
                try physical.requireHealthy();try reserved.requireHealthy()
                emit("PASS reserved empty-display handshake frames=\(reserved.count)")
            }
            let physicalBaseline=physical.count,reservedBaseline=reserved.count
            stage("wechat_launch")
            try await phone.launchApplication(wechat,on:scanner.id)
            emit("PASS WeChat launch on reserved display")
            if !concurrent {
                stage("reserved_mirror_start")
                let direct=try await phone.directMirror(display:scanner.id)
                try await mirror.startVideo(adbURL:adb,serverURL:serverJar,serial:endpoint.serial,displayID:scanner.id,serverSocket:server?.socket,direct:direct,onFrame:{_ in reserved.add()},onFailure:{reserved.failed($0)})
            }
            stage("wechat_mirror_fresh_frames")
            try await awaitFrames(concurrent ? [(physical,physicalBaseline),(reserved,reservedBaseline)] : [(reserved,reservedBaseline)])
            guard try await phone.foreground(display:scanner.id)?.hasPrefix("com.tencent.mm/")==true else {throw ScanError("WeChat independent mirror unavailable")}
            emit("PASS WeChat independent display decoded frames=\(reserved.count)")
            if locked {try await requirePrimaryLocked(phone,checkpoint:"wechat_first_frame")}
            if locked {
                stage("direct_stream_restart")
                await mirror.stop()
                try await phone.stopDirectMirror(display:scanner.id)
                let baseline=reserved.count
                let replacement=try await phone.directMirror(display:scanner.id)
                try await mirror.startVideo(adbURL:adb,serverURL:serverJar,serial:endpoint.serial,displayID:scanner.id,serverSocket:server?.socket,direct:replacement,onFrame:{_ in reserved.add()},onFailure:{reserved.failed($0)})
                try await awaitFrames([(reserved,baseline)])
                try await requirePrimaryLocked(phone,checkpoint:"direct_restart")
                emit("PASS direct EOF cleanup, explicit stop and fresh replacement stream")
            }
            if concurrent {emit("PASS both mirrors fresh physical=\(physical.count-physicalBaseline) reserved=\(reserved.count-reservedBaseline)")}
            stage("restore_wechat")
            if locked {try await requirePrimaryLocked(phone,checkpoint:"before_wechat_restore")}
            await mirror.stop();await physicalMirror.stop()
            if locked {try await phone.stopDirectMirror(display:scanner.id)}
            try await phone.restoreScannerApplications()
            emit("PASS WeChat task restored; reserved display retained")
            let clean=await cleanup(mirrors:[mirror,physicalMirror,settingsMirror],phone:phone,manager:wirelessManager,endpoint:wirelessEndpoint,server:server,locked:locked)
            guard clean else {emit("FAILED stage=cleanup category=recovery");exit(1)}
            emit("PASS all owned resources cleaned")
        } catch {
            emit("FAILED stage=\(phase) category=\(failureCategory(error.localizedDescription))")
            let clean=await cleanup(mirrors:[mirror,physicalMirror,settingsMirror],phone:cleanupSession,manager:wirelessManager,endpoint:wirelessEndpoint,server:server,locked:locked)
            emit("FAILED cleanup_ok=\(clean)");exit(1)
        }
    }
}
