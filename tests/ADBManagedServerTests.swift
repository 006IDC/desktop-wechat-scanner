import Foundation
import Darwin

@main enum ADBManagedServerTests {
    static func require(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
    static func waitFor(_ file: URL) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: file.path) {
            guard Date() < deadline else { fatalError("Synthetic process did not start") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("managed-adb-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("adb"), pidFile = directory.appendingPathComponent("pid")
        func fixture(_ body: String) throws {
            try Data(("#!/bin/sh\n" + body).utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
        let startup = """
        [ "$1" = '-L' ] && [ "$2" = 'tcp:localhost:42001' ] && [ "$3" = 'server' ] || exit 11
        [ "$4" = 'nodaemon' ] && [ "$5" = '--reply-fd' ] && [ "$6" = '3' ] || exit 12
        [ "$ADB_USB" = 0 ] && [ "$ADB_EMU" = 0 ] && [ "$ADB_MDNS_AUTO_CONNECT" = 0 ] || exit 13
        printf '%s' "$$" > "$(dirname "$0")/pid"
        """
        try fixture(startup + "\nprintf 'OK\\n' >&3\nexec /bin/sleep 30\n")
        var server: ADBManagedServer? = try await .start(adbURL: executable, portProvider: { 42001 })
        let pid = Int32(try String(contentsOf: pidFile, encoding: .utf8))!
        require(server?.socket == "tcp:127.0.0.1:42001" && server?.isRunning == true, "Managed runtime was not ready")
        var slot: ADBWirelessServerHandoff? = ADBWirelessServerHandoff()
        require(slot?.take() == nil, "Handoff before cleanup succeeded")
        slot?.finish(with: server); server = nil
        require(kill(pid, 0) == 0, "Chooser slot did not retain selected runtime")
        let selected = slot?.take()
        require(slot?.take() == nil, "Runtime could be taken twice")
        slot = nil
        require(selected?.isRunning == true, "Transferred runtime died with chooser")
        await selected?.stop(); await selected?.stop()
        require(kill(pid, 0) == -1 && errno == ESRCH, "Transferred runtime did not stop/reap")

        server = try await .start(adbURL: executable, portProvider: { 42001 })
        let abandonedPID = Int32(try String(contentsOf: pidFile, encoding: .utf8))!
        slot = ADBWirelessServerHandoff(); slot?.finish(with: server); server = nil; slot = nil
        require(kill(abandonedPID, 0) == -1 && errno == ESRCH, "Untaken handoff leaked its process")

        try FileManager.default.removeItem(at: pidFile)
        try fixture(startup + "\nexec /bin/sleep 30\n")
        let pending = Task { try await ADBManagedServer.start(adbURL: executable, portProvider: { 42001 }) }
        try await waitFor(pidFile)
        let cancelledPID = Int32(try String(contentsOf: pidFile, encoding: .utf8))!
        pending.cancel()
        var cancelled = false
        do { _ = try await pending.value } catch is CancellationError { cancelled = true }
        require(cancelled, "Startup cancellation was not propagated")
        require(kill(cancelledPID, 0) == -1 && errno == ESRCH, "Cancelled startup left a process")

        try fixture(startup + "\nexec /bin/sleep 30\n")
        do { _ = try await ADBManagedServer.start(adbURL: executable, timeout: 0.1, portProvider: { 42001 }); fatalError("Timeout accepted") } catch {}
        let timedOutPID = Int32(try String(contentsOf: pidFile, encoding: .utf8))!
        require(kill(timedOutPID, 0) == -1 && errno == ESRCH, "Timed-out startup left a process")

        let progress = directory.appendingPathComponent("drained")
        try fixture(startup + """

        printf 'OK\\n' >&3
        i=0
        while [ "$i" -lt 20000 ]; do printf 'synthetic long-lived diagnostics that must not block stdout\\n'; i=$((i+1)); done
        printf 'done' > "$(dirname "$0")/drained"
        exec /bin/sleep 30
        """)
        server = try await .start(adbURL: executable, portProvider: { 42001 })
        try await waitFor(progress)
        require(server?.isRunning == true, "Long-lived log drain blocked or killed server")
        await server?.stop(); server = nil

        try fixture("""
        [ "$1" = '-L' ] && [ "$2" = 'tcp:127.0.0.1:42001' ] || exit 21
        shift 2
        case "$1" in
          devices) printf 'List of devices attached\\n192.0.2.10:30001 device model:Synthetic_Phone\\n' ;;
          connect) [ "$2" = '192.0.2.10:30001' ] || exit 22; printf 'connected to fixture\\n' ;;
          disconnect) [ "$2" = '192.0.2.10:30001' ] || exit 23; printf 'disconnected fixture\\n' ;;
          *) exit 24 ;;
        esac
        """)
        let manager = ADBConnectionManager(adbURL: executable, serverSocket: "tcp:127.0.0.1:42001")
        let devices = try await manager.devices()
        require(devices.count == 1 && devices[0].serverSocket == "tcp:127.0.0.1:42001", "Device lost its server route")
        let plain = ADBDevice(serial: devices[0].serial, model: nil, transport: .wireless, authorization: .authorized)
        require(plain.id != devices[0].id, "Distinct routes collided in device identity")
        try await manager.connect(endpoint: "192.0.2.10:30001")
        try await manager.disconnect(endpoint: "192.0.2.10:30001")
        print("PASS managed start/stop, cancellation/timeout, continuous drain, one-time selected handoff, abandoned cleanup and explicit command/device routes")
    }
}
