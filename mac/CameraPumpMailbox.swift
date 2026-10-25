import Foundation

/// Main-thread geometry publication and background pump metrics. No image data is
/// queued here: the worker always selects the newest ROI after the previous ACK.
final class CameraPumpMailbox: @unchecked Sendable {
    struct Statistics: Sendable {
        var sent=0,dropped=0
        var fps=0.0,captureMilliseconds=0.0,transferMilliseconds=0.0,maximumGapMilliseconds=0.0
    }
    struct Snapshot {
        let statistics:Statistics
        let failure:Error?
    }
    private let lock=NSLock()
    private var active=true
    private var target:DesktopCaptureTarget?
    private var statistics=Statistics()
    private var failure:Error?
    func publish(_ value:DesktopCaptureTarget) {
        lock.lock();defer{lock.unlock()}
        if active {target=value}
    }
    func latest() -> DesktopCaptureTarget? {
        lock.lock();defer{lock.unlock()}
        return active ? target:nil
    }
    func update(_ value:Statistics) {
        lock.lock();defer{lock.unlock()}
        if active {statistics=value}
    }
    func fail(_ error:Error) {
        lock.lock();defer{lock.unlock()}
        guard active else{return}
        active=false;target=nil;failure=error
    }
    func stop() {
        lock.lock();defer{lock.unlock()}
        active=false;target=nil;failure=nil
    }
    func snapshot()->Snapshot {
        lock.lock();defer{lock.unlock()}
        return Snapshot(statistics:statistics,failure:failure)
    }
}
