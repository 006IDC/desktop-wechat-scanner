import Foundation
import CoreVideo

/// One retained decoded frame, replacing older frames when presentation is slower.
final class MirrorVideoMailbox: @unchecked Sendable {
    struct Frame: @unchecked Sendable {
        let pixelBuffer:CVPixelBuffer
        let generation:Int
        /// Monotonic time at publication; suitable for display scheduling metrics.
        let receivedAt:TimeInterval
    }

    private let lock=NSLock()
    private var generation=0
    private var active=false
    private var pending:Frame?
    private var lastReceivedAt:TimeInterval?
    private var decodedObserver:(id:UUID,receive:@Sendable (CVPixelBuffer)->Void,invalidate:@Sendable ()->Void)?

    func reset(generation:Int) {
        lock.lock()
        let invalidate=decodedObserver?.invalidate
        self.generation=generation;active=true;pending=nil;lastReceivedAt=nil;decodedObserver=nil
        lock.unlock();invalidate?()
    }

    func publish(_ pixelBuffer:CVPixelBuffer,generation:Int) {
        lock.lock()
        guard active,self.generation==generation else{lock.unlock();return}
        pending=Frame(pixelBuffer:pixelBuffer,generation:generation,
                      receivedAt:ProcessInfo.processInfo.systemUptime)
        lastReceivedAt=pending?.receivedAt
        let observer=decodedObserver?.receive
        lock.unlock()
        // Never execute a consumer while holding the mailbox lock. The native
        // consumer owns a separate stop fence for callbacks already in flight.
        observer?(pixelBuffer)
    }

    /// One direct decoded-frame consumer, independent of the AppKit timer.
    /// It must be bounded/nonblocking and fence its own in-flight callbacks.
    func observeDecodedFrames(generation:Int,onInvalidated:@escaping @Sendable ()->Void={},
                              receive:@escaping @Sendable (CVPixelBuffer)->Void)->UUID? {
        lock.lock()
        guard active,self.generation==generation else{lock.unlock();return nil}
        let invalidate=decodedObserver?.invalidate
        let id=UUID();decodedObserver=(id,receive,onInvalidated)
        lock.unlock();invalidate?();return id
    }
    func hasDecodedFrameObserver(_ id:UUID,generation:Int)->Bool {
        lock.lock();defer{lock.unlock()}
        return active && self.generation==generation && decodedObserver?.id==id
    }
    func removeDecodedFrameObserver(_ id:UUID) {
        lock.lock();defer{lock.unlock()}
        if decodedObserver?.id==id {decodedObserver=nil}
    }

    func takeLatest() -> Frame? {
        lock.lock();defer{lock.unlock()}
        let frame=pending;pending=nil
        return frame
    }
    /// Survives taking the latest frame, but never a reset or stop. Readiness
    /// can require a decoded frame from the current launch instead of a blank
    /// frame that arrived while the virtual display was still empty.
    func receivedFrame(generation:Int,since time:TimeInterval)->Bool {
        lock.withLock{active && self.generation==generation && lastReceivedAt.map{$0>=time}==true}
    }

    func stop() {
        stop(ifGeneration:nil)
    }
    func stop(generation:Int) {
        stop(ifGeneration:generation)
    }
    private func stop(ifGeneration expected:Int?) {
        lock.lock()
        guard expected==nil || generation==expected else{lock.unlock();return}
        let invalidate=decodedObserver?.invalidate
        active=false;pending=nil;lastReceivedAt=nil;decodedObserver=nil
        lock.unlock();invalidate?()
    }
}
