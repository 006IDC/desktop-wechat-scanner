import Foundation

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
        try FileManager.default.removeItem(at:adb)
        rejects({ _=try ADBConfiguration.validate(adb,version:{ _ in fatalError("Missing path was run") }) }, "Removed selection accepted")
        print("PASS ADB response, saved candidate priority, file preflight, async synthetic version, removed selection")
    }
}
