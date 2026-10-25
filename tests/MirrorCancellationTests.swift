import Foundation

@main struct MirrorCancellationTests {
    static func require(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
    static func main() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("006idc-mirror-cancel-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:directory)}
        let adb=directory.appendingPathComponent("fake-adb"),jar=directory.appendingPathComponent("empty.jar")
        // Only this local fixture runs: no adb server, Android device, or network service.
        try #"""
        #!/bin/sh
        route=default
        if [ "$1" = -L ]; then route="$2"; shift 2; fi
        [ "$1" = -s ] || exit 21
        serial="$2"; shift 2
        printf '%s|%s|%s\n' "$route" "$serial" "$*" >> "$0.commands"
        case "$1" in
          push)
            if [ "$(cat "$0.mode")" = push ]; then exec /bin/sleep 8; fi
            ;;
          forward)
            if [ "$2" = tcp:0 ]; then
              printf '%s' "$3" > "$0.forward"
              printf '1\n'
            elif [ "$2" = --list ]; then
              printf '%s tcp:1 %s\n' "$serial" "$(cat "$0.forward")"
            fi
            ;;
          shell)
            case "$2" in
              CLASSPATH=*) printf started > "$0.launched"; exec /bin/sleep 8 ;;
            esac
            ;;
          *) exit 22 ;;
        esac
        """#.write(to:adb,atomically:true,encoding:.utf8)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:adb.path)
        try Data().write(to:jar)
        // The executable uses its own exact prefix as fixture paths.
        let commandLog=URL(fileURLWithPath:adb.path+".commands")
        let fixtureMode=URL(fileURLWithPath:adb.path+".mode")
        let fixtureLaunched=URL(fileURLWithPath:adb.path+".launched")
        let mirror=MirrorSession()
        for (index, route) in [String?.none, "tcp:127.0.0.1:42137", "tcp:127.0.0.1:42138"].enumerated() {
            let waitForServer = index == 2
            try (waitForServer ? "server" : "push").write(to:fixtureMode,atomically:true,encoding:.utf8)
            try Data().write(to:commandLog)
            let start=Task {
                try await mirror.start(adbURL:adb,serverURL:jar,serial:"synthetic-device",displayID:0,serverSocket:route,onFrame:{_ in},onFailure:{_ in})
            }
            let ready=Date().addingTimeInterval(3)
            while Date()<ready {
                if waitForServer && FileManager.default.fileExists(atPath:fixtureLaunched.path) { break }
                if !waitForServer && (try? String(contentsOf:commandLog,encoding:.utf8).contains("|push ")) == true { break }
                try await Task.sleep(nanoseconds:10_000_000)
            }
            if waitForServer { require(FileManager.default.fileExists(atPath:fixtureLaunched.path), "Scrcpy process launch was not reached") }
            let began=Date()
            async let first:Void=mirror.stop()
            async let second:Void=mirror.stop()
            _=await(first,second)
            do {try await start.value;fatalError("Canceled mirror start succeeded")}
            catch { if !waitForServer { require(error is CancellationError, "Push cancellation did not propagate") } }
            require(Date().timeIntervalSince(began)<3,"Mirror cancellation exceeded bound")
            let commands=try String(contentsOf:commandLog,encoding:.utf8).split(separator:"\n").map(String.init)
            require(!commands.isEmpty && commands.allSatisfy { $0.hasPrefix((route ?? "default")+"|synthetic-device|") }, "ADB lifecycle crossed server routes")
            require(commands.contains { $0.contains("|shell rm -f /data/local/tmp/006idc-mirror-") }, "Remote cleanup was not routed")
            if waitForServer {
                require(commands.contains { $0.contains("|forward tcp:0 ") }, "Forward creation was not routed")
                require(commands.contains { $0.contains("|shell CLASSPATH=") }, "Long-lived process was not routed")
                require(commands.contains { $0.hasSuffix("|forward --list") } && commands.contains { $0.hasSuffix("|forward --remove tcp:1") }, "Owned forward cleanup was not routed")
            }
        }
        print("PASS default/owned ADB routes, forward/server/cleanup command scope, generation server isolation, interrupted push and concurrent stop")
    }
}
