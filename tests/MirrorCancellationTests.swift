import Foundation

@main struct MirrorCancellationTests {
    static func main() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("006idc-mirror-cancel-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:directory)}
        let adb=directory.appendingPathComponent("fake-adb"),jar=directory.appendingPathComponent("empty.jar")
        // Simulate a stuck ADB push without touching an Android device.
        try "#!/bin/sh\nif [ \"$3\" = push ]; then exec /bin/sleep 8; fi\nexit 0\n".write(to:adb,atomically:true,encoding:.utf8)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:adb.path)
        try Data().write(to:jar)
        let mirror=MirrorSession()
        let start=Task {try await mirror.start(adbURL:adb,serverURL:jar,serial:"test-device",displayID:0,onFrame:{_ in},onFailure:{_ in})}
        try await Task.sleep(nanoseconds:250_000_000)
        let began=Date()
        async let first:Void=mirror.stop()
        async let second:Void=mirror.stop()
        _=await(first,second)
        do {try await start.value;fatalError("Canceled mirror start succeeded")}
        catch is CancellationError {}
        guard Date().timeIntervalSince(began)<3 else{fatalError("Mirror cancellation exceeded bound")}
        print("PASS GCD ADB push interrupted, concurrent stop awaited, canceled start completed")
    }
}
