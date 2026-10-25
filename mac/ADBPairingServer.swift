import Foundation
import Darwin

/// One pairing operation owns one foreground server and process group. The
/// private fd-3 ACK is emitted by AOSP only after its listener is installed;
/// connecting to a random open port is deliberately not a readiness test.
enum ADBPairingServer {
    typealias PortProvider = @Sendable () throws -> UInt16
    static func run(_ executable: URL, timeout: TimeInterval, cancellation: ADBCommandCancellation,
                    portProvider: PortProvider = { try availablePort() },
                    environment suppliedEnvironment: [String: String]? = nil,
                    pair: (String, [String: String], TimeInterval, @escaping @Sendable () -> Bool) throws -> String) throws -> String {
        let deadline = ProcessInfo.processInfo.systemUptime + min(19, timeout)
        var environment = suppliedEnvironment ?? ProcessInfo.processInfo.environment
        // A pairing-only server must not contend for the default server's USB
        // devices or automatically establish unrelated device transports.
        environment["ADB_USB"] = "0"; environment["ADB_EMU"] = "0"
        environment["ADB_MDNS_AUTO_CONNECT"] = "0"
        environment["ADB_TRACE"] = ""
        environment["ANDROID_LOG_TAGS"] = "*:s"
        environment["ANDROID_ADB_LOG_PATH"] = "/dev/null"
        environment.removeValue(forKey: "ADB_SERVER_SOCKET")
        environment.removeValue(forKey: "ANDROID_ADB_SERVER_ADDRESS")
        environment.removeValue(forKey: "ANDROID_ADB_SERVER_PORT")
        let port = try portProvider()
        guard port > 0, port != 5037 else { throw unavailable }
        let socket = "tcp:127.0.0.1:\(port)"
        // Pinned AOSP accepts "localhost" for an IPv4 loopback listener, but
        // rejects a numeric IPv4 listen spec. The client intentionally uses
        // numeric 127.0.0.1: AOSP treats that as a remote-host spec and refuses
        // to auto-start a background daemon if our foreground server dies.
        let server = try OwnedServer(executable: executable, socket: "tcp:localhost:\(port)", environment: environment)
        defer { server.stop() }
        try server.waitUntilReady(deadline: deadline, cancellation: cancellation)
        if cancellation.isCancelled { throw CancellationError() }
        guard server.isRunning else { throw unavailable }
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw unavailable }
        return try pair(socket, environment, remaining, { server.checkAlive() })
    }

    private static var unavailable: ADBConnectionError {
        ADBConnectionError("无法启动本次配对的独立 ADB 服务，请重试。现有 USB 连接未被停止。")
    }

    static func availablePort() throws -> UInt16 {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw unavailable }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { throw unavailable }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard result == 0, address.sin_port != 0 else { throw unavailable }
        // Reservation release can race another binder. Only the owned server's
        // ACK below authorizes sending a pairing code, never a TCP probe.
        return UInt16(bigEndian: address.sin_port)
    }

    private final class OwnedServer: @unchecked Sendable {
        private let pid: pid_t
        private let acknowledgement: Int32
        private let diagnostics: Int32
        private var stopped = false

        init(executable: URL, socket: String, environment: [String: String]) throws {
            var ack = [Int32](repeating: -1, count: 2), log = [Int32](repeating: -1, count: 2)
            guard pipe(&ack) == 0 else { throw unavailable }
            guard pipe(&log) == 0 else { Darwin.close(ack[0]); Darwin.close(ack[1]); throw unavailable }
            let null = open("/dev/null", O_RDONLY)
            guard null >= 0 else {
                for descriptor in ack + log { Darwin.close(descriptor) }
                throw unavailable
            }
            defer { Darwin.close(null); Darwin.close(ack[1]); Darwin.close(log[1]) }
            for descriptor in ack + log + [null] { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }
            var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
            posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
            defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
            posix_spawn_file_actions_adddup2(&actions, null, STDIN_FILENO)
            posix_spawn_file_actions_adddup2(&actions, log[1], STDOUT_FILENO)
            posix_spawn_file_actions_adddup2(&actions, log[1], STDERR_FILENO)
            // AOSP rejects stdin/stdout/stderr as --reply-fd. dup2 clears
            // close-on-exec for this explicit child-only descriptor, including
            // under POSIX_SPAWN_CLOEXEC_DEFAULT.
            posix_spawn_file_actions_adddup2(&actions, ack[1], 3)
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
            posix_spawnattr_setpgroup(&attributes, 0)
            let arguments = [executable.path, "-L", socket, "server", "nodaemon", "--reply-fd", "3"]
            let argumentPointers = arguments.map { strdup($0) } + [nil]
            let environmentPointers = environment.sorted(by: { $0.key < $1.key }).map { strdup($0.key + "=" + $0.value) } + [nil]
            defer { argumentPointers.forEach { free($0) }; environmentPointers.forEach { free($0) } }
            var child: pid_t = 0
            let result = argumentPointers.withUnsafeBufferPointer { argv in
                environmentPointers.withUnsafeBufferPointer { envp in
                    posix_spawn(&child, executable.path, &actions, &attributes,
                                UnsafeMutablePointer(mutating: argv.baseAddress!), UnsafeMutablePointer(mutating: envp.baseAddress!))
                }
            }
            guard result == 0 else { Darwin.close(ack[0]); Darwin.close(log[0]); throw unavailable }
            pid = child; acknowledgement = ack[0]; diagnostics = log[0]
            _ = fcntl(acknowledgement, F_SETFL, O_NONBLOCK)
            _ = fcntl(diagnostics, F_SETFL, O_NONBLOCK)
        }

        var isRunning: Bool {
            // WNOWAIT preserves the child PID until group cleanup: it cannot
            // be reused for an unrelated process before we signal the group.
            var information = siginfo_t()
            guard waitid(P_PID, id_t(pid), &information, WEXITED | WNOHANG | WNOWAIT) == 0 else { return false }
            return information.si_pid == 0
        }

        func checkAlive() -> Bool { drainDiagnostics(); return isRunning }

        func waitUntilReady(deadline: TimeInterval, cancellation: ADBCommandCancellation) throws {
            var ack = Data()
            while ProcessInfo.processInfo.systemUptime < deadline {
                if cancellation.isCancelled { throw CancellationError() }
                drainDiagnostics()
                var bytes = [UInt8](repeating: 0, count: 16)
                let count = Darwin.read(acknowledgement, &bytes, bytes.count)
                if count > 0 { ack.append(contentsOf: bytes.prefix(count)) }
                guard isRunning else { throw unavailable }
                if ack == Data("OK\n".utf8) { return }
                guard ack.count <= 3 else { throw unavailable }
                Thread.sleep(forTimeInterval: 0.01)
            }
            throw unavailable
        }

        private func drainDiagnostics() {
            // No diagnostic text is retained or emitted; ADB tracing is also
            // disabled so RPC contents cannot become an adb.log artifact.
            var bytes = [UInt8](repeating: 0, count: 4096)
            for _ in 0..<16 { if Darwin.read(diagnostics, &bytes, bytes.count) <= 0 { break } }
        }

        func stop() {
            guard !stopped else { return }
            stopped = true
            _ = kill(-pid, SIGTERM)
            let deadline = ProcessInfo.processInfo.systemUptime + 0.3
            while isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                drainDiagnostics(); Thread.sleep(forTimeInterval: 0.01)
            }
            // This is only our posix_spawn-created group. Kill descendants
            // before reaping its leader, even when the leader already exited.
            _ = kill(-pid, SIGKILL)
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            drainDiagnostics()
            Darwin.close(acknowledgement); Darwin.close(diagnostics)
        }
    }
}
