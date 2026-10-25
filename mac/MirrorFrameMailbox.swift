import Foundation
import CoreGraphics

/// A single pending preview shared by the decoder and the AppKit display tick.
/// The decoder never enqueues UI work; a newer frame replaces the pending frame.
final class MirrorFrameMailbox: @unchecked Sendable {
    struct Frame: @unchecked Sendable {
        let image:CGImage
        let generation:Int
        /// Monotonic arrival time, for measuring decoder-to-display scheduling delay.
        let receivedAt:TimeInterval
    }

    private let lock=NSLock()
    private var generation=0
    private var active=false
    private var pending:Frame?

    /// Begin a mirror generation and discard any unconsumed previous frame.
    /// The owner uses a fresh generation for each start, including after stop().
    func reset(generation:Int) {
        lock.lock();defer{lock.unlock()}
        self.generation=generation;active=true;pending=nil
    }

    func publish(_ image:CGImage,generation:Int) {
        lock.lock();defer{lock.unlock()}
        guard active,self.generation==generation else{return}
        pending=Frame(image:image,generation:generation,receivedAt:ProcessInfo.processInfo.systemUptime)
    }

    /// Atomically take the newest pending frame; a second take returns nil until publish.
    func takeLatest() -> Frame? {
        lock.lock();defer{lock.unlock()}
        let frame=pending;pending=nil
        return frame
    }

    /// Drop the pending frame and reject even current-generation callbacks until reset.
    func stop() {
        lock.lock();defer{lock.unlock()}
        active=false;pending=nil
    }
}
