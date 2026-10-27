import Foundation

@main struct CancellationTests {
    static func main() async throws {
        let clock=Date()
        let command=Task.detached {try ShellCommand.run(URL(fileURLWithPath:"/bin/sleep"),["8"])}
        try await Task.sleep(nanoseconds:150_000_000)
        command.cancel()
        do {_ = try await command.value;fatalError("Expected cancellation")}
        catch is CancellationError {}
        guard Date().timeIntervalSince(clock)<3 else{fatalError("Command cancellation exceeded bound")}
        let serverLog=ServerLog(),started=Date()
        let waiter=Task.detached {try serverLog.waitReady()}
        try await Task.sleep(nanoseconds:150_000_000);waiter.cancel()
        do {_ = try await waiter.value;fatalError("Expected readiness cancellation")}
        catch is CancellationError {}
        guard Date().timeIntervalSince(started)<1 else{fatalError("Readiness cancellation exceeded bound")}
        let earlyExit=ServerLog(),exitStarted=Date()
        let exitWaiter=Task.detached {try earlyExit.waitReady()}
        earlyExit.finish()
        do {_ = try await exitWaiter.value;fatalError("Exited server accepted readiness")}
        catch {guard error.localizedDescription.contains("退出") else{throw error}}
        guard Date().timeIntervalSince(exitStarted)<1 else{fatalError("Exited server waited for full startup timeout")}
        for phase in ["virtual_device", "camera_policy", "virtual_camera", "camera_register", "camera_identifier", "camera_owner_watch", "owned_display", "session_channel"] {
            let phased = ServerLog()
            phased.append(Data("QR_LIVE setup_phase=\(phase)\n".utf8)); phased.finish()
            do { _ = try phased.waitReady(); fatalError("Exited staged server accepted readiness") }
            catch { guard let description = ServerLog.setupDescription(phase), error.localizedDescription.contains(description) else { throw error } }
        }
        guard ServerLog.setupDescription("untrusted raw text") == nil else { fatalError("Unknown phase echoed") }
        let readyThenEOF=ServerLog()
        readyThenEOF.append(Data("QR_LIVE device_id=7\nQR_LIVE display_id=9\nQR_LIVE pid=123\nQR_LIVE ready=1\n".utf8))
        readyThenEOF.finish()
        let ready=try readyThenEOF.waitReady()
        guard ready.0==7 && ready.1==9 && ready.2==123 else{fatalError("Buffered ready reply lost at EOF")}
        let cleanup=Task.detached {() throws -> String in
            try await Task.sleep(nanoseconds:100_000_000)
            return "unexpected"
        }
        cleanup.cancel();_ = try? await cleanup.value
        let canceledCleanup=Task.detached {() throws -> String in
            do {try await Task.sleep(nanoseconds:500_000_000)}catch{}
            return try ShellCommand.run(URL(fileURLWithPath:"/usr/bin/true"),[],cancellable:false)
        }
        canceledCleanup.cancel();_ = try await canceledCleanup.value
        let dump="""
        Display #0 (activities from top to bottom):
          topResumedActivity=ActivityRecord{abc u0 example.test/.Home t8}
        Display #7 (activities from top to bottom):
          topResumedActivity=ActivityRecord{def u0 com.tencent.mm/.plugin.scanner.ui.BaseScanUI t9}
        """
        guard PhoneSession.foregroundComponent(in:dump,display:7)=="com.tencent.mm/.plugin.scanner.ui.BaseScanUI",
              PhoneSession.foregroundComponent(in:dump,display:0)=="example.test/.Home",
              PhoneSession.foregroundComponent(in:dump,display:8)==nil else{fatalError("Foreground display isolation failed")}
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("phone-server-route-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fakeADB = directory.appendingPathComponent("fake-adb")
        try #"""
        #!/bin/sh
        route=default
        if [ "$1" = -L ]; then route="$2"; shift 2; fi
        [ "$1" = devices ] && [ "$2" = -l ] && [ "$#" = 2 ] || exit 21
        printf '%s' "$route" > "$0.route"
        printf 'List of devices attached\n'
        """#.write(to: fakeADB, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeADB.path)
        for route in [String?.none, "tcp:127.0.0.1:42139"] {
            let phone = PhoneSession(resources: directory, adbURL: fakeADB, serverSocket: route)
            do {
                _ = try await phone.connect(openWechatOnConnect: false, progress: { _ in })
                fatalError("Empty synthetic device list connected")
            } catch {
                guard error.localizedDescription.contains("未发现") else { throw error }
            }
            let actual = try String(contentsOfFile: fakeADB.path + ".route", encoding: .utf8)
            guard actual == (route ?? "default") else { fatalError("Phone enumeration crossed server routes") }
        }
        print("PASS command/readiness cancellation, cleanup after cancellation, display isolation, default/owned PhoneSession ADB routing")
    }
}
