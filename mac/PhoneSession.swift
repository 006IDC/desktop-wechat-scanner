import Foundation
import Darwin

struct ScanError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

enum ShellCommand {
    static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval = 15, cancellable:Bool = true,
                    cancellationRequested:(@Sendable ()->Bool)? = nil) throws -> String {
        let process = Process(), pipe = Pipe(), done = DispatchSemaphore(value: 0)
        let readerDone = DispatchSemaphore(value: 0)
        var outputData = Data()
        process.executableURL = executable; process.arguments = arguments
        process.standardOutput = pipe; process.standardError = pipe
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        DispatchQueue.global(qos:.userInitiated).async {
            outputData = pipe.fileHandleForReading.readDataToEndOfFile()
            readerDone.signal()
        }
        let deadline=Date().addingTimeInterval(timeout)
        var finished=false
        while Date()<deadline && !(cancellable && Task.isCancelled) && cancellationRequested?() != true {
            if done.wait(timeout:.now()+0.1) == .success {finished=true;break}
        }
        if !finished {
            process.terminate()
            if done.wait(timeout: .now()+2) == .timedOut { kill(process.processIdentifier, SIGKILL) }
            if (cancellable && Task.isCancelled) || cancellationRequested?() == true {throw CancellationError()}
            throw ScanError("手机操作超时，请检查 USB 连接和手机授权。")
        }
        guard readerDone.wait(timeout:.now()+2) == .success else {throw ScanError("读取手机响应超时。")}
        let output = String(data: outputData, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else { throw ScanError(String(output.prefix(700)).trimmingCharacters(in: .whitespacesAndNewlines)) }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Blocking framed transport. Only PhoneSession's actor accesses this socket.
final class CameraSocket {
    struct MeasuredResponse {
        let data: Data
        let sendMilliseconds: Double
        let responseWaitMilliseconds: Double
        let responseBodyMilliseconds: Double
    }
    private var descriptor: Int32 = -1
    init(port: UInt16, token: String) throws {
        descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ScanError("无法建立本机图像通道。") }
        var timeout = timeval(tv_sec: 5, tv_usec: 0), one: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(descriptor, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { close(); throw ScanError("无法连接手机图像通道，请重新连接。") }
        try send(Data(token.utf8))
    }
    deinit { close() }
    func close() { if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 } }
    private func send(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let count = Darwin.send(descriptor, base.advanced(by: sent), raw.count-sent, 0)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ScanError("手机图像连接已中断。") }
                sent += count
            }
        }
    }
    private func read(_ count: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            var received = 0
            while received < count {
                let n = Darwin.recv(descriptor, base.advanced(by: received), count-received, 0)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw ScanError("手机图像连接已中断或超时。") }
                received += n
            }
        }
        return data
    }
    func request(_ command: UInt8, _ body: Data = Data()) throws -> Data {
        try requestMeasured(command, body).data
    }
    func requestMeasured(_ command: UInt8, _ body: Data = Data()) throws -> MeasuredResponse {
        guard body.count <= 4*1024*1024+8 else { throw ScanError("图像过大。") }
        var request = Data([command]); var length = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &length) { request.append(contentsOf: $0) }
        request.append(body)
        let sendStart=ProcessInfo.processInfo.systemUptime
        try send(request)
        let sentAt=ProcessInfo.processInfo.systemUptime
        let header = try read(5)
        let headerAt=ProcessInfo.processInfo.systemUptime
        let size = header.dropFirst().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard size <= 4*1024*1024 else { throw ScanError("手机返回了无效图像长度。") }
        let result = try read(Int(size))
        let bodyAt=ProcessInfo.processInfo.systemUptime
        guard header[0] == 0 else { throw ScanError(String(data: result, encoding: .utf8) ?? "手机处理图像失败。") }
        return MeasuredResponse(data:result,
                                sendMilliseconds:max(0,(sentAt-sendStart)*1000),
                                responseWaitMilliseconds:max(0,(headerAt-sentAt)*1000),
                                responseBodyMilliseconds:max(0,(bodyAt-headerAt)*1000))
    }
}

final class ServerLog {
    private let condition = NSCondition()
    private var buffer = "", fields: [String:String] = [:]
    private var ended = false
    func append(_ data: Data) {
        condition.lock(); defer { condition.unlock() }
        buffer += String(data: data, encoding: .utf8) ?? ""
        while let newline = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<newline]); buffer.removeSubrange(...newline)
            if line.hasPrefix("QR_LIVE "), let equal = line.firstIndex(of: "=") {
                fields[String(line[line.index(line.startIndex, offsetBy: 8)..<equal])] = String(line[line.index(after: equal)...])
            }
        }
        condition.broadcast()
    }
    func finish() { condition.lock(); ended=true; condition.broadcast(); condition.unlock() }
    func dpi() -> Int { condition.lock(); defer { condition.unlock() }; return Int(fields["display_dpi"] ?? "") ?? 320 }
    func independentLockReady() -> Bool {
        condition.lock();defer {condition.unlock()}
        return fields["ready"] == "1" && fields["independent_lock_ready"] == "1"
    }
    func dimensions() -> (Int,Int) {
        condition.lock();defer {condition.unlock()}
        return (Int(fields["display_width"] ?? "") ?? 720,Int(fields["display_height"] ?? "") ?? 1280)
    }
    func encoderLatencyFrames() -> Int? {
        condition.lock(); defer { condition.unlock() }
        guard let raw = fields["direct_codec_latency"], let value = Int(raw), (0...120).contains(value) else { return nil }
        return value
    }
    static func setupDescription(_ phase:String?) -> String? {
        switch phase {
        case "virtual_device": return "创建独立设备"
        case "camera_policy": return "配置本次虚拟相机"
        case "virtual_camera": return "注册虚拟相机"
        case "camera_register": return "提交虚拟相机注册"
        case "camera_identifier": return "取得虚拟相机标识"
        case "camera_owner_watch": return "确认虚拟相机归属"
        case "owned_display": return "创建独立屏幕"
        case "session_channel": return "建立本次连接通道"
        default: return nil
        }
    }
    func waitReady() throws -> (Int,Int,Int) {
        condition.lock(); defer { condition.unlock() }
        let end = Date().addingTimeInterval(25)
        while fields["ready"] != "1" && fields["error"] == nil && !ended && Date() < end && !Task.isCancelled {
            condition.wait(until:min(end,Date().addingTimeInterval(0.2)))
        }
        if Task.isCancelled {throw CancellationError()}
        if let error = fields["error"] { throw ScanError("手机暂不支持：\(error)") }
        guard fields["ready"] == "1", let device = Int(fields["device_id"] ?? ""),
              let display = Int(fields["display_id"] ?? ""), let pid = Int(fields["pid"] ?? ""),
              device > 0, display > 0, pid > 0 else {
            let phase = Self.setupDescription(fields["setup_phase"]).map { "（\($0)）" } ?? ""
            throw ScanError(ended ? "手机连接服务在准备完成前退出\(phase)，请重新连接。" : "手机连接服务准备超时\(phase)，已停止本次连接。")
        }
        return (device,display,pid)
    }
}

