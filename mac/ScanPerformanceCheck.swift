import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Opt-in diagnostic, started from the app menu. The only moved window is our
/// scanner. This exercises the production capture path, not synthesized input.
/// It measures application scheduling, not physical mouse-to-photon latency.
@MainActor final class ScanPerformanceCheck {
    nonisolated static let payload = "006IDC20261026PERF"
    let board: NSWindow
    private let pattern = ScanPerformancePattern()
    private var originalOrigin: NSPoint
    private var scanner: NSWindow
    private var lastStackingLevel:Int?
    private var center: NSPoint
    private var captureOffsetX: CGFloat
    private var started: TimeInterval?
    private var previousTick: TimeInterval?
    private var tickGaps: [Double] = []
    private var positionErrors: [Double] = []
    private var lastSampledSent=0
    private var syntheticQRVisible=false,movementMaximumGap=0.0
    private var movementSent=0
    private var movementDuration=0.0
    private var captureCosts:[Double]=[],transferCosts:[Double]=[]
    private var processingCosts:[Double]=[],requestCosts:[Double]=[],actorWaitCosts:[Double]=[],imageSizes:[Double]=[]
    private var sendCosts:[Double]=[],responseWaitCosts:[Double]=[],responseBodyCosts:[Double]=[]
    private var presentationCosts:[String:[Double]]=[:]
    private(set) var qrVisible = false
    private(set) var movedPoints: CGFloat = 0
    private let reduceMotion: Bool

    init(scanner: ControlWindowController) throws {
        guard let window = scanner.window, let screen = window.screen ?? NSScreen.main else {
            throw ScanError("扫码窗口尚未就绪。")
        }
        self.scanner = window; originalOrigin = window.frame.origin
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let visible = screen.visibleFrame
        let size = NSSize(width: min(820, visible.width), height: min(800, visible.height))
        let frame = NSRect(x: visible.midX-size.width/2, y: visible.midY-size.height/2,
                           width: size.width, height: size.height)
        pattern.prepareQR()
        board = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        board.isReleasedWhenClosed = false
        board.title = "扫码流畅度自检 · 合成图案"
        board.contentView = pattern
        board.collectionBehavior = [.canJoinAllApplications]
        // Before a scanner opens, the mirror is an ordinary window. A board
        // already at floating-1 would cover it and consume real pointer input.
        board.level=window.level
        board.order(.below,relativeTo:window.windowNumber)
        let capture = scanner.desktopCaptureRect
        captureOffsetX=capture.minX-window.frame.minX
        // Center QR in the actual transparent camera aperture, not in the whole phone.
        let aperture = ScanPreviewAperture.standard
        let openingCenter = NSPoint(x: capture.minX+capture.width*aperture.midX,
                                    y: capture.maxY-capture.height*aperture.midY)
        center = NSPoint(x: window.frame.minX + frame.midX-openingCenter.x,
                         y: window.frame.minY + frame.midY-openingCenter.y)
        window.setFrameOrigin(center)
        window.makeKeyAndOrderFront(nil)
    }

    func start(at time: TimeInterval) { started=time; previousTick=nil }

    /// Move the actual local framing window in the new product path. The
    /// synthetic board alone remains the capture source throughout the test.
    func bindLocalFrame(_ controller:ScanFrameController) {
        guard let window=controller.window else{return}
        scanner=window;originalOrigin=window.frame.origin
        lastStackingLevel=nil
        captureOffsetX=controller.captureRect.minX-window.frame.minX
        center=NSPoint(x:board.frame.midX-window.frame.width/2,
                       y:board.frame.midY-176)
        window.setFrameOrigin(center)
    }

    /// Called by the same common-mode presentation tick as the product camera.
    func tick(at now: TimeInterval) {
        synchronizeStacking()
        guard let started else { return }
        let elapsed=now-started
        if let previousTick, elapsed <= 6 { tickGaps.append((now-previousTick)*1000) }
        previousTick=now
        if elapsed < 6 {
            let amplitude: CGFloat = reduceMotion ? 0 : 60
            let x=center.x+amplitude*sin(elapsed*Double.pi)
            movedPoints=max(movedPoints,abs(x-center.x))
            scanner.setFrameOrigin(NSPoint(x:x,y:center.y))
            pattern.phase=elapsed
            pattern.needsDisplay=true
        } else if !qrVisible {
            scanner.setFrameOrigin(center)
            qrVisible=true; pattern.showQR=true; pattern.needsDisplay=true
        }
    }

    private func synchronizeStacking() {
        guard lastStackingLevel != scanner.level.rawValue else{return}
        lastStackingLevel=scanner.level.rawValue
        let desired=NSWindow.Level(rawValue:max(NSWindow.Level.normal.rawValue,scanner.level.rawValue-1))
        if board.level != desired {board.level=desired}
        // Same-level ordering matters before the phone's camera promotes the
        // scanner to floating. With different levels, the levels keep it below.
        if board.level == scanner.level {board.order(.below,relativeTo:scanner.windowNumber)}
        else if !board.isVisible {board.orderFront(nil)}
    }

    func recordCaptureRect(_ captureRect: CGRect, at now: TimeInterval) {
        guard let started else{return}
        if now-started > 0.2, now-started < 6, positionErrors.count < 600 {
            let expectedX=scanner.frame.minX+captureOffsetX
            positionErrors.append(abs(captureRect.minX-expectedX))
        }
    }

