import Foundation
import Darwin

// Local-only direct-video contract. The fake adb never contacts a device.
private final class DirectPeer: @unchecked Sendable {
    enum Mode { case success, wrongAck, holdAck }
    let port: UInt16
    private let listener: Int32
    private let lock = NSLock()
    private var recordedRoles = [UInt8]()
    private var failed = false, finished = false, sawClosure = false
    var roles: [UInt8] { lock.withLock { recordedRoles } }
    var isFinished: Bool { lock.withLock { finished } }
    var isFailed: Bool { lock.withLock { failed } }
    var videoHelloSeen: Bool { lock.withLock { !recordedRoles.isEmpty } }
    var closedByClient: Bool { lock.withLock { sawClosure } }

    init() throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ScanError("Fixture listener failed") }
        listener = fd
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        guard withUnsafePointer(to: &address, { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }) == 0, Darwin.listen(fd, 2) == 0 else {
            Darwin.close(fd); throw ScanError("Fixture bind failed")
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        port = UInt16(bigEndian: address.sin_port)
    }

    private func exact(_ fd: Int32, _ size: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: size), offset = 0
        while offset < size {
            let count = bytes.withUnsafeMutableBytes {
                Darwin.recv(fd, $0.baseAddress!.advanced(by: offset), size - offset, 0)
            }
            if count <= 0 { return nil }
            offset += count
        }
        return bytes
    }
    private func send(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeBytes {
                Darwin.send(fd, $0.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
            }
            if count <= 0 { return false }
            offset += count
        }
        return true
    }
    private func mark(role: UInt8) { lock.withLock { recordedRoles.append(role) } }
    private func closeObserved(_ value: Bool) { lock.withLock { sawClosure = value } }
    private func fail() { lock.withLock { failed = true } }

    func run(_ mode: Mode) {
        defer { Darwin.close(listener); lock.withLock { finished = true } }
        let video = Darwin.accept(listener, nil, nil)
        guard video >= 0 else { fail(); return }
        defer { Darwin.close(video) }
        guard let hello = exact(video, 33), hello[32] == 0,
              hello.prefix(32).allSatisfy({ $0 == 0x62 }) else { fail(); return }
        mark(role: hello[32])
        if mode == .holdAck {
            var byte: UInt8 = 0
            closeObserved(Darwin.recv(video, &byte, 1, 0) == 0)
            return
        }
        guard send(video, [mode == .wrongAck ? 1 : 0]) else { fail(); return }
        if mode == .wrongAck { return }
        // The production receiver should accept an H.264 marker and its
        // virtual-display session header without requiring scrcpy metadata.
        guard send(video, [0x68, 0x32, 0x36, 0x34, 0x80, 0, 0, 0,
                           0, 0, 5, 0, 0, 0, 2, 0xd0]) else { fail(); return }
        let control = Darwin.accept(listener, nil, nil)
        guard control >= 0 else { fail(); return }
        defer { Darwin.close(control) }
        guard let controlHello = exact(control, 33), controlHello[32] == 1,
              controlHello.prefix(32).allSatisfy({ $0 == 0x62 }) else { fail(); return }
        mark(role: controlHello[32])
        guard send(control, [0]) else { fail(); return }
        var byte: UInt8 = 0
        closeObserved(Darwin.recv(video, &byte, 1, 0) == 0)
    }
    func start(_ mode: Mode) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in run(mode) }
    }
}

@main enum DirectMirrorTests {
    static func require(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
    static func waitUntil(_ condition: @escaping () -> Bool, seconds: TimeInterval = 4) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else { throw ScanError("Fixture timed out") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    private static func run(_ mode: DirectPeer.Mode, in directory: URL) async throws {
        let peer = try DirectPeer()
        let adb = directory.appendingPathComponent("fake-adb")
        let commands = URL(fileURLWithPath: adb.path + ".commands")
        let active = URL(fileURLWithPath: adb.path + ".active")
        let portFile = URL(fileURLWithPath: adb.path + ".port")
        try String(peer.port).write(to: portFile, atomically: true, encoding: .utf8)
        try Data().write(to: commands)
        try? FileManager.default.removeItem(at: active)
        peer.start(mode)
        let mirror = MirrorSession()
        let descriptor = DirectMirrorDescriptor(display: 7,
            socket: "006idc_video_" + String(repeating: "a", count: 32),
            token: String(repeating: "b", count: 32), width: 1280, height: 720)
        let started = Task {
            try await mirror.startVideo(adbURL: adb,
                serverURL: directory.appendingPathComponent("nonexistent-scrcpy.jar"),
                serial: "synthetic-device", displayID: 7,
                serverSocket: "tcp:127.0.0.1:42001", direct: descriptor,
                onFrame: { _ in }, onFailure: { _ in })
        }
        if mode == .holdAck {
            try await waitUntil({ peer.videoHelloSeen })
            let before = Date()
            await mirror.stop()
            require(Date().timeIntervalSince(before) < 3, "Stop did not interrupt pending authentication")
            do { try await started.value; fatalError("Stopped handshake succeeded") } catch { }
        } else if mode == .wrongAck {
            do { try await started.value; fatalError("Wrong ACK accepted") } catch { }
        } else {
            try await started.value
            await mirror.stop()
        }
        try await waitUntil({ peer.isFinished })
        require(!peer.isFailed, "Local peer saw malformed authentication")
        require(peer.roles == (mode == .success ? [0, 1] : [0]), "Direct roles were not authenticated in order")
        if mode != .wrongAck { require(peer.closedByClient, "Stop did not close the video socket") }
        let log = try String(contentsOf: commands, encoding: .utf8).split(separator: "\n").map(String.init)
        require(log.allSatisfy { $0.hasPrefix("tcp:127.0.0.1:42001|synthetic-device|") }, "ADB command escaped owned route")
        require(log.contains { $0.contains("|forward tcp:0 localabstract:") }, "Direct forward not created")
        require(log.contains { $0.hasSuffix("|forward --list") } &&
                log.contains { $0.hasSuffix("|forward --remove tcp:\(peer.port)") }, "Direct forward not exactly removed")
        require(!log.contains { $0.contains("|push ") || $0.contains("|shell ") }, "Direct route launched scrcpy or removed a remote jar")
        require(!FileManager.default.fileExists(atPath: active.path), "Direct forward remained active")
    }
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("006idc-direct-mirror-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let adb = directory.appendingPathComponent("fake-adb")
        try #"""
        #!/bin/sh
        route=default
        if [ "$1" = -L ]; then route="$2"; shift 2; fi
        [ "$1" = -s ] || exit 21
        serial="$2"; shift 2
        printf '%s|%s|%s\n' "$route" "$serial" "$*" >> "$0.commands"
        case "$1" in
          forward)
            if [ "$2" = tcp:0 ]; then
              printf '%s' "$3" > "$0.target"
              : > "$0.active"
              cat "$0.port"
            elif [ "$2" = --list ]; then
              if [ -f "$0.active" ]; then printf '%s tcp:%s %s\n' "$serial" "$(cat "$0.port")" "$(cat "$0.target")"; fi
            elif [ "$2" = --remove ]; then
              [ "$3" = "tcp:$(cat "$0.port")" ] || exit 23
              rm "$0.active"
            fi
            ;;
          push|shell) exit 90 ;;
          *) exit 22 ;;
        esac
        """#.write(to: adb, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: adb.path)
        try await run(.success, in: directory)
        try await run(.wrongAck, in: directory)
        try await run(.holdAck, in: directory)
        print("PASS direct video/control authentication, rejected ACK, interrupted handshake, exact owned-forward cleanup, no scrcpy launch or remote delete")
    }
}
