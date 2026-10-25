import Foundation
import CoreVideo

private final class MirrorObservation: @unchecked Sendable {
    private let lock=NSLock()
    private var frames=0, failure:String?
    let route:String
    init(_ route:String) {self.route=route}
    func add(){lock.withLock{frames+=1}}
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
    private static func cleanup(mirrors:[MirrorSession],phone:PhoneSession?,manager:ADBConnectionManager?,endpoint:String?,server:ADBManagedServer?) async -> Bool {
        emit("STAGE cleanup_mirrors")
        for mirror in mirrors {await mirror.stop()}
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
        return phoneOK.isEmpty && wirelessOK
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
        let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        let adb=root.appendingPathComponent(".local/adb-bundle/bin/adb")
        let serverJar=root.appendingPathComponent(".tools/scrcpy/scrcpy-server-v5.0.1")
        var cleanupSession:PhoneSession?,server:ADBManagedServer?,wirelessManager:ADBConnectionManager?,wirelessEndpoint:String?
        let mirror=MirrorSession(),physicalMirror=MirrorSession()
        let reserved=MirrorObservation("reserved"),physical=MirrorObservation("physical")
        var phase="arguments"
        func stage(_ value:String){phase=value;emit("STAGE \(value)")}
        do {
            emit("MODE concurrent_mirrors=\(concurrent)")
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
            let devices=try await manager.devices().filter {device in
                guard device.authorization == .authorized else{return false}
                if let requestedEndpoint {return device.transport == .wireless && device.serial == requestedEndpoint}
                return device.transport == .usb
            }
            guard devices.count==1 else {throw ScanError("Need exactly one selected authorized phone")}
            let phone=PhoneSession(resources:root.appendingPathComponent("build"),adbURL:adb,serverSocket:server?.socket)
            cleanupSession=phone
            stage("connect_phone")
            _=try await phone.connect(openWechatOnConnect:false,selectedSerial:devices[0].serial){_ in}
            let apps=try await phone.applications()
            guard let wechat=apps.first(where:{$0.packageName=="com.tencent.mm"}),let scanner=await phone.scannerDisplay() else {throw ScanError("WeChat scanner target unavailable")}
            emit("PASS authenticated application catalog and reserved display")
            stage("extra_display")
            let extra=try await phone.createAppDisplay()
            if let settings=apps.first(where:{$0.packageName=="com.android.settings"}) {
                try await phone.launchApplication(settings,on:extra.id)
                guard try await phone.foreground(display:extra.id)?.hasPrefix("com.android.settings/")==true else {throw ScanError("Settings not on app display")}
                emit("PASS independent Settings application display")
            }
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
                try await mirror.startVideo(adbURL:adb,serverURL:serverJar,serial:endpoint.serial,displayID:scanner.id,serverSocket:server?.socket,onFrame:{_ in reserved.add()},onFailure:{reserved.failed($0)})
            }
            stage("wechat_mirror_fresh_frames")
            try await awaitFrames(concurrent ? [(physical,physicalBaseline),(reserved,reservedBaseline)] : [(reserved,reservedBaseline)])
            guard try await phone.foreground(display:scanner.id)?.hasPrefix("com.tencent.mm/")==true else {throw ScanError("WeChat independent mirror unavailable")}
            emit("PASS WeChat independent display decoded frames=\(reserved.count)")
            if concurrent {emit("PASS both mirrors fresh physical=\(physical.count-physicalBaseline) reserved=\(reserved.count-reservedBaseline)")}
            stage("restore_wechat")
            await mirror.stop();await physicalMirror.stop();try await phone.restoreScannerApplications()
            emit("PASS WeChat task restored; reserved display retained")
            let clean=await cleanup(mirrors:[mirror,physicalMirror],phone:phone,manager:wirelessManager,endpoint:wirelessEndpoint,server:server)
            guard clean else {emit("FAILED stage=cleanup category=recovery");exit(1)}
            emit("PASS all owned resources cleaned")
        } catch {
            emit("FAILED stage=\(phase) category=\(failureCategory(error.localizedDescription))")
            let clean=await cleanup(mirrors:[mirror,physicalMirror],phone:cleanupSession,manager:wirelessManager,endpoint:wirelessEndpoint,server:server)
            emit("FAILED cleanup_ok=\(clean)");exit(1)
        }
    }
}