private struct Recovery: Codable {
    var serial: String, suffix: String, token: String, mac: String
    var association: Int? = nil
    var port: UInt16? = nil
    var display: Int? = nil
    var device: Int? = nil
    var pid: Int? = nil
    var appDisplays: [AndroidAppDisplay]? = nil
    var appTasks: [AndroidOwnedTask]? = nil
    var path: String { "/data/local/tmp/006idc-scan-" + suffix }
    var socketName: String { "006idc_scan_" + suffix }
    var valid: Bool {
        suffix.range(of: "^[0-9a-f]{8}$",options: .regularExpression) != nil &&
        token.range(of: "^[0-9a-f]{32}$",options: .regularExpression) != nil &&
        mac.range(of: "^02:06:1D:([0-9A-F]{2}:){2}[0-9A-F]{2}$", options: .regularExpression) != nil &&
        !serial.isEmpty && !serial.contains("\n") &&
        (association == nil || association! > 0) &&
        (device == nil || device! > 0) && (pid == nil || pid! > 0) && (display == nil || display! > 0) &&
        (appDisplays ?? []).count <= 4 && (appDisplays ?? []).allSatisfy({ $0.isValid && $0.id != display }) &&
        Set((appDisplays ?? []).map(\.id)).count == (appDisplays ?? []).count &&
        (appTasks ?? []).allSatisfy({ $0.id > 0 && $0.originalDisplay >= 0 && $0.ownedDisplay > 0 &&
            $0.packageName.range(of: "^[A-Za-z_][A-Za-z0-9_]*(\\.[A-Za-z_][A-Za-z0-9_]*)+$", options: .regularExpression) != nil })
    }
}

private struct VirtualRecord {
    let device: Int
    let association: Int
    let owner: String
}

struct CameraFrameExpiredError: LocalizedError {
    var errorDescription:String? {"本次桌面坐标已过时。"}
}

struct CameraFrameReceipt {
    let processingMilliseconds: Double?
    let requestMilliseconds: Double
    let sendMilliseconds: Double
    let responseWaitMilliseconds: Double
    let responseBodyMilliseconds: Double
    init(processingMilliseconds: Double?, requestMilliseconds: Double,
         sendMilliseconds: Double=0, responseWaitMilliseconds: Double=0,
         responseBodyMilliseconds: Double=0) {
        self.processingMilliseconds=processingMilliseconds
        self.requestMilliseconds=requestMilliseconds
        self.sendMilliseconds=sendMilliseconds
        self.responseWaitMilliseconds=responseWaitMilliseconds
        self.responseBodyMilliseconds=responseBodyMilliseconds
    }
}

