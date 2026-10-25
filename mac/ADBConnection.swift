import Foundation
import Darwin

struct ADBDevice: Identifiable, Equatable, Sendable {
    enum Transport: String, Sendable { case usb, wireless, unknown }
    enum Authorization: String, Sendable { case authorized, unauthorized, offline, unavailable }
    let serial: String
    let model: String?
    let transport: Transport
    let authorization: Authorization
    var id: String { serial }
}

struct ADBDiscoveredService: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case pairing, connection }
    let name: String
    let endpoint: String
    let kind: Kind
    var id: String { kind.rawValue + ":" + name + ":" + endpoint }
}

struct ADBConnectionError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

/// An explicit host and port. Only this validated value reaches adb argv.
/// IPv6 requires brackets; URLs, implicit ports and shell syntax are rejected.
struct ADBEndpoint: Equatable, Sendable {
    let value: String
    init(_ input: String) throws {
        let host: String, portText: String
        if input.hasPrefix("["), let close = input.firstIndex(of: "]") {
            host = String(input[input.index(after: input.startIndex)..<close])
            let suffix = input[input.index(after: close)...]
            guard suffix.hasPrefix(":"), !host.isEmpty else { throw Self.invalid }
            portText = String(suffix.dropFirst())
            var address = in6_addr()
            guard host.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { throw Self.invalid }
        } else {
            let parts = input.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2 else { throw Self.invalid }
            host = String(parts[0]); portText = String(parts[1])
            guard !host.isEmpty, host.utf8.count <= 253 else { throw Self.invalid }
            let labels = host.split(separator: ".", omittingEmptySubsequences: false)
            guard labels.allSatisfy({ label in
                !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" &&
                label.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
            }) else { throw Self.invalid }
            // Numeric dotted addresses must be real IPv4, not ambiguous hostnames.
            if host.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }) {
                var address = in_addr()
                guard host.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else { throw Self.invalid }
            }
        }
        guard !portText.isEmpty, portText.utf8.allSatisfy({ (48...57).contains($0) }),
              let port = UInt16(portText), port > 0 else { throw Self.invalid }
        value = host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }
    private static var invalid: ADBConnectionError { ADBConnectionError("请输入手机显示的地址和端口，例如 192.168.1.20:37123 或 [IPv6]:37123。") }
}

/// Uses the user's already validated adb. No tcpip command, default port,
/// global disconnect or automatic pairing is performed. Android/ADB persist trust
/// after an explicit pair; the app never persists the one-time pairing code.
actor ADBConnectionManager {
    private let adbURL: URL
    private let timeout: TimeInterval
    private let pairingPortProvider: ADBPairingServer.PortProvider
    init(adbURL: URL, timeout: TimeInterval = 15,
         pairingPortProvider: @escaping ADBPairingServer.PortProvider = { try ADBPairingServer.availablePort() }) {
        self.adbURL = adbURL
        self.timeout = timeout.isFinite && timeout > 0 ? timeout : 15
        self.pairingPortProvider = pairingPortProvider
    }

    func devices() async throws -> [ADBDevice] {
        Self.parseDevices(try await run(["devices", "-l"]))
    }

    func pair(endpoint: String, code: String) async throws {
        let endpoint = try ADBEndpoint(endpoint)
        guard code.utf8.count == 6, code.utf8.allSatisfy({ (48...57).contains($0) }) else {
            throw ADBConnectionError("请输入手机当前显示的六位配对码。")
        }
        // adb prompts on stdin when the code argument is omitted. Never pass
        // the secret in argv, errors, logs, defaults or a temporary file.
        let cancellation = ADBCommandCancellation()
        let executable = adbURL, timeout = min(timeout, 20), portProvider = pairingPortProvider
        let task = Task.detached(priority: .userInitiated) {
            try ADBPairingServer.run(executable, timeout: timeout, cancellation: cancellation, portProvider: portProvider) { socket, environment, remaining, owner in
                try ADBConnectionProcess.run(executable, ["-L", socket, "pair", endpoint.value],
                                             input: Data((code + "\n").utf8), timeout: remaining,
                                             cancellation: cancellation, environment: environment, owner: owner)
            }
        }
        let response = try await withTaskCancellationHandler(operation: {
            let value = try await task.value
            try Task.checkCancellation()
            return value
        }, onCancel: { cancellation.cancel() })
        guard response.contains("Successfully paired to ") else {
            throw ADBConnectionError("无线配对未成功。请保持手机配对窗口打开，核对配对端口和最新配对码。")
        }
    }

    func connect(endpoint: String) async throws {
        let endpoint = try ADBEndpoint(endpoint)
        let response = try await run(["connect", endpoint.value])
        guard response.split(whereSeparator: \.isNewline).contains(where: {
            $0.hasPrefix("connected to ") || $0.hasPrefix("already connected to ")
        }) else {
            throw ADBConnectionError("无线连接未成功。请使用无线调试主页的连接端口，并确认手机和 Mac 在同一网络。")
        }
    }

    func disconnect(endpoint: String) async throws {
        let endpoint = try ADBEndpoint(endpoint)
        let response = try await run(["disconnect", endpoint.value])
        guard response.split(whereSeparator: \.isNewline).contains(where: { $0.hasPrefix("disconnected ") }) else {
            throw ADBConnectionError("此无线连接未断开，请刷新设备列表检查连接状态。")
        }
    }

    /// Optional mDNS discovery. Callers can fall back to manual entry on error.
    func discover() async throws -> [ADBDiscoveredService] {
        Self.parseServices(try await run(["mdns", "services"]))
    }

    static func parseDevices(_ output: String) -> [ADBDevice] {
        var seen = Set<String>()
        return output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 2, !line.hasPrefix("List of devices"), !line.hasPrefix("*"),
                  ["device", "unauthorized", "offline", "recovery", "sideload", "bootloader", "no"].contains(fields[1]),
                  seen.insert(fields[0]).inserted else { return nil }
            let authorization: ADBDevice.Authorization
            switch fields[1] {
            case "device": authorization = .authorized
            case "unauthorized": authorization = .unauthorized
            case "offline": authorization = .offline
            default: authorization = .unavailable
            }
            let serial = fields[0]
            let transport: ADBDevice.Transport
            if fields.contains(where: { $0.hasPrefix("usb:") }) { transport = .usb }
            else if (try? ADBEndpoint(serial)) != nil || serial.contains("._adb-tls-connect._tcp") { transport = .wireless }
            else { transport = .unknown }
            let model = fields.first(where: { $0.hasPrefix("model:") }).map { String($0.dropFirst(6)).replacingOccurrences(of: "_", with: " ") }
            return ADBDevice(serial: serial, model: model, transport: transport, authorization: authorization)
        }
    }

    static func parseServices(_ output: String) -> [ADBDiscoveredService] {
        var seen = Set<String>()
        return output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count == 3, let endpoint = try? ADBEndpoint(fields[2]) else { return nil }
            let kind: ADBDiscoveredService.Kind
            switch fields[1].trimmingCharacters(in: CharacterSet(charactersIn: ".")) {
            case "_adb-tls-pairing._tcp": kind = .pairing
            case "_adb-tls-connect._tcp": kind = .connection
            default: return nil
            }
            let service = ADBDiscoveredService(name: fields[0], endpoint: endpoint.value, kind: kind)
            return seen.insert(service.id).inserted ? service : nil
        }
    }

    private func run(_ arguments: [String], input: Data? = nil) async throws -> String {
        let cancellation = ADBCommandCancellation()
        let executable = adbURL, timeout = timeout
        let task = Task.detached(priority: .userInitiated) {
            try ADBConnectionProcess.run(executable, arguments, input: input, timeout: timeout, cancellation: cancellation)
        }
        return try await withTaskCancellationHandler(operation: {
            let result = try await task.value
            try Task.checkCancellation()
            return result
        }, onCancel: { cancellation.cancel() })
    }
}

