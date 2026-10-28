import Foundation
import CoreVideo
import QuartzCore

/// A latest-only decoded slot with at most one calibration waiter. Rendering
/// reads synchronously; calibration suspends without polling the UI actor.
final class NativeScannerFrames:@unchecked Sendable {
    struct Sample:@unchecked Sendable {
        let revision:Int,pixels:CVPixelBuffer,receivedAt:TimeInterval
    }
    enum Failure:Error {case stopped,timedOut,concurrentWait,invalidWait}
    private final class Request:@unchecked Sendable {
        let id=UUID()
        // Accessed only under the owning slot's lock, including before install.
        var cancelled=false
    }
    private struct Waiter {
        let request:Request,after:Int,notBefore:TimeInterval
        let continuation:CheckedContinuation<Sample,Error>
    }
    private let lock=NSLock()
    private let clock:@Sendable ()->TimeInterval
    private var revision=0,pixels:CVPixelBuffer?,active=true,receivedAt=0.0
    private var waiter:Waiter?

    init(clock:@escaping @Sendable ()->TimeInterval={CACurrentMediaTime()}) {self.clock=clock}
    var hasWaiter:Bool {lock.withLock {waiter != nil}}
    func latest()->(Int,CVPixelBuffer?,Bool,Double) {lock.withLock {(revision,pixels,active,receivedAt)}}
    @discardableResult func publish(_ value:CVPixelBuffer)->Bool {
        lock.lock()
        guard active else{lock.unlock();return false}
        revision+=1;pixels=value;receivedAt=clock()
        let sample=Sample(revision:revision,pixels:value,receivedAt:receivedAt)
        var continuation:CheckedContinuation<Sample,Error>?
        if let pending=waiter,revision>pending.after,receivedAt>=pending.notBefore {
            continuation=pending.continuation;waiter=nil
        }
        lock.unlock()
        continuation?.resume(returning:sample)
        return true
    }
    func stop() {
        let pending=lock.withLock {()->CheckedContinuation<Sample,Error>? in
            active=false;pixels=nil
            let pending=waiter?.continuation;waiter=nil;return pending
        }
        pending?.resume(throwing:Failure.stopped)
    }
    /// The receipt gate preserves temporal sample spacing even when camera RPCs
    /// already consumed part of that interval. Timeout tasks are cancelled/joined.
    func wait(after:Int,notBefore:TimeInterval=0,timeout:TimeInterval) async throws -> Sample {
        guard after>=0,notBefore.isFinite,notBefore>=0,timeout.isFinite,timeout>0,timeout<=60 else {
            throw Failure.invalidWait
        }
        try Task.checkCancellation()
        let result=try await withThrowingTaskGroup(of:Sample.self) {group in
            group.addTask {try await self.waitForPublication(after:after,notBefore:notBefore)}
            group.addTask {
                try await Task.sleep(nanoseconds:UInt64(timeout*1_000_000_000))
                throw Failure.timedOut
            }
            defer {group.cancelAll()}
            return try await group.next()!
        }
        try Task.checkCancellation()
        guard lock.withLock({active}) else{throw Failure.stopped}
        return result
    }
    private func waitForPublication(after:Int,notBefore:TimeInterval) async throws -> Sample {
        let request=Request()
        return try await withTaskCancellationHandler(operation:{
            try await withCheckedThrowingContinuation {continuation in
                self.install(request,after:after,notBefore:notBefore,continuation:continuation)
            }
        },onCancel:{self.cancel(request)})
    }
    private func install(_ request:Request,after:Int,notBefore:TimeInterval,
                         continuation:CheckedContinuation<Sample,Error>) {
        lock.lock()
        let result:Result<Sample,Error>?
        if request.cancelled {result = .failure(CancellationError())}
        else if !active {result = .failure(Failure.stopped)}
        else if revision>after,receivedAt>=notBefore,let pixels {
            result = .success(Sample(revision:revision,pixels:pixels,receivedAt:receivedAt))
        } else if waiter != nil {result = .failure(Failure.concurrentWait)}
        else {
            waiter=Waiter(request:request,after:after,notBefore:notBefore,continuation:continuation)
            result=nil
        }
        lock.unlock()
        if let result {continuation.resume(with:result)}
    }
    private func cancel(_ request:Request) {
        let pending=lock.withLock {()->CheckedContinuation<Sample,Error>? in
            request.cancelled=true
            guard waiter?.request.id==request.id else{return nil}
            let pending=waiter?.continuation;waiter=nil;return pending
        }
        pending?.resume(throwing:CancellationError())
    }
}
