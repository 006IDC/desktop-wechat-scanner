import Foundation

/// Main-thread geometry publication and background pump metrics. No image data is
/// queued here: the worker always selects the newest ROI after the previous ACK.
final class CameraPumpMailbox: @unchecked Sendable {
    struct Statistics: Sendable {
        var sent=0,dropped=0
        var firstFrameAcknowledgedAt:TimeInterval?
        var syntheticQRVisible=false
        var localQRSubmitted=false
        var localSubmission:Selection?
        var imageBytes=0
        var phoneProcessingMilliseconds:Double?
        var requestMilliseconds=0.0,actorWaitMilliseconds=0.0
        var sendMilliseconds=0.0,responseWaitMilliseconds=0.0,responseBodyMilliseconds=0.0
        var fps=0.0,captureMilliseconds=0.0,transferMilliseconds=0.0,maximumGapMilliseconds=0.0
    }
    struct Snapshot {
        let statistics:Statistics
        let failure:Error?
    }
    struct Selection:Sendable {
        let target:DesktopCaptureTarget
        let revision:UInt64
    }
    private let sourceIsAvailable:@Sendable ()->Bool
    init(sourceIsAvailable:@escaping @Sendable ()->Bool = {true}) {self.sourceIsAvailable=sourceIsAvailable}
    private var admitsFrames:Bool {active && sourceIsAvailable()}
    private let lock=NSLock()
    private var active=true
    private var target:DesktopCaptureTarget?
    private var statistics=Statistics()
    private var failure:Error?
    private var captureNotBefore:TimeInterval=0
    private var revision:UInt64=0
    func delayCapture(until time:TimeInterval) {
        lock.lock();defer{lock.unlock()}
        if admitsFrames {captureNotBefore=time;revision &+= 1}
    }
    /// The untouched first generic region is already stationary. An earlier
    /// drag/retry fence, or any previously selected region, still requires settling.
    func prepareRegion(at time:TimeInterval,immediateFirst:Bool) {
        lock.lock();defer{lock.unlock()}
        guard admitsFrames else{return}
        let untouched=target==nil && captureNotBefore==0
        captureNotBefore=max(captureNotBefore,time+(immediateFirst && untouched ? 0:0.18))
        revision &+= 1
    }
    func captureReady(at time:TimeInterval)->Bool {
        lock.lock();defer{lock.unlock()}
        return admitsFrames && time>=captureNotBefore
    }
    func publish(_ value:DesktopCaptureTarget) {
        lock.lock();defer{lock.unlock()}
        if admitsFrames {
            if target?.rect != value.rect || target?.displayID != value.displayID ||
                target?.screenFrame != value.screenFrame || target?.pixelSize != value.pixelSize {revision &+= 1}
            target=value
        }
    }
    func selection()->Selection? {
        lock.lock();defer{lock.unlock()}
        return admitsFrames ? target.map{Selection(target:$0,revision:revision)}:nil
    }
    func isCurrent(_ selection:Selection)->Bool {
        lock.lock();defer{lock.unlock()}
        return admitsFrames && target != nil && revision==selection.revision
    }
    func canHandoff(at time:TimeInterval)->Bool {
        lock.lock();defer{lock.unlock()}
        return admitsFrames && statistics.localQRSubmitted &&
            statistics.localSubmission?.revision==revision && time>=captureNotBefore
    }
    func latest() -> DesktopCaptureTarget? {
        lock.lock();defer{lock.unlock()}
        return admitsFrames ? target:nil
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