actor PhoneSession {
    /// Fixed diagnostic stages only; no device identity, app page or raw errors.
    private(set) var cleanupStage="notStarted"
    private(set) var cleanupScannerBeforeSleep=false
    private(set) var cleanupCameraStreamsBeforeSleep:Int?
    private(set) var cleanupCameraClosureConfirmed=false

    private let adbURL: URL, jarURL: URL, recoveryURL: URL
    private let serverSocket: String?
    private var recovery: Recovery?
    private var server: Process?, serverPipe: Pipe?, channel: CameraSocket?
    private var displayWidth=720, displayHeight=1280, displayDpi=320
    private var displayID: Int?
    private(set) var independentApplicationsWhenLocked=false
    private var genericDesktopCamera=false
    // Canned placement counts only; no component names, IDs, extras or page text.
    private(set) var lastApplicationLaunchEvidence:[String:Int]?
    private var cleaning=false
    private(set) var connectionStage = "idle"
    private var diagnosticLog: ServerLog?
    func encoderLatencyFrames() -> Int? { diagnosticLog?.encoderLatencyFrames() }
    init(resources: URL, adbURL: URL? = nil, serverSocket: String? = nil) {
        self.serverSocket = serverSocket
        self.adbURL = adbURL ?? resources.appendingPathComponent("adb")
        jarURL = resources.appendingPathComponent("camera-probe.jar")
        let support = FileManager.default.urls(for: .applicationSupportDirectory,in: .userDomainMask)[0].appendingPathComponent("006IDC/DesktopWeChatScanner")
        recoveryURL = support.appendingPathComponent("session.json")
    }
    private func adb(_ args: [String], serial: String? = nil, timeout: TimeInterval = 15) throws -> String {
        let selected = serial ?? recovery?.serial
        return try ShellCommand.run(adbURL, (serverSocket.map { ["-L", $0] } ?? []) + (selected.map { ["-s",$0] } ?? []) + args, timeout: timeout,cancellable:!cleaning)
    }
    private func shell(_ command: String) throws -> String { try adb(["shell",command]) }
    private func save() throws {
        guard let state = recovery else { return }
        try FileManager.default.createDirectory(at: recoveryURL.deletingLastPathComponent(),withIntermediateDirectories:true)
        try JSONEncoder().encode(state).write(to: recoveryURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:recoveryURL.path)
    }
    func connect(openWechatOnConnect: Bool = true, selectedSerial: String? = nil, allowLockedApplications: Bool = false, desktopHome: Bool = false, balancedDisplay: Bool = false, displayBeforeCamera: Bool = false, mirrorOnly: Bool = false, realtimeVideo: Bool = false, genericDesktopCamera:Bool=false, progress: @escaping @Sendable (String) -> Void) async throws -> String {
        guard server == nil else { throw ScanError("手机已经连接。") }
        guard !genericDesktopCamera || (desktopHome && !mirrorOnly) else {
            throw ScanError("通用桌面相机需要启用相机的应用桌面会话。")
        }
        do {
            connectionStage = "enumeration"
            progress("正在检查手机连接…")
            let listing = try adb(["devices","-l"])
            let lines = listing.split(separator:"\n").map { $0.split(whereSeparator:{$0==" " || $0=="\t"}).map(String.init) }
            let devices = lines.filter { $0.count >= 2 && $0[1] == "device" &&
                (selectedSerial == nil ? $0.contains(where:{$0.hasPrefix("usb:")}) : $0[0] == selectedSerial!) }
            if devices.isEmpty {
                if selectedSerial != nil { throw ScanError("选中的手机当前未连接或尚未授权，请刷新设备列表。") }
                if lines.contains(where:{$0.count>=2 && $0[1]=="unauthorized"}) { throw ScanError("请解锁手机，并在手机上允许这台 Mac 的 USB 调试。") }
                throw ScanError("未发现已授权的 USB 手机。请使用数据线连接并开启 USB 调试。")
            }
            guard devices.count == 1 else { throw ScanError("检测到多台 USB 手机，请只保留要扫码的那一台。") }
            let serial = devices[0][0]
            if FileManager.default.fileExists(atPath: recoveryURL.path) {
                let old = try JSONDecoder().decode(Recovery.self,from:Data(contentsOf:recoveryURL))
                guard old.valid,old.serial==serial else { throw ScanError("上次会话的设备标识与当前连接不一致；无线地址与 USB 标识不能自动互换，请使用上次的准确连接清理。") }
                recovery=old
                connectionStage = "recovery"
                progress("正在清理上次未结束的连接…")
                let problems = disconnect()
                guard problems.isEmpty else { throw ScanError(problems) }
            }
            connectionStage = "android_version"
            let api = Int(try adb(["shell","getprop ro.build.version.sdk"],serial:serial)) ?? 0
            guard api >= 36 else { throw ScanError("此版本需要 Android 16 或更新系统。") }
            if openWechatOnConnect {
                let wechat = try adb(["shell","cmd package list packages com.tencent.mm"],serial:serial)
                guard wechat.split(separator:"\n").contains("package:com.tencent.mm") else { throw ScanError("手机主用户中没有找到微信。") }
            }
            let suffix = String(UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased().prefix(8))
            let token = UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased()
            let hex = Array(suffix.uppercased())
            let mac = "02:06:1D:" + stride(from:0,to:6,by:2).map { String(hex[$0...$0+1]) }.joined(separator:":")
            recovery=Recovery(serial:serial,suffix:suffix,token:token,mac:mac)
            try save(); try Task.checkCancellation()
            let r = recovery!
            connectionStage = "session_directory"
            _ = try shell("mkdir \(r.path) && printf '%s' '\(r.token)' > \(r.path)/owner")
            progress("正在创建临时手机摄像头…")
            connectionStage = "association"
            _ = try shell("cmd companiondevice associate 0 com.android.shell \(r.mac) android.app.role.COMPANION_DEVICE_APP_STREAMING")
            let entries = try shell("cmd companiondevice list 0").split(separator:"\n").map { $0.split(separator:"|").map { $0.trimmingCharacters(in:.whitespaces) } }
            guard let entry = entries.first(where:{$0.count==3 && $0[1]=="com.android.shell" && $0[2].uppercased()==r.mac}), let association=Int(entry[0]) else { throw ScanError("手机未返回有效的临时连接编号。") }
            recovery?.association=association; try save()
            connectionStage = "service_transfer"
            _ = try adb(["push",jarURL.path,r.path+"/server.jar"])
            try Task.checkCancellation()
            let process=Process(), pipe=Pipe(), log=ServerLog()
            diagnosticLog = log
            process.executableURL=adbURL
            let lockArgument=(allowLockedApplications ? " independent-lock":"") + (desktopHome ? " desktop-home":"") + (balancedDisplay ? " balanced-display":"") + (displayBeforeCamera ? " display-before-camera":"") + (mirrorOnly ? " mirror-only":"") + (realtimeVideo ? " realtime-video":"") + (genericDesktopCamera ? " desktop-camera-source":"")
            process.arguments=(serverSocket.map { ["-L", $0] } ?? []) + ["-s",r.serial,"shell","CLASSPATH=\(r.path)/server.jar app_process / LiveCameraServer \(association) \(r.socketName) \(r.token)\(lockArgument)"]
            process.standardOutput=pipe;process.standardError=pipe
            pipe.fileHandleForReading.readabilityHandler = { handle in let data=handle.availableData; if !data.isEmpty {log.append(data)} else {log.finish()} }
            connectionStage = "service_startup"
            server=process;serverPipe=pipe;try process.run()
            let (device,display,pid)=try log.waitReady()
            (displayWidth,displayHeight)=log.dimensions(); displayDpi=log.dpi()
            displayID=display;recovery?.display=display;recovery?.device=device;recovery?.pid=pid;try save()
            independentApplicationsWhenLocked=allowLockedApplications && log.independentLockReady()
            if allowLockedApplications && !independentApplicationsWhenLocked {throw ScanError("手机没有确认独立窗口的锁屏策略，已停止连接。")}
            connectionStage = "image_forward"
            let portText=try adb(["forward","tcp:0","localabstract:"+r.socketName])
            guard let port=UInt16(portText), port>0 else {throw ScanError("USB 图像通道创建失败。")}
            recovery?.port=port;try save()
            connectionStage = "authentication"
            channel=try CameraSocket(port:port,token:r.token)
            self.genericDesktopCamera=genericDesktopCamera
            if genericDesktopCamera {
                guard desktopHome,!mirrorOnly,try cameraState().desktopCameraSupported else {
                    throw ScanError("手机服务未提供通用桌面相机，请使用完整的新版本。")
                }
                guard try channel?.request(26,Data([2]))==Data([1]),try cameraState().desktopCameraEnabled else {
                    throw ScanError("手机未确认桌面相机模式。")
                }
            }
            if openWechatOnConnect {
                progress("正在打开手机微信…")
                try openWechat()
            }
            try Task.checkCancellation()
            connectionStage = "model_query"
            let model = try shell("getprop ro.product.model")
            connectionStage = "ready"
            return model
        } catch {
            let cleanup=disconnect()
            throw ScanError(error.localizedDescription + (cleanup.isEmpty ? "" : "\n"+cleanup))
        }
    }
    private static func epochBytes(_ epoch: Int) throws -> Data {
        guard epoch >= 0 else { throw ScanError("扫码帧序号无效。") }
        var value = UInt64(epoch).bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
    /// Android processing only, when supported; ACK round-trip remains a separate measurement.
    @discardableResult
    func frame(_ data: Data, epoch: Int, selectedAt:TimeInterval?=nil,
               isCurrent:(@Sendable ()->Bool)?=nil) throws -> CameraFrameReceipt {
        try Task.checkCancellation()
        if let selectedAt,ProcessInfo.processInfo.systemUptime-selectedAt>0.5 {
            throw CameraFrameExpiredError()
        }
        guard let channel else {throw ScanError("手机未连接。")}
        guard data.count <= 4*1024*1024 else {throw ScanError("图像过大。")}
        var body = try Self.epochBytes(epoch)
        body.append(data)
        let started=ProcessInfo.processInfo.systemUptime
        let response:CameraSocket.MeasuredResponse
        if let isCurrent,!isCurrent() {throw CameraFrameExpiredError()}
        do {response=try channel.requestMeasured(1,body)}
        catch let error as ScanError where error.message=="Desktop camera has no verified scanner owner" || error.message=="Desktop camera state changed while decoding frame" {
            // A normal scanner exit can invalidate an in-flight frame before
            // the next status poll. Drop it without displaying a transport error.
            throw CameraFrameExpiredError()
        }
        let processing=try Self.frameProcessingMilliseconds(in:response.data)
        return CameraFrameReceipt(processingMilliseconds:processing,
                                  requestMilliseconds:(ProcessInfo.processInfo.systemUptime-started)*1000,
                                  sendMilliseconds:response.sendMilliseconds,
                                  responseWaitMilliseconds:response.responseWaitMilliseconds,
                                  responseBodyMilliseconds:response.responseBodyMilliseconds)
    }
    /// Fixed-size synthetic calibration only. Capability negotiation happens in
    /// NativeScannerOverlay; the server still verifies the live scanner owner.
    static func solidCalibrationBody(epoch:Int,blue:Bool) throws -> Data {
        var body=try epochBytes(epoch)
        body.append(blue ? 1:0)
        return body
    }
    func solidCalibrationFrame(blue:Bool,epoch:Int) throws -> CameraFrameReceipt {
        try Task.checkCancellation()
        guard let channel else{throw ScanError("手机未连接。")}
        let body=try Self.solidCalibrationBody(epoch:epoch,blue:blue)
        let started=ProcessInfo.processInfo.systemUptime
        let response=try channel.requestMeasured(25,body)
        return CameraFrameReceipt(processingMilliseconds:try Self.frameProcessingMilliseconds(in:response.data),
                                  requestMilliseconds:(ProcessInfo.processInfo.systemUptime-started)*1000,
                                  sendMilliseconds:response.sendMilliseconds,
                                  responseWaitMilliseconds:response.responseWaitMilliseconds,
                                  responseBodyMilliseconds:response.responseBodyMilliseconds)
    }
    static func frameProcessingMilliseconds(in reply: Data) throws -> Double? {
        // Empty is compatible with older servers and deliberately ignored epochs.
        if reply.isEmpty { return nil }
        guard reply.count == 8 else { throw ScanError("手机返回了无效的图像处理耗时长度。") }
        let nanos = reply.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard nanos <= UInt64(Int64.max) else { throw ScanError("手机返回了无效的图像处理耗时。") }
        return Double(nanos) / 1_000_000
    }
    func clear(epoch: Int, requireConnection:Bool=false) throws {
        guard let channel else {
            if requireConnection {throw ScanError("手机未确认清除相机画面。")}
            return
        }
        _ = try channel.request(3,Self.epochBytes(epoch))
    }
    /// Discard a moved/retried image within the same capture generation. Unlike
    /// advancing clear(), it cannot invalidate a newer generation's pixels.
    func discardFrame(epoch:Int) throws {
        guard let channel else{throw ScanError("手机未确认丢弃过期画面。")}
        _ = try channel.request(23,Self.epochBytes(epoch))
    }
    func heartbeat() throws { guard let channel else {throw ScanError("手机未连接。")};_ = try channel.request(4) }
    static func desktopCameraBindingBody(display:Int,package:String?) throws -> Data {
        guard display>0,display<=Int(Int32.max) else{throw ScanError("桌面相机窗口无效。")}
        var body=Data([package == nil ? 0:1]),value=Int32(display).bigEndian
        withUnsafeBytes(of:&value){body.append(contentsOf:$0)}
        if let package {
            guard package.utf8.count<=255,AndroidApplication(packageName:package,component:package+"/.Main",name:"").isValid else {
                throw ScanError("桌面相机应用无效。")
            }
            body.append(Data(package.utf8))
        }
        return body
    }
    private func bindDesktopCamera(display:Int,package:String?) throws -> Bool {
        guard genericDesktopCamera else{return false}
        guard let channel else{throw ScanError("手机未连接。")}
        let reply=try channel.request(26,Self.desktopCameraBindingBody(display:display,package:package))
        return try DesktopCameraLaunch.accepted(reply,clearing:package == nil)
    }
    func cameraState() throws -> PhoneCameraState {
        try PhoneCameraState.decode(cameraStatusSnapshot())
    }
    /// Authenticated bounded technical status; callers must not persist app activity history.
    func cameraStatusSnapshot() throws -> Data {
        try Task.checkCancellation()
        guard let channel else {throw ScanError("手机未连接。")}
        return try channel.request(5)
    }
    func screenshot() throws -> Data { guard let channel else {throw ScanError("手机未连接。")};return try channel.request(2) }
    func tap(x: Int,y: Int) throws {
        guard let displayID else {return}
        let result=try shell("input -d \(displayID) tap \(min(displayWidth-1,max(0,x*displayWidth/720))) \(min(displayHeight-1,max(0,y*displayHeight/1280)))")
        if result.contains("Exception") || result.contains("Permission") || result.contains("Error") {throw ScanError(String(result.prefix(400)))}
    }
    func back() throws { if let displayID {_ = try shell("input -d \(displayID) keyevent KEYCODE_BACK")} }
    func mirrorEndpoint() throws -> (serial: String, display: Int) {
        guard let state=recovery,let displayID,channel != nil else {throw ScanError("手机未连接。")}
        return (state.serial,displayID)
    }
    func mirrorEndpoint(display: Int) throws -> (serial: String, display: Int) {
        guard let state = recovery, channel != nil, ownsDisplay(display) else { throw ScanError("屏幕不属于本次手机连接。") }
        return (state.serial, display)
    }
    func directMirror(display target:Int) throws -> DirectMirrorDescriptor? {
        guard independentApplicationsWhenLocked,target != 0 else{return nil}
        guard let channel,ownsDisplay(target),let id=Int32(exactly:target) else {throw ScanError("直连画面不属于当前应用窗口。")}
        try requireApplicationAccess(on:target)
        var value=id.bigEndian
        let payload=withUnsafeBytes(of:&value){Data($0)}
        do {
            let descriptor=try JSONDecoder().decode(DirectMirrorDescriptor.self,from:channel.request(20,payload))
            guard descriptor.isValid,descriptor.display==target else {throw ScanError("手机返回的直连画面信息无效。")}
            return descriptor
        } catch {
            _=try? channel.request(21,payload)
            throw error
        }
    }
    func stopDirectMirror(display target:Int) throws {
        guard independentApplicationsWhenLocked else{return}
        guard let channel,ownsDisplay(target),let id=Int32(exactly:target) else {throw ScanError("直连画面不属于当前应用窗口。")}
        var value=id.bigEndian
        _=try channel.request(21,withUnsafeBytes(of:&value){Data($0)})
    }
    /// Return only a foreground component, never task extras, URLs or chat text.
    func foreground(onVirtualDisplay: Bool) async throws -> String? {
        guard let displayID else { return nil }
        return try await foreground(display: onVirtualDisplay ? displayID : 0)
    }
    func foreground(display target: Int) async throws -> String? {
        guard let state=recovery, target == 0 || ownsDisplay(target) else {return nil}
        let adb=adbURL, serial=state.serial, route=serverSocket.map { ["-L", $0] } ?? []
        // Read-only monitoring must not hold the camera actor while ADB waits.
        let dump=try await Task.detached {
            try ShellCommand.run(adb,route + ["-s",serial,"shell","dumpsys activity activities"],timeout:5)
        }.value
        return Self.foregroundComponent(in:dump,display:target)
    }
    static func foregroundComponent(in dump:String,display:Int) -> String? {
        var current:Int?, resumed:String?
        for raw in dump.split(separator:"\n") {
            let line=raw.trimmingCharacters(in:.whitespaces)
            if line.hasPrefix("Display #") {
                current=Int(line.dropFirst(9).prefix(while:{$0.isNumber}))
            } else if current==display && (line.contains("topResumedActivity=") || line.contains("mResumedActivity:")) {
                let fields=line.split(whereSeparator:{$0==" " || $0=="\t" || $0=="}"})
                if let component=fields.first(where:{$0.contains("/") && !$0.contains("://")}) {
                    resumed=String(component)
                }
            }
        }
        return resumed
    }
    func moveWechat(toVirtualDisplay:Bool) throws {
        guard let displayID else {throw ScanError("手机未连接。")}
        let source=toVirtualDisplay ? 0 : displayID, destination=toVirtualDisplay ? displayID : 0
        let dump=try shell("dumpsys activity activities")
        var current:Int?, task:Int?
        for raw in dump.split(separator:"\n") {
            let line=raw.trimmingCharacters(in:.whitespaces)
            if line.hasPrefix("Display #") {current=Int(line.dropFirst(9).prefix(while:{$0.isNumber}))}
            else if current==source && (line.contains("topResumedActivity=") || line.contains("mResumedActivity:")) && line.contains("com.tencent.mm/") {
                for field in line.split(whereSeparator:{$0==" " || $0=="}"}) {
                    if field.first=="t",let value=Int(field.dropFirst()),value>0 {task=value}
                }
            }
        }
        guard let task else {throw ScanError("未找到当前微信窗口，请回到微信后重试。")}
        let result=try shell("am display move-stack \(task) \(destination)")
        guard !result.lowercased().contains("exception") && !result.lowercased().contains("error") else {throw ScanError("微信窗口切换失败。")}
    }
    func mainHome() throws { _ = try shell("input -d 0 keyevent KEYCODE_HOME") }
    /// Open only the normal launcher on the display owned by this session.
    func openWechat(onVirtualDisplay:Bool = true) throws {
        guard let displayID,let state=recovery,state.device != nil else {
            throw ScanError("手机临时屏幕尚未准备好。")
        }
        if onVirtualDisplay {
            try launchApplication(AndroidApplication(packageName: "com.tencent.mm", component: "com.tencent.mm/.ui.LauncherUI", name: "微信"), on: displayID)
            return
        }
        let target=0
        let trust=try shell("dumpsys trust")
        guard let owner=trust.split(separator:"\n").map(String.init)
            .first(where:{$0.contains("(id=0,") && $0.contains("(current)")}) else {
            throw ScanError("无法确认手机主用户的锁屏状态，请保持手机解锁后重试。")
        }
        if owner.contains("deviceLocked=1") {
            throw ScanError("请先解锁手机，再点开始扫码。")
        }
        guard owner.contains("deviceLocked=0") else {
            throw ScanError("无法确认手机是否已解锁，请解锁后重试。")
        }
        let launch=try shell("am start --display \(target) -n com.tencent.mm/.ui.LauncherUI")
        let lower=launch.lowercased()
        if lower.contains("error:") || lower.contains("exception") {
            throw ScanError("微信未能在手机临时屏幕启动："+String(launch.prefix(300)))
        }
        for _ in 0..<5 {
            Thread.sleep(forTimeInterval:0.25)
            let activities=try shell("dumpsys activity activities")
            var onOurDisplay=false
            for line in activities.split(separator:"\n") {
                let value=line.trimmingCharacters(in:.whitespaces)
                if value.hasPrefix("Display #") {
                    let number=value.dropFirst("Display #".count).prefix(while:{$0.isNumber})
                    onOurDisplay=Int(number)==target
                } else if onOurDisplay && value.contains("com.tencent.mm/") {
                    return
                }
            }
        }
        throw ScanError("微信没有出现在本次手机临时屏幕，请保持手机解锁后重试。")
    }
    private func ownsDisplay(_ id: Int) -> Bool {
        id == displayID || recovery?.appDisplays?.contains(where: { $0.id == id }) == true
    }
    func scannerDisplay() -> AndroidAppDisplay? {
        guard let displayID else { return nil }
        return AndroidAppDisplay(id: displayID, width: displayWidth, height: displayHeight, dpi: displayDpi, independentLock:independentApplicationsWhenLocked)
    }
    func applications() async throws -> [AndroidApplication] {
        guard let channel else { throw ScanError("手机未连接。") }
        return try catalog(channel)
    }
    private func catalog(_ channel: CameraSocket) throws -> [AndroidApplication] { try AndroidApplication.decodeCatalog(channel.request(10)) }
    private func appendAppDisplay(_ display: AndroidAppDisplay) {
        // Read before optional-chain writeback begins (Swift exclusivity).
        var displays = recovery?.appDisplays ?? []
        displays.append(display)
        recovery?.appDisplays = displays
    }
    private func appendAppTask(_ task: AndroidOwnedTask) {
        var tasks = recovery?.appTasks ?? []
        tasks.append(task)
        recovery?.appTasks = tasks
    }
    func createAppDisplay() throws -> AndroidAppDisplay {
        guard let channel else { throw ScanError("手机未连接。") }
        guard (recovery?.appDisplays?.count ?? 0) < 4 else { throw ScanError("最多同时打开四个应用窗口。") }
        let created = try JSONDecoder().decode(AndroidAppDisplay.self, from: channel.request(11))
        guard created.isValid, !ownsDisplay(created.id) else { throw ScanError("手机返回无效的应用屏幕。") }
        appendAppDisplay(created)
        do { try save() }
        catch {
            var id = Int32(created.id).bigEndian
            _ = try? channel.request(12, withUnsafeBytes(of: &id) { Data($0) })
            recovery?.appDisplays?.removeAll(where: { $0.id == created.id })
            throw error
        }
        if independentApplicationsWhenLocked && created.independentLock != true {
            try closeAppDisplay(created.id)
            throw ScanError("新应用窗口未确认锁屏独立显示，已关闭该临时屏幕。")
        }
        return created
    }
    func primaryUserUnlocked() throws -> Bool {
        let trust = try shell("dumpsys trust")
        return try Self.primaryUserUnlocked(in:trust)
    }
    /// Monitoring must not block the frame channel while an ADB subprocess waits.
    func pollPrimaryUserUnlocked() async throws -> Bool {
        guard let state=recovery else {throw ScanError("手机未连接。")}
        let adb=adbURL,route=serverSocket.map { ["-L",$0] } ?? []
        let trust=try await Task.detached(priority:.utility) {
            try ShellCommand.run(adb,route+["-s",state.serial,"shell","dumpsys trust"],timeout:5)
        }.value
        try Task.checkCancellation()
        guard recovery?.path==state.path,recovery?.serial==state.serial else {throw CancellationError()}
        return try Self.primaryUserUnlocked(in:trust)
    }
    private static func primaryUserUnlocked(in trust:String) throws -> Bool {
        guard let owner = trust.split(separator: "\n").first(where: { $0.contains("(id=0,") && $0.contains("(current)") }) else {throw ScanError("无法确认手机主用户的锁屏状态。")}
        if owner.contains("deviceLocked=0") {return true}
        if owner.contains("deviceLocked=1") {return false}
        throw ScanError("无法确认手机主用户的锁屏状态。")
    }
    private func requireApplicationAccess(on target:Int) throws {
        let confirmed=target==displayID || recovery?.appDisplays?.contains(where:{$0.id==target && $0.independentLock==true})==true
        if independentApplicationsWhenLocked && target>0 && ownsDisplay(target) && confirmed {return}
        guard try primaryUserUnlocked() else {throw ScanError("手机已锁定。请解锁，或重新连接并开启“手机锁屏时继续使用独立应用”。")}
    }
    private func tasks(requiredDisplay: Int? = nil) throws -> [AndroidTaskSnapshot] {
        let dump = try shell("dumpsys activity activities")
        return try AndroidTaskSnapshot.parseChecked(dump, requiredDisplay: requiredDisplay)
    }
    private func moveTask(_ id: Int, to display: Int, expectedRoot: Int? = nil) throws {
        let snapshot = try tasks()
        guard let task = snapshot.first(where: { $0.id == id }) else { return }
        guard task.userID == 0, !task.rootContainsOtherUsers,
              snapshot.filter({ $0.rootID == task.rootID }).allSatisfy({ $0.userID == 0 && !$0.rootContainsOtherUsers }) else {
            throw ScanError("任务容器包含其他手机用户，不能移动。")
        }
        guard expectedRoot == nil || task.rootID == expectedRoot else { throw ScanError("应用任务容器已变化，已保留恢复记录。") }
        // Android may already have returned the task while a window is closing.
        // Moving a root to its current display throws instead of being a no-op.
        if task.display == display { return }
        let result = try shell("am display move-stack \(task.rootID) \(display)")
        guard !result.lowercased().contains("error"), !result.lowercased().contains("exception") else { throw ScanError("手机拒绝移动应用任务。") }
        if let moved = try tasks().first(where: { $0.id == id }), moved.display != display {
            throw ScanError("应用任务没有移动到指定屏幕，已保留恢复记录。")
        }
    }
    @discardableResult
    func launchApplication(_ app: AndroidApplication, on target: Int) throws -> Bool {
        lastApplicationLaunchEvidence=nil
        guard let state = recovery, channel != nil, ownsDisplay(target), app.isValid else { throw ScanError("应用或屏幕不属于本次连接。") }
        try requireApplicationAccess(on:target)
        // Revalidate against the authenticated launcher catalog, never execute an arbitrary component.
        guard let channel, try catalog(channel).contains(where: { $0.canonicalComponent == app.canonicalComponent }) else { throw ScanError("手机主用户中未找到此应用入口。") }
        return try DesktopCameraLaunch.perform(bind:{try self.bindDesktopCamera(display:target,package:app.packageName)},launch:{
            let before = try tasks(requiredDisplay: target)
            let moving = before.filter { $0.userID == 0 && $0.packageName == app.packageName && $0.display != target }
            let groups = Dictionary(grouping: moving, by: \.rootID)
            for root in groups.keys {
                guard before.filter({ $0.rootID == root }).allSatisfy({ $0.userID == 0 && !$0.rootContainsOtherUsers && $0.packageName == app.packageName && $0.display != target }) else {
                    throw ScanError("此应用与其他应用共享任务容器，无法安全地单独移入窗口。")
                }
            }
            // Record every child before moving a root once: one root move affects all children.
            for task in moving {
                if state.appTasks?.contains(where: { $0.id == task.id }) != true {
                    appendAppTask(AndroidOwnedTask(id: task.id, originalDisplay: task.display, packageName: task.packageName, ownedDisplay: target))
                } else if let index = recovery?.appTasks?.firstIndex(where: { $0.id == task.id }), let old = recovery?.appTasks?[index] {
                    recovery?.appTasks?[index] = AndroidOwnedTask(id: old.id, originalDisplay: old.originalDisplay, packageName: old.packageName, ownedDisplay: target)
                }
            }
            try save()
            for root in groups.keys.sorted() {
                guard let group = groups[root], let representative = group.first else { continue }
                let current = try tasks().filter { $0.rootID == root }
                guard current.allSatisfy({ task in task.userID == 0 && !task.rootContainsOtherUsers && group.contains(where: { $0.id == task.id && $0.packageName == task.packageName && $0.display == task.display }) }) else {
                    throw ScanError("应用任务在移动前发生变化，已保留恢复记录。")
                }
                try moveTask(representative.id, to: target, expectedRoot: root)
            }
            let result = try shell("am start --user 0 --display \(target) -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -n '\(app.component)'")
            guard !result.lowercased().contains("error:"), !result.lowercased().contains("exception") else { throw ScanError("手机应用启动失败。") }
            for _ in 0..<8 {
                let activityDump = try shell("dumpsys activity activities")
                let after = try AndroidTaskSnapshot.parseChecked(activityDump, requiredDisplay: target)
                for task in after where task.userID == 0 && !task.rootContainsOtherUsers && task.packageName == app.packageName && task.display == target && !(recovery?.appTasks?.contains(where: { $0.id == task.id }) ?? false) {
                    appendAppTask(AndroidOwnedTask(id: task.id, originalDisplay: 0, packageName: app.packageName, ownedDisplay: target))
                    try save()
                }
                let foreground=Self.foregroundComponent(in:activityDump,display:target)
                lastApplicationLaunchEvidence=[
                    "foregroundKind":foreground.map{$0.hasPrefix(app.packageName+"/") ? 1:2} ?? 0,
                    "targetTaskCount":after.filter{$0.display==target}.count,
                    "requestedTasksOnTarget":after.filter{$0.display==target && $0.userID==0 && $0.packageName==app.packageName}.count,
                    "requestedTasksElsewhere":after.filter{$0.display != target && $0.userID==0 && $0.packageName==app.packageName}.count,
                    "otherUserTasksOnTarget":after.filter{$0.display==target && ($0.userID != 0 || $0.rootContainsOtherUsers)}.count]
                if foreground?.hasPrefix(app.packageName+"/")==true {
                    lastApplicationLaunchEvidence=nil
                    return
                }
                Thread.sleep(forTimeInterval: 0.2)
            }
            throw ScanError("应用未出现在指定屏幕；已保留恢复记录。")
        },clear:{_ = try self.bindDesktopCamera(display:target,package:nil)})
    }
    private func restoreTasks(on target: Int) throws {
        let snapshot = try tasks(requiredDisplay: target)
        guard snapshot.filter({ $0.display == target }).allSatisfy({ $0.userID == 0 && !$0.rootContainsOtherUsers }) else {
            throw ScanError("应用窗口包含其他手机用户，已保留窗口和恢复记录。")
        }
        let recorded = recovery?.appTasks ?? []
        // Native secondary HOME belongs to the owned display itself. Android
        // destroys it with that display; never move it onto the physical phone.
        let groups = Dictionary(grouping: snapshot.filter { $0.display == target && !$0.isHome }, by: \.rootID)
        var destinations: [Int: Int] = [:]
        // A root cannot be split by move-stack. Refuse conflicting destinations
        // before moving anything, including children associated with another window.
        for (root, group) in groups {
            guard snapshot.filter({ $0.rootID == root }).allSatisfy({ $0.display == target }) else {
                throw ScanError("任务容器跨越多个屏幕，已保留恢复记录。")
            }
            let targetDisplays = Set(group.map { task in
                recorded.first(where: { $0.id == task.id && $0.packageName == task.packageName })?.originalDisplay ?? 0
            })
            guard targetDisplays.count == 1, let destination = targetDisplays.first, destination != target else {
                throw ScanError("同一任务容器的原屏幕记录不一致，已保留窗口和恢复记录。")
            }
            destinations[root] = destination
        }
        for root in groups.keys.sorted() {
            guard let group = groups[root], let representative = group.first, let destination = destinations[root] else { continue }
            let current = try tasks().filter { $0.rootID == root }
            guard current.allSatisfy({ task in task.userID == 0 && !task.rootContainsOtherUsers && group.contains(where: { $0.id == task.id && $0.packageName == task.packageName && task.display == target }) }) else {
                throw ScanError("应用任务在恢复前发生变化，已保留窗口和恢复记录。")
            }
            try moveTask(representative.id, to: destination, expectedRoot: root)
        }
        let restored = try tasks(requiredDisplay: target)
        guard !restored.contains(where: { $0.display == target && !$0.isHome }), groups.allSatisfy({ root, group in
            group.allSatisfy { original in
                restored.first(where: { $0.id == original.id }).map { $0.display == destinations[root] } ?? true
            }
        }) else { throw ScanError("应用任务尚未恢复，已保留临时屏幕，避免丢失应用状态。") }
        recovery?.appTasks?.removeAll(where: { $0.ownedDisplay == target })
        do { try save() }
        catch { recovery?.appTasks = recorded; throw error }
    }
    /// Restore every scanner task without releasing its reserved display or camera.
    func restoreScannerApplications() throws {
        guard let displayID, channel != nil, let state = recovery, state.display == displayID,
              state.valid, try ownedDevice(state) != nil else { throw ScanError("扫码屏幕不属于当前连接。") }
        try restoreTasks(on: displayID)
    }
    func closeAppDisplay(_ id: Int) throws {
        guard let channel, recovery?.appDisplays?.contains(where: { $0.id == id }) == true, let value = Int32(exactly: id) else { throw ScanError("应用屏幕不属于本次连接。") }
        try restoreTasks(on: id)
        var network = value.bigEndian
        let body = withUnsafeBytes(of: &network) { Data($0) }
        _ = try channel.request(12, body)
        recovery?.appDisplays?.removeAll(where: { $0.id == id })
        try save()
    }
    private func virtualRecords() throws -> [VirtualRecord] {
        let dump=try shell("dumpsys virtualdevice")
        guard let start=dump.range(of:"Created virtual devices:") else {
            throw ScanError("手机没有返回虚拟设备创建列表，已保留恢复记录。")
        }
        var created=String(dump[start.upperBound...])
        if let end=created.range(of:"VirtualDevice Log:") {created=String(created[..<end.lowerBound])}
        let blocks=created.components(separatedBy:"\n  VirtualDevice:").dropFirst()
        return try blocks.map { block in
            func value(_ key:String)->String? {
                block.split(separator:"\n").map { $0.trimmingCharacters(in:.whitespaces) }
                    .first(where:{$0.hasPrefix(key+":")})?
                    .dropFirst(key.count+1).trimmingCharacters(in:.whitespaces)
            }
            guard let device=Int(value("mDeviceId") ?? ""),
                  let association=Int(value("mAssociationId") ?? ""),
                  let owner=value("mOwnerPackageName") else {
                throw ScanError("手机虚拟设备列表格式无法核实，已保留恢复记录。")
            }
            return VirtualRecord(device:device,association:association,owner:owner)
        }
    }

    private func ownedDevice(_ state: Recovery) throws -> VirtualRecord? {
        let records=try virtualRecords()
        if let id=state.device, let record=records.first(where:{$0.device==id}) {
            guard record.owner=="com.android.shell",record.association==state.association else {
                throw ScanError("原虚拟设备编号现属于其他连接，已停止自动清理。")
            }
            return record
        }
        guard let association=state.association else {return nil}
        let matches=records.filter{$0.association==association && $0.owner=="com.android.shell"}
        guard matches.count<=1 else {throw ScanError("临时连接对应多个虚拟设备，已停止自动清理。")}
        if let match=matches.first,let id=state.device,id != match.device {
            throw ScanError("原虚拟设备编号已变化，已停止自动清理。")
        }
        return matches.first
    }

    private func associationPresent(_ state: Recovery) throws -> Bool {
        let rows=try shell("cmd companiondevice list 0").split(separator:"\n")
        let matches=rows.map{$0.split(separator:"|").map{$0.trimmingCharacters(in:.whitespaces)}}
            .filter{$0.count==3 && $0[1]=="com.android.shell" && $0[2].uppercased()==state.mac}
        guard matches.count<=1 else {throw ScanError("存在多个同名临时连接，已停止自动清理。")}
        if let row=matches.first,let expected=state.association,Int(row[0]) != expected {
            throw ScanError("临时连接编号不匹配，已停止自动清理。")
        }
        return !matches.isEmpty
    }

    private func processExists(_ pid:Int) throws -> Bool {
        try shell("if test -d /proc/\(pid); then printf yes; else printf no; fi")=="yes"
    }

    private func isOwnedProcess(_ pid:Int,_ state:Recovery) throws -> Bool {
        guard try processExists(pid) else {return false}
        let args=try shell("cat /proc/\(pid)/cmdline").split(separator:"\0").map(String.init)
        guard args.contains("LiveCameraServer"),args.contains(state.socketName),args.contains(state.token),
              state.association.map({args.contains(String($0))}) ?? false else {return false}
        let environment=try shell("cat /proc/\(pid)/environ").split(separator:"\0").map(String.init)
        return environment.contains("CLASSPATH=\(state.path)/server.jar")
    }

    private func findOwnedProcess(_ state:Recovery) throws -> Int? {
        if let pid=state.pid {return try isOwnedProcess(pid,state) ? pid : nil}
        // Old journals had no PID. Enumerate only candidate command lines, then
        // verify every argument and the exact CLASSPATH before any signal.
        let lines=try shell("ps -A -o PID,ARGS").split(separator:"\n")
        let candidates=lines.filter{$0.contains("LiveCameraServer") && $0.contains(state.socketName) && $0.contains(state.token)}
            .compactMap{$0.split(whereSeparator:{$0==" " || $0=="\t"}).first.flatMap{Int($0)}}
        let owned=try candidates.filter{try isOwnedProcess($0,state)}
        guard owned.count<=1 else {throw ScanError("发现多个相同会话进程，已停止自动清理。")}
        return owned.first
    }

    private func waitForOwnedProcessExit(_ pid:Int,_ state:Recovery,seconds:TimeInterval) throws -> Bool {
        let end=Date().addingTimeInterval(seconds)
        while Date()<end {
            if try !isOwnedProcess(pid,state) {return true}
            Thread.sleep(forTimeInterval:0.1)
        }
        return try !isOwnedProcess(pid,state)
    }

    private func waitForDeviceGone(_ state:Recovery,seconds:TimeInterval) throws -> Bool {
        let end=Date().addingTimeInterval(seconds)
        while Date()<end {
            if try ownedDevice(state)==nil {return true}
            Thread.sleep(forTimeInterval:0.15)
        }
        return try ownedDevice(state)==nil
    }

    /// Synchronous inside this actor so connect/quit cannot enter cleanup twice.
    func disconnect() -> String {
        cleanupStage="validateRecord"
        cleanupCameraStreamsBeforeSleep=nil;cleanupCameraClosureConfirmed=false;cleanupScannerBeforeSleep=false
        diagnosticLog=nil
        genericDesktopCamera=false
        independentApplicationsWhenLocked=false
        cleaning=true;defer {cleaning=false}
        if let state = recovery {
            do {
                guard state.valid else { throw ScanError("连接恢复记录无效。") }
                cleanupStage="verifyOwner"
                let owner = try shell("if test -d \(state.path); then cat \(state.path)/owner; else printf absent; fi")
                guard owner == state.token || owner == "absent" else { throw ScanError("手机会话标记不匹配。") }
                cleanupStage="verifyDevice"
                let owned=try ownedDevice(state)
                if owned != nil {
                    cleanupStage="verifyAssociation"
                    guard try associationPresent(state) else {
                        throw ScanError("本次虚拟设备的关联记录缺失，已保留会话。")
                    }
                    if let channel {
                        // No page navigation: the server sleeps its own retained
                        // VirtualDevice object, never a caller-supplied display ID.
                        // Cleanup deliberately continues after diagnostic cancellation.
                        cleanupStage="readCameraBeforeSleep"
                        let beforeSleep=try PhoneCameraState.decode(channel.request(5))
                        cleanupCameraStreamsBeforeSleep=beforeSleep.activeStreams
                        cleanupScannerBeforeSleep=beforeSleep.captureActivity() != nil
                        cleanupStage="sleepOwnedDevice"
                        let cameraPresent=try channel.request(24)
                        guard cameraPresent==Data([0]) || cameraPresent==Data([1]) else {
                            throw ScanError("手机未确认本次独立设备的休眠请求。")
                        }
                        if cameraPresent==Data([1]) {
                            cleanupStage="waitCameraClosure"
                            try OwnedCameraCleanup.quiesce(read:{try PhoneCameraState.decode(channel.request(5))})
                            cleanupCameraClosureConfirmed=true
                        }
                    }
                    cleanupStage="restoreTasks"
                    for display in state.appDisplays ?? [] { try restoreTasks(on: display.id) }
                    if let display = state.display { try restoreTasks(on: display) }
                }
            } catch { return "应用任务恢复失败，已保留连接与临时屏幕：" + error.localizedDescription }
        }
        cleanupStage="closeOwnedTransport"
        if let channel {_ = try? channel.request(9);channel.close()}
        channel=nil
        if let server,server.isRunning {
            let end=Date().addingTimeInterval(5)
            while server.isRunning && Date()<end {Thread.sleep(forTimeInterval:0.1)}
        }
        guard var state=recovery else {
            serverPipe?.fileHandleForReading.readabilityHandler=nil
            serverPipe=nil;server=nil;displayID=nil
            cleanupStage="complete"
            return ""
        }
        guard state.valid else {return "连接恢复记录无效，已停止自动清理。"}
        cleanupStage="recoverOwnedResources"
        do {
            // A mismatched owner marker makes both the directory and phone
            // association unsafe to touch, even if the old journal is valid.
            let owner=try shell("if test -d \(state.path); then cat \(state.path)/owner; else printf absent; fi")
            guard owner==state.token || owner=="absent" else {
                throw ScanError("手机临时目录的会话标记不匹配，已保留恢复记录。")
            }
            if let found=try ownedDevice(state),state.device==nil {
                state.device=found.device;recovery=state;try save()
            }
            if state.pid==nil,let found=try findOwnedProcess(state) {
                state.pid=found;recovery=state;try save()
            }
            if let pid=try findOwnedProcess(state) {
                // The local command may be hung after its remote service died.
                // Signal only an exact PID whose arguments and jar path match.
                _ = try shell("kill -TERM \(pid)")
                if try !waitForOwnedProcessExit(pid,state,seconds:3) {
                    guard try isOwnedProcess(pid,state) else {throw ScanError("进程身份已变化，已停止自动清理。")}
                    _ = try shell("kill -KILL \(pid)")
                    guard try waitForOwnedProcessExit(pid,state,seconds:2) else {
                        throw ScanError("本次手机进程尚未退出。")
                    }
                }
            }
            guard try waitForDeviceGone(state,seconds:4) else {
                throw ScanError("本次虚拟设备尚未关闭，已保留恢复记录。")
            }
            if try associationPresent(state) {
                _ = try shell("cmd companiondevice disassociate 0 com.android.shell \(state.mac)")
            }
            if owner != "absent" {
                _ = try shell("rm -f \(state.path)/server.jar \(state.path)/owner && rmdir \(state.path)")
            }
            if let port=state.port {_ = try? adb(["forward","--remove","tcp:\(port)"])}
            guard try ownedDevice(state)==nil,
                  try findOwnedProcess(state)==nil,
                  try !associationPresent(state),
                  try shell("if test -e \(state.path); then printf present; else printf absent; fi")=="absent" else {
                throw ScanError("手机临时资源未全部消失，已保留恢复记录。")
            }
            if let server,server.isRunning {server.terminate()}
            serverPipe?.fileHandleForReading.readabilityHandler=nil
            serverPipe=nil;server=nil;displayID=nil
            try FileManager.default.removeItem(at:recoveryURL)
            recovery=nil
            cleanupStage="complete"
            return ""
        } catch {
            return "清理未完成；请连接同一手机后再次点连接："+error.localizedDescription
        }
    }
}
