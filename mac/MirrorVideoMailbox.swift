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

    func reset(generation:Int) {
        lock.lock();defer{lock.unlock()}
        self.generation=generation;active=true;pending=nil
    }

    func publish(_ pixelBuffer:CVPixelBuffer,generation:Int) {
        lock.lock();defer{lock.unlock()}
        guard active,self.generation==generation else{return}
        pending=Frame(pixelBuffer:pixelBuffer,generation:generation,
                      receivedAt:ProcessInfo.processInfo.systemUptime)
    }

    func takeLatest() -> Frame? {
        lock.lock();defer{lock.unlock()}
        let frame=pending;pending=nil
        return frame
    }

    func stop() {
        lock.lock();defer{lock.unlock()}
        active=false;pending=nil
    }
}
