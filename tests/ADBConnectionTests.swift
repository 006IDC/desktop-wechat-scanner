import Foundation
import Darwin

@main enum ADBConnectionTests {
    static func require(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
    static func rejects(_ input: String) {
        do { _ = try ADBEndpoint(input); fatalError("Invalid endpoint accepted") } catch {}
    }
    static func main() async throws {
        for value in ["192.0.2.10:37123", "phone.local:65535", "localhost:1", "[2001:db8::1]:37123", "[::1]:3"] {
            require(try ADBEndpoint(value).value == value, "Valid endpoint changed")
        }
        for value in ["", "host", "host:0", "host:65536", "host:-1", "host:+123", "host:1\n", "host:1;echo", "-host:123", "host :12", "https://host:123", "host:12/path", "2001:db8::1:123", "[::bad::]:123", "[::1]:", "1.2.3.999:123", "host..local:123", "$(x):123", "host:１２３"] { rejects(value) }
        let devices = ADBConnectionManager.parseDevices("""
        * daemon started successfully
        List of devices attached
        synthetic-usb device usb:1-2 product:fixture model:Test_Phone transport_id:1
        192.0.2.10:37123 device product:fixture model:WiFi_Phone transport_id:2
        adb-fixture._adb-tls-connect._tcp offline transport_id:3
        synthetic-denied unauthorized usb:1-3 transport_id:4
        synthetic-recovery recovery usb:1-4
        malformed
        synthetic-usb device usb:1-2
        """)
        require(devices.count == 5, "Enumeration lost or duplicated devices")
        require(devices[0].transport == .usb && devices[0].model == "Test Phone" && devices[0].authorization == .authorized, "USB metadata incorrect")
        require(devices[1].transport == .wireless && devices[2].transport == .wireless, "TLS wireless devices unrecognized")
        require(devices[2].authorization == .offline && devices[3].authorization == .unauthorized && devices[4].authorization == .unavailable, "Authorization states incorrect")
        let services = ADBConnectionManager.parseServices("""
        List of discovered mdns services
        fixture-pair _adb-tls-pairing._tcp. 192.0.2.10:30001
        fixture-connect _adb-tls-connect._tcp. [2001:db8::1]:30002
        fixture-pair _adb-tls-pairing._tcp. 192.0.2.10:30001
        fixture-legacy _adb._tcp. 192.0.2.10:5555
        fixture-invalid _adb-tls-connect._tcp. host:0
        """)
        require(services.count == 2 && services[0].kind == .pairing && services[1].kind == .connection, "mDNS service filtering incorrect")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("adb-connection-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("adb")
        func fixture(_ body: String) throws {
            try Data(("#!/bin/sh\n" + body).utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
        func pairingFixture(_ body: String, server: String = "printf 'OK\\n' >&3\nexec /bin/sleep 30\n") throws {
            try fixture("""
            [ "$1" = '-L' ] || exit 31
            case "$2" in tcp:127.0.0.1:*|tcp:localhost:*) ;; *) exit 32 ;; esac
            [ "$2" != 'tcp:127.0.0.1:5037' ] && [ "$2" != 'tcp:localhost:5037' ] || exit 33
            socket="$2"
            shift 2
            if [ "$1" = 'server' ]; then
              case "$socket" in tcp:localhost:*) ;; *) exit 37 ;; esac
              [ "$2" = 'nodaemon' ] && [ "$3" = '--reply-fd' ] && [ "$4" = '3' ] || exit 34
              [ "$ADB_USB" = '0' ] && [ "$ADB_EMU" = '0' ] && [ -z "$ADB_TRACE" ] || exit 35
              printf '%s' "$$" > "$0.server.pid"
              \(server)
              exit 36
            fi
            case "$socket" in tcp:127.0.0.1:*) ;; *) exit 38 ;; esac
            \(body)
            """)
        }
        // No real adb, devices, network access or pairing secrets are used.
        try fixture("""
        case "$1" in
          pair)
            [ "$#" = 2 ] && [ "$2" = '192.0.2.10:30001' ] || exit 8
            IFS= read -r code
            [ "$code" = '012345' ] || exit 9
            printf 'Successfully paired to 192.0.2.10:30001\\n'
            ;;
          connect)
            [ "$#" = 2 ] && [ "$2" = '[2001:db8::1]:30002' ] || exit 10
            printf '* daemon started successfully\\nconnected to [2001:db8::1]:30002\\n'
            ;;
          disconnect)
            [ "$#" = 2 ] && [ "$2" = '[2001:db8::1]:30002' ] || exit 11
            printf 'disconnected [2001:db8::1]:30002\\n'
            ;;
          devices) printf 'List of devices attached\\nsynthetic-usb device usb:1-2 model:Test_Phone\\n' ;;
          mdns) printf 'fixture _adb-tls-connect._tcp. 192.0.2.10:30002\\n' ;;
          *) exit 12 ;;
        esac
        """)
        // Fake server never binds a socket. Inject a synthetic port so these
        // subprocess lifecycle tests require no network entitlement at all.
        let manager = ADBConnectionManager(adbURL: executable, pairingPortProvider: { 42001 })
        try await manager.connect(endpoint: "[2001:db8::1]:30002")
        try await manager.disconnect(endpoint: "[2001:db8::1]:30002")
        require(try await manager.devices().count == 1, "Process enumeration failed")
        require(try await manager.discover().count == 1, "Process discovery failed")

        try pairingFixture("""
        [ "$1" = 'pair' ] && [ "$#" = 2 ] && [ "$2" = '192.0.2.10:30001' ] || exit 40
        IFS= read -r code
        [ "$code" = '012345' ] || exit 41
        printf 'Successfully paired to 192.0.2.10:30001\\n'
        """)
        try await manager.pair(endpoint: "192.0.2.10:30001", code: "012345")
        let serverPID = Int32(try String(contentsOf: URL(fileURLWithPath: executable.path + ".server.pid"), encoding: .utf8))!
        require(kill(serverPID, 0) == -1 && errno == ESRCH, "Successful pairing left its owned server alive")

        // stdout/stderr and nonzero failures must never surface echoed input.
        try pairingFixture("IFS= read -r code\nprintf 'echoed %s\\n' \"$code\" >&2\nexit 1\n")
        do { try await manager.pair(endpoint: "192.0.2.10:30001", code: "012345"); fatalError("Pair failure accepted") }
        catch { require(!error.localizedDescription.contains("012345"), "Pairing code leaked into an error") }
        try fixture("printf 'failed to connect to fixture\\n'\n")
        do { try await manager.connect(endpoint: "192.0.2.10:30002"); fatalError("ADB zero-status failure accepted") } catch {}
        try pairingFixture("printf 'not a valid pair response\\n'\n")
        do { try await manager.pair(endpoint: "192.0.2.10:30001", code: "012345"); fatalError("Pair response not checked") } catch {}
        do { try await manager.pair(endpoint: "192.0.2.10:30001", code: "12\n345"); fatalError("Invalid code accepted") } catch {}

        let secretMarker = URL(fileURLWithPath: executable.path + ".pair-called")
        try pairingFixture("printf 'called' > \"$0.pair-called\"\n", server: "printf 'not-owned\\n' >&3\nexec /bin/sleep 30\n")
        do { try await manager.pair(endpoint: "192.0.2.10:30001", code: "012345"); fatalError("Missing owned ACK accepted") } catch {}
        require(!FileManager.default.fileExists(atPath: secretMarker.path), "Pairing code could reach a server without owned readiness ACK")

        try pairingFixture("printf '%s' \"$$\" > \"$0.client.pid\"\nexec /bin/sleep 30\n")
        let pairing = Task { try await manager.pair(endpoint: "192.0.2.10:30001", code: "012345") }
        let clientPIDFile = URL(fileURLWithPath: executable.path + ".client.pid")
        let pairStartup = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: clientPIDFile.path), Date() < pairStartup { try await Task.sleep(nanoseconds: 10_000_000) }
        let clientPID = Int32(try String(contentsOf: clientPIDFile, encoding: .utf8))!
        let cancelledServerPID = Int32(try String(contentsOf: URL(fileURLWithPath: executable.path + ".server.pid"), encoding: .utf8))!
        pairing.cancel()
        var pairingCancelled = false
        do { try await pairing.value } catch is CancellationError { pairingCancelled = true }
        require(pairingCancelled, "Isolated pairing cancellation did not propagate")
        require(kill(clientPID, 0) == -1 && errno == ESRCH, "Cancelled pairing client not reaped")
        require(kill(cancelledServerPID, 0) == -1 && errno == ESRCH, "Cancelled pairing server not reaped")

        let unrelated = Process()
        unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep"); unrelated.arguments = ["30"]
        try unrelated.run()
        defer { if unrelated.isRunning { unrelated.terminate(); unrelated.waitUntilExit() } }
        try pairingFixture("printf 'Successfully paired to fixture\\n'\n", server: """
        trap '' TERM
        /bin/sleep 30 &
        printf '%s' "$!" > "$0.descendant.pid"
        printf 'OK\\n' >&3
        wait
        """)
        try await manager.pair(endpoint: "192.0.2.10:30001", code: "012345")
        let descendant = Int32(try String(contentsOfFile: executable.path + ".descendant.pid", encoding: .utf8))!
        let descendantDeadline = Date().addingTimeInterval(2)
        while kill(descendant, 0) == 0, Date() < descendantDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
        require(kill(descendant, 0) == -1 && errno == ESRCH, "Owned server descendant survived cleanup")
        require(unrelated.isRunning, "Cleanup signalled an unrelated process")

        try pairingFixture("IFS= read -r code && printf 'called' > \"$0.pair-called\"\n", server: "printf 'OK\\n' >&3\nexit 0\n")
        do { try await manager.pair(endpoint: "192.0.2.10:30001", code: "012345"); fatalError("Dead owned server accepted") } catch {}
        require(!FileManager.default.fileExists(atPath: secretMarker.path), "Pairing input was sent after owned server exited")

        try pairingFixture("printf 'called' > \"$0.pair-called\"\n", server: "exec /bin/sleep 30\n")
        let shortPairing = ADBConnectionManager(adbURL: executable, timeout: 0.1, pairingPortProvider: { 42001 })
        do { try await shortPairing.pair(endpoint: "192.0.2.10:30001", code: "012345"); fatalError("Server startup timeout accepted") } catch {}
        let timedOutServer = Int32(try String(contentsOfFile: executable.path + ".server.pid", encoding: .utf8))!
        require(kill(timedOutServer, 0) == -1 && errno == ESRCH, "Server startup timeout left a process")
        require(!FileManager.default.fileExists(atPath: secretMarker.path), "Startup timeout sent pairing input")

        // exec gives the fixture exactly one child PID. Ignore TERM to verify
        // forced exit plus reaping, for both cancellation and timeout.
        let pidFile = URL(fileURLWithPath: executable.path + ".pid")
        try fixture("printf '%s' \"$$\" > \"$0.pid\"\ntrap '' TERM\nexec /bin/sleep 30\n")
        let task = Task { try await manager.devices() }
        let startup = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: pidFile.path), Date() < startup { try await Task.sleep(nanoseconds: 10_000_000) }
        let pid = Int32(try String(contentsOf: pidFile, encoding: .utf8))!
        defer { if kill(pid, 0) == 0 { _ = kill(pid, SIGKILL) } }
        let cancelledAt = Date()
        task.cancel()
        var cancelled = false
        do { _ = try await task.value } catch is CancellationError { cancelled = true }
        require(cancelled, "Cancellation did not propagate")
        require(Date().timeIntervalSince(cancelledAt) < 3, "Cancellation did not stop promptly")
        require(kill(pid, 0) == -1 && errno == ESRCH, "Cancelled child was not reaped")
        let shortManager = ADBConnectionManager(adbURL: executable, timeout: 0.1)
        do { _ = try await shortManager.devices(); fatalError("Timeout did not fail") } catch {}
        let timeoutPID = Int32(try String(contentsOf: pidFile, encoding: .utf8))!
        require(kill(timeoutPID, 0) == -1 && errno == ESRCH, "Timed-out child was not reaped")

        print("PASS endpoint validation, USB/TLS enumeration, mDNS, exact command scope, isolated foreground pairing, stdin-only code, owned ACK, redacted failures, cancellation/timeout and owned group cleanup")
    }
}