final class ADBCommandCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

private final class ADBCommandOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var overflow = false
    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        if data.count + chunk.count > 262_144 { overflow = true }
        else { data.append(chunk) }
    }
    func result() throws -> String {
        lock.lock(); defer { lock.unlock() }
        guard !overflow else { throw ADBConnectionError("ADB 返回内容过长，请重试。") }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

enum ADBConnectionProcess {
    static func run(_ executable: URL, _ arguments: [String], input: Data?, timeout: TimeInterval,
                    cancellation: ADBCommandCancellation, environment: [String: String]? = nil,
                    owner: (@Sendable () -> Bool)? = nil) throws -> String {
        if cancellation.isCancelled { throw CancellationError() }
        guard owner?() != false else { throw ADBConnectionError("本次配对的独立 ADB 服务已退出，请重试。") }
        let process = Process(), output = Pipe(), stdin = Pipe()
        let done = DispatchSemaphore(value: 0), readerDone = DispatchSemaphore(value: 0)
        let buffer = ADBCommandOutput()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = output; process.standardError = output
        process.standardInput = stdin
        // A child can reject the command before reading its stdin. Avoid
        // SIGPIPE taking down the app if that happens during pairing.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() }
        catch { throw ADBConnectionError("无法启动所选 ADB，请重新选择 Google Platform-Tools 中的 adb。") }
        // Drain continuously so a full stdout pipe cannot prevent child exit.
        DispatchQueue.global(qos: .userInitiated).async {
            while true {
                let chunk = output.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
            }
            readerDone.signal()
        }
        // At most seven bytes for pairing; never retain or expose child output
        // on an error because some adb versions may echo the pairing input.
        if let input, owner?() != false { try? stdin.fileHandleForWriting.write(contentsOf: input) }
        try? stdin.fileHandleForWriting.close()
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var finished = false
        while !cancellation.isCancelled && owner?() != false && ProcessInfo.processInfo.systemUptime < deadline {
            if done.wait(timeout: .now() + 0.025) == .success { finished = true; break }
        }
        if !finished {
            if process.isRunning { process.terminate() }
            if done.wait(timeout: .now() + 0.3) == .timedOut, process.isRunning { kill(process.processIdentifier, SIGKILL) }
            // Reap before returning; a cancelled connection command cannot run
            // later and connect a device behind the user's back.
            process.waitUntilExit()
            _ = readerDone.wait(timeout: .now() + 1)
            if cancellation.isCancelled { throw CancellationError() }
            throw ADBConnectionError("ADB 连接操作超时，请检查手机无线调试和网络后重试。")
        }
        process.waitUntilExit()
        guard readerDone.wait(timeout: .now() + 1) == .success else {
            throw ADBConnectionError("读取 ADB 响应超时，请重试。")
        }
        if cancellation.isCancelled { throw CancellationError() }
        guard process.terminationStatus == 0 else {
            throw ADBConnectionError("ADB 操作失败。请核对手机无线调试、地址、端口及授权后重试。")
        }
        return try buffer.result()
    }
}
