import Foundation

/// Owns optional metadata preparation, never screen frames. Foreground work must
/// drain this owner before using the same capture actor. Starts during draining
/// are rejected, and concurrent finishers await the same retired job.
@MainActor final class CaptureMetadataWarmup {
    private final class Job {
        let task:Task<Bool,Never>
        init(prepare:@escaping @Sendable () async throws -> Void) {
            task=Task.detached(priority:.utility) {
                do {try Task.checkCancellation();try await prepare();try Task.checkCancellation();return true}
                catch {return false}
            }
        }
    }
    private var pending:Job?,draining:Job?
    private var foregroundDepth=0
    func start(allowed:Bool,prepare:@escaping @Sendable () async throws -> Void) {
        guard allowed,foregroundDepth==0,pending==nil,draining==nil else{return}
        pending=Job(prepare:prepare)
    }
    @discardableResult func finish() async -> Bool {
        guard let job=draining ?? pending else{return false}
        if draining==nil {pending=nil;draining=job;job.task.cancel()}
        let prepared=await job.task.value
        if draining === job {draining=nil}
        return prepared
    }
    /// Keep background starts closed after the drain and across every await in
    /// foreground prepare/clear/board-swap work, including nested operations.
    func withForeground<T>(_ operation:(Bool) async throws -> T) async rethrows -> T {
        foregroundDepth+=1;defer{foregroundDepth-=1}
        let prepared=await finish()
        return try await operation(prepared)
    }
    deinit {pending?.task.cancel();draining?.task.cancel()}
}
