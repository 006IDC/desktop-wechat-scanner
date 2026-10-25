import Foundation
import Darwin

@main enum ADBConfigurationTests {
    static func require(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
    static func rejects(_ body: () throws -> Void, _ message: String) {
        do { try body(); fatalError(message) } catch {}
    }
    static func main() async throws {
        let valid="Android Debug Bridge version 1.0.41\nVersion 36.0.0-13206524\nInstalled as /example/adb\nRunning on Darwin 24.0.0"
        require(ADBConfiguration.isADBVersion(valid), "Official ADB response rejected")
        for invalid in ["", "Version 36.0.0", "Android Debug Bridge version hello\nVersion 36.0.0", "other executable\n"+valid, "Android Debug Bridge version 1.0.41"] {
            require(!ADBConfiguration.isADBVersion(invalid), "Unrelated version response accepted")
        }
        let home=URL(fileURLWithPath:"/synthetic-home")
        let paths=ADBConfiguration.candidates(savedPath:"/opt/homebrew/bin/adb",home:home).map(\.path)
        require(paths == ["/opt/homebrew/bin/adb","/usr/local/bin/adb","/synthetic-home/Library/Android/sdk/platform-tools/adb"], "Candidate order or deduplication changed")
        require(ADBConfiguration.candidates(savedPath:"/custom/adb",home:home).first?.path == "/custom/adb", "Saved choice not preferred")
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("adb-tests-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let adb=directory.appendingPathComponent("adb"), other=directory.appendingPathComponent("other")
        // The only executed fixture prints synthetic version text; no device or daemon commands.
        let script="#!/bin/sh\nprintf '%s\\n' 'Android Debug Bridge version 1.0.41' 'Version 36.0.0-13206524'\n"
        try Data(script.utf8).write(to:adb)
        rejects({ _=try ADBConfiguration.validate(adb,version:{ _ in fatalError("Non-executable was run") }) },"Non-executable accepted")
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:adb.path)
        require(try ADBConfiguration.validate(adb,version:{ _ in valid }) == adb, "Valid path not retained")
        rejects({ _=try ADBConfiguration.validate(adb,version:{ _ in "not adb" }) }, "Unrelated executable accepted")
        try Data(script.utf8).write(to:other)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:other.path)
        rejects({ _=try ADBConfiguration.validate(other,version:{ _ in fatalError("Wrong filename was run") }) }, "Wrong filename accepted")
        let fakeDirectory=directory.appendingPathComponent("sub/adb")
        try FileManager.default.createDirectory(at:fakeDirectory,withIntermediateDirectories:true)
        rejects({ _=try ADBConfiguration.validate(fakeDirectory,version:{ _ in fatalError("Directory was run") }) }, "Directory accepted")
        require(try await ADBConfiguration.validateAsync(adb) == adb, "Background version check failed")
        require(try await ADBConfiguration.discover(savedPath:nil) == nil, "First connection discovered an unselected executable")
        require(try await ADBConfiguration.discover(savedPath:"") == nil, "Empty choice discovered an unselected executable")
        require(try await ADBConfiguration.discover(savedPath:adb.path) == adb, "Saved selection not revalidated")

        // exec replaces the shell with sleep, so cancellation owns exactly one
        // child PID and cannot leave a shell descendant behind.
        let blockingScript="#!/bin/sh\nprintf '%s' \"$$\" > \"$0.pid\"\nexec /bin/sleep 30\n"
        try Data(blockingScript.utf8).write(to:adb)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:adb.path)
        let pidFile=URL(fileURLWithPath:adb.path+".pid")
        let validation=Task { try await ADBConfiguration.validateAsync(adb) }
        let started=Date()
        while !FileManager.default.fileExists(atPath:pidFile.path),Date().timeIntervalSince(started)<3 {
            try await Task.sleep(nanoseconds:20_000_000)
        }
        guard let pidText=try? String(contentsOf:pidFile,encoding:.utf8),let pid=Int32(pidText) else {
            validation.cancel();_=try? await validation.value
            fatalError("Blocking fixture did not start")
        }
        defer { if kill(pid,0)==0 { _=kill(pid,SIGKILL) } }
        let cancelledAt=Date()
        validation.cancel()
        var wasCancelled=false
        do { _=try await validation.value } catch is CancellationError { wasCancelled=true } catch {}
        let elapsed=Date().timeIntervalSince(cancelledAt)
        let stopDeadline=Date().addingTimeInterval(2)
        while kill(pid,0)==0,Date()<stopDeadline { try await Task.sleep(nanoseconds:20_000_000) }
        let stopped=kill(pid,0) == -1 && errno == ESRCH
        if !stopped { _=kill(pid,SIGKILL) }
        require(wasCancelled,"Version cancellation did not return CancellationError")
        require(elapsed<3,"Version cancellation waited for its timeout")
        require(stopped,"Cancelled ADB fixture remained alive")
        try FileManager.default.removeItem(at:adb)
        rejects({ _=try ADBConfiguration.validate(adb,version:{ _ in fatalError("Missing path was run") }) }, "Removed selection accepted")
        require(try await ADBConfiguration.discover(savedPath:adb.path) == nil, "Removed saved choice discovered another executable")
        print("PASS ADB response, chooser hints, explicit saved choice only, file preflight, async version and cancellation with child exit, removed selection")
    }
}