    /// Numeric-only opt-in timing of the UI work surrounding a presentation.
    /// Bounded to the six-second movement phase; no screen content is retained.
    func recordPresentation(_ stage:String,since began:TimeInterval) {
        let now=ProcessInfo.processInfo.systemUptime
        guard let started,now-started<=6,(presentationCosts[stage]?.count ?? 0)<600 else{return}
        presentationCosts[stage,default:[]].append(max(0,now-began)*1000)
    }

    func recordPump(_ stats:CameraPumpMailbox.Statistics,at now:TimeInterval) {
        syntheticQRVisible = syntheticQRVisible || stats.syntheticQRVisible
        guard let started,now-started<=6 else{return}
        movementMaximumGap=stats.maximumGapMilliseconds
        movementSent=stats.sent;movementDuration=now-started
        if stats.sent>0,stats.sent != lastSampledSent,captureCosts.count<600 {
            lastSampledSent=stats.sent
            captureCosts.append(stats.captureMilliseconds);transferCosts.append(stats.transferMilliseconds)
            if let processing=stats.phoneProcessingMilliseconds {processingCosts.append(processing)}
            requestCosts.append(stats.requestMilliseconds);actorWaitCosts.append(stats.actorWaitMilliseconds)
            sendCosts.append(stats.sendMilliseconds);responseWaitCosts.append(stats.responseWaitMilliseconds)
            responseBodyCosts.append(stats.responseBodyMilliseconds)
            imageSizes.append(Double(stats.imageBytes))
        }
    }

    func finish() -> [String: Any] {
        scanner.setFrameOrigin(originalOrigin)
        board.orderOut(nil); board.close()
        func percentile(_ values:[Double]) -> Double {
            let sorted=values.sorted()
            return sorted.isEmpty ? 0 : sorted[min(sorted.count-1,Int(Double(sorted.count)*0.95))]
        }
        let presentation=presentationCosts.mapValues { values in
            ["p95Milliseconds":percentile(values),"maxMilliseconds":values.max() ?? 0,"samples":Double(values.count)]
        }
        return ["test":"native-window-motion-and-synthetic-qr", "tickSamples":tickGaps.count,
                "presentationStages":presentation,
                "tickP95Milliseconds":percentile(tickGaps), "tickMaxMilliseconds":tickGaps.max() ?? 0,
                "roiPositionErrorP95Points":percentile(positionErrors),
                "movementSentFrames":movementSent,
                "movementMaximumSendGapMilliseconds":movementMaximumGap,
                "outgoingSyntheticQRVisible":syntheticQRVisible,
                "movementSendFPS":movementDuration>0 ? Double(movementSent)/movementDuration : 0,
                "movementCaptureP95Milliseconds":percentile(captureCosts),
                "movementTransferP95Milliseconds":percentile(transferCosts),
                "movementPhoneProcessingSamples":processingCosts.count,
                "movementPhoneProcessingP95Milliseconds":percentile(processingCosts),
                "movementRequestP95Milliseconds":percentile(requestCosts),
                "movementActorWaitP95Milliseconds":percentile(actorWaitCosts),
                "movementSendP95Milliseconds":percentile(sendCosts),
                "movementResponseWaitP95Milliseconds":percentile(responseWaitCosts),
                "movementResponseBodyP95Milliseconds":percentile(responseBodyCosts),
                "movementImageBytesP95":percentile(imageSizes),
                "movementAmplitudePoints":movedPoints, "reducedMotion":reduceMotion,
                "physicalMouseDragMeasured":false]
    }
}

private final class ScanPerformancePattern: NSView {
    var phase: Double = 0
    var showQR=false
    private lazy var qr: CGImage? = {
        let filter=CIFilter.qrCodeGenerator()
        filter.message=Data(ScanPerformanceCheck.payload.utf8); filter.correctionLevel="M"
        guard let output=filter.outputImage else{return nil}
        return CIContext().createCGImage(output,from:output.extent)
    }()
    func prepareQR() {_ = qr}
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill(); bounds.fill()
        let cell: CGFloat=32
        for y in stride(from:CGFloat(0),to:bounds.height,by:cell) {
            for x in stride(from:CGFloat(0),to:bounds.width,by:cell) {
                if (Int(x/cell)+Int(y/cell))%2 == 0 {
                    NSColor(calibratedRed:0.78,green:0.87,blue:0.96,alpha:1).setFill()
                    NSRect(x:x,y:y,width:cell,height:cell).fill()
                }
            }
        }
        if showQR,let qr,let context=NSGraphicsContext.current?.cgContext {
            let side: CGFloat=180
            let rect=NSRect(x:bounds.midX-side/2,y:bounds.midY-side/2,width:side,height:side)
            NSColor.white.setFill(); rect.insetBy(dx:-16,dy:-16).fill()
            context.saveGState();context.interpolationQuality = .none
            context.draw(qr,in:rect);context.restoreGState()
        } else {
            NSColor.systemBlue.setFill()
            NSRect(x:bounds.midX+120*sin(phase*Double.pi),y:0,width:8,height:bounds.height).fill()
        }
        let label=showQR ? "等待手机识别测试二维码" : "流畅度检查 · 窗口将自动往返移动"
        (label as NSString).draw(at:NSPoint(x:24,y:24),withAttributes:[.font:NSFont.systemFont(ofSize:18,weight:.medium),.foregroundColor:NSColor.black])
    }
}
