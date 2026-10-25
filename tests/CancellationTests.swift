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
        print("PASS command/readiness cancellation, cleanup after cancellation, display isolation")
    }
}
