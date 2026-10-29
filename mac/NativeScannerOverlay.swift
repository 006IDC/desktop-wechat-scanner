import AppKit
import CoreImage
import CoreVideo
import QuartzCore

/// Opt-in native-camera presentation. The product owns capture/epoch/cleanup;
/// this object only calibrates the verified scanner and renders original pixels.
@MainActor final class NativeScannerOverlay {
    private let frames=NativeScannerFrames()
    private var decodedBinding:(mailbox:MirrorVideoMailbox,id:UUID,generation:Int)?
    var decodedFrameDelivery:Bool {
        guard let binding=decodedBinding else{return false}
        return binding.mailbox.hasDecodedFrameObserver(binding.id,generation:binding.generation)
    }
    private var displayDriver:NativeMetalDisplayDriver?
    var presentationClock:String {displayDriver == nil ? "notStarted":"metalDisplayLink"}
    private var identity:(Int,Int)?
    private let display:Int,package:String
    private let fastCalibration:Bool
    private let batchedCalibration:Bool
    private let solidCalibrationEnabled:Bool
    let displaySyncEnabled:Bool
    let layer=CAMetalLayer()
    let statistics=NativeMattePresentationStats()
    private(set) var frozen=false
    private var hidesCalibrationFrames=false
    private var renderFailure:String?
    var failure:String? {
        if decodedBinding != nil,!decodedFrameDelivery {return "原生视频会话已变化。"}
        return renderFailure
    }
    private(set) var calibrationTiming=[String:Double]()
    enum EndReason:String {case cleared,scannerStateChanged,windowHidden,pumpFailure,qrHandoff,returnedToApplication,pausedByControl}
    private(set) var termination=[String:Any]()
    func noteEnd(_ reason:EndReason) {if termination.isEmpty {termination["reason"]=reason.rawValue}}
    func noteStateChange(_ state:PhoneCameraState) {
        guard termination.isEmpty else{return}
        noteEnd(.scannerStateChanged)
        termination["scannerStillVerified"]=state.scannerActivity() != nil
        termination["sameGeneration"]=identity?.0==state.generation
        termination["sameOwnerGeneration"]=identity?.1==state.ownerGeneration
        termination["activeStreams"]=state.activeStreams
        let activity=state.activities.first {$0.displayId==display}
        termination["ownedDisplayHasActivity"]=activity != nil
        termination["sameApplicationOnOwnedDisplay"]=activity?.component.hasPrefix(package+"/") ?? false
    }
    func notePumpFailure(_ error:Error) {
        guard termination.isEmpty else{return}
        noteEnd(.pumpFailure)
        let value=error as NSError
        termination["errorDomain"]=value.domain.hasPrefix("com.apple.") || value.domain=="NSPOSIXErrorDomain" ? value.domain:"application_error"
        termination["errorCode"]=value.code
        if let transient=error as? DesktopCaptureTransientError {
            switch transient {
            case .frameExpired:termination["transient"]=1
            case .frameNotReady:termination["transient"]=2
            case .encodingBusy:termination["transient"]=3
            }
        }
    }
    private func recordFailure() {renderFailure="原生扫码显示中断。"}
    init(display:Int,package:String,fastCalibration:Bool=false,batchedCalibration:Bool=false,solidCalibrationEnabled:Bool=true,displaySyncEnabled:Bool=true) {
        self.display=display;self.package=package;self.fastCalibration=fastCalibration || batchedCalibration
        self.batchedCalibration=batchedCalibration
        self.solidCalibrationEnabled=solidCalibrationEnabled
        self.displaySyncEnabled=displaySyncEnabled
    }
    /// Show genuine black-background frames during calibration, so opening the
    /// Android scanner keeps its own animation. Hide only the blue-key phase.
    func receive(_ pixels:CVPixelBuffer)->Bool {
        if decodedBinding == nil,frames.publish(pixels) {statistics.received(at:ProcessInfo.processInfo.systemUptime)}
        return hidesCalibrationFrames || frozen
    }
    /// Bind only after the caller verified the exact mirror display/incarnation.
    /// Capture the thread-safe frame slot, never this MainActor UI object.
    func observeDecodedFrames(in mailbox:MirrorVideoMailbox,generation:Int) throws {
        guard decodedBinding == nil,!frozen else{throw ScanError("原生视频已绑定或停止。")}
        let input=frames,statistics=statistics
        guard let id=mailbox.observeDecodedFrames(generation:generation,onInvalidated:{input.stop()},receive:{pixels in
            if input.publish(pixels) {statistics.received(at:ProcessInfo.processInfo.systemUptime)}
        }) else{throw ScanError("原生视频会话已变化。")}
        decodedBinding=(mailbox,id,generation)
    }
    func matches(_ state:PhoneCameraState)->Bool {
        guard let scanner=state.scannerActivity(),scanner.displayId==display,scanner.package==package else{return false}
        return identity.map {$0 == (state.generation,state.ownerGeneration)} ?? true
    }
    @discardableResult
    private func requireCurrent(_ phone:PhoneSession) async throws -> PhoneCameraState {
        try Task.checkCancellation()
        if decodedBinding != nil,!decodedFrameDelivery {throw ScanError("原生视频会话已变化。")}
        let state=try await phone.cameraState()
        try Task.checkCancellation()
        if decodedBinding != nil,!decodedFrameDelivery {throw ScanError("原生视频会话已变化。")}
        guard matches(state) else{throw ScanError("原生扫码状态已变化，已停止校准。")}
        if identity == nil {identity=(state.generation,state.ownerGeneration)}
        return state
    }
    private nonisolated static func background(blue:Bool) throws -> Data {
        try NativeCalibrationImages.image(blue:blue)
    }
    private func sendCalibrationBackground(blue:Bool,phone:PhoneSession,epoch:Int,solid:Bool) async throws -> CameraFrameReceipt {
        if solid {
            return try await phone.solidCalibrationFrame(blue:blue,epoch:epoch)
        } else {
            let image=try await Task.detached {try Self.background(blue:blue)}.value
            return try await phone.frame(image,epoch:epoch)
        }
    }
    private func nextCalibrationFrame(after:Int,notBefore:TimeInterval=0,
                                      deadline:TimeInterval) async throws -> NativeScannerFrames.Sample {
        do {
            let remaining=deadline-CACurrentMediaTime()
            guard remaining>0 else{throw NativeScannerFrames.Failure.timedOut}
            return try await frames.wait(after:after,notBefore:notBefore,timeout:remaining)
        } catch NativeScannerFrames.Failure.stopped {throw CancellationError()}
        catch NativeScannerFrames.Failure.concurrentWait {throw ScanError("原生扫码校准状态已变化。")}
        catch NativeScannerFrames.Failure.timedOut {throw ScanError("原生扫码校准未收到新画面。")}
    }
    private nonisolated static func isBlue(_ pixels:CVPixelBuffer)->Bool {
        guard CVPixelBufferGetPixelFormatType(pixels)==kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(pixels,.readOnly)==kCVReturnSuccess else{return false}
        defer {CVPixelBufferUnlockBaseAddress(pixels,.readOnly)}
        guard let bytes=CVPixelBufferGetBaseAddress(pixels)?.assumingMemoryBound(to:UInt8.self) else{return false}
        let w=CVPixelBufferGetWidth(pixels),h=CVPixelBufferGetHeight(pixels),row=CVPixelBufferGetBytesPerRow(pixels)
        var delta=0.0,count=0
        for y in stride(from:h/3,to:h*2/3,by:max(1,h/32)) {
            for x in stride(from:w/4,to:w*3/4,by:max(1,w/24)) {
                let offset=y*row+x*4;delta += Double(bytes[offset])-Double(bytes[offset+2]);count += 1
            }
        }
        return count > 0 && delta/Double(count) > 100
    }
    func prepare(phone:PhoneSession,epoch:Int) async throws {
        let began=ProcessInfo.processInfo.systemUptime
        func mark(_ stage:String) {calibrationTiming[stage]=(ProcessInfo.processInfo.systemUptime-began)*1000}
        // scannerActivity() is the single authoritative allowlist for owner,
        // exact route and owned display. Unknown camera apps cannot calibrate.
        guard display > 0 else{throw ScanError("原生扫码不属于本次独立屏幕。")}
        let initialState=try await requireCurrent(phone)
        let solid=batchedCalibration && solidCalibrationEnabled && initialState.solidCalibrationSupported
        calibrationTiming["solidCalibrationSelected"]=solid ? 1:0
        let blackReceipt=try await sendCalibrationBackground(blue:false,phone:phone,epoch:epoch,solid:solid)
        calibrationTiming["blackRequestMilliseconds"]=blackReceipt.requestMilliseconds
        calibrationTiming["blackProcessingMilliseconds"]=blackReceipt.processingMilliseconds
        mark("blackAcknowledgedMilliseconds")
        calibrationTiming["sampleSpacingMilliseconds"]=fastCalibration ? 40:80
        calibrationTiming["sampleStateChecks"]=0
        var samples=[CVPixelBuffer](),last=frames.latest().0,lastReceipt=0.0
        if fastCalibration {
            let deadline=CACurrentMediaTime()+2
            var observed=last,consecutiveDark=0
            while CACurrentMediaTime()<deadline {
                try Task.checkCancellation()
                let sample:(Int,CVPixelBuffer?,Bool,Double)
                if batchedCalibration {
                    let fresh=try await nextCalibrationFrame(after:observed,deadline:deadline)
                    sample=(fresh.revision,fresh.pixels,true,fresh.receivedAt)
                } else {sample=frames.latest()}
                guard sample.2 else{throw CancellationError()}
                if sample.0>observed,let pixels=sample.1 {
                    observed=sample.0
                    consecutiveDark=NativeCalibrationReadiness.blackVisible(pixels) ? consecutiveDark+1:0
                    if consecutiveDark>=2 {
                        try await requireCurrent(phone)
                        samples.append(pixels);last=sample.0;lastReceipt=sample.3
                        mark("darkCandidateReadyMilliseconds")
                        break
                    }
                }
                if !batchedCalibration {try await Task.sleep(nanoseconds:10_000_000)}
            }
            guard !samples.isEmpty else{throw ScanError("原生相机黑底尚未确认，已停止校准。")}
            if !batchedCalibration {try await Task.sleep(nanoseconds:40_000_000)}
        } else {
            try await Task.sleep(nanoseconds:350_000_000)
            last=frames.latest().0
        }
        for index in samples.count..<9 {
            let sample:(Int,CVPixelBuffer?,Bool,Double)
            if batchedCalibration {
                let earliest=lastReceipt+(fastCalibration ? 0.04:0.08)
                let fresh=try await nextCalibrationFrame(after:last,notBefore:earliest,deadline:CACurrentMediaTime()+2)
                sample=(fresh.revision,fresh.pixels,true,fresh.receivedAt)
            } else {
                let deadline=ProcessInfo.processInfo.systemUptime+2
                while frames.latest().0<=last && ProcessInfo.processInfo.systemUptime<deadline {
                    try Task.checkCancellation();try await Task.sleep(nanoseconds:10_000_000)
                }
                sample=frames.latest()
            }
            guard sample.2,sample.0>last,let pixels=sample.1 else{throw ScanError("原生扫码校准未收到新画面。")}
            if !batchedCalibration {
                try await requireCurrent(phone)
                calibrationTiming["sampleStateChecks",default:0]+=1
            }
            samples.append(pixels);last=sample.0;lastReceipt=sample.3
            if index<8,!batchedCalibration {try await Task.sleep(nanoseconds:fastCalibration ? 40_000_000:80_000_000)}
        }
        // The decoded slot rejects reset/replaced streams during sampling.
        // Re-check camera owner/generation/route after the complete batch and
        // again before sending blue; mixed or obsolete observations never attach.
        if batchedCalibration {
            try await requireCurrent(phone)
            calibrationTiming["sampleStateChecks",default:0]+=1
        }
        mark("blackSamplesReadyMilliseconds")
        let renderer=try await Task.detached(priority:.userInitiated) {
            let images=samples.map {CIImage(cvPixelBuffer:$0)}
            return try NativeScannerMatte(black:images[0],white:images[0],
                algorithm:.blueWithNativeColorBias,blueCalibration:images)
        }.value
        mark("rendererReadyMilliseconds")
        samples.removeAll()
        try await requireCurrent(phone)
        hidesCalibrationFrames=true
        let beforeBlue=frames.latest().0
        let blueReceipt=try await sendCalibrationBackground(blue:true,phone:phone,epoch:epoch,solid:solid)
        calibrationTiming["blueRequestMilliseconds"]=blueReceipt.requestMilliseconds
        calibrationTiming["blueProcessingMilliseconds"]=blueReceipt.processingMilliseconds
        mark("blueAcknowledgedMilliseconds")
        let deadline=ProcessInfo.processInfo.systemUptime+3
        var confirmed=false
        if batchedCalibration {
            let limit=CACurrentMediaTime()+3
            var observed=beforeBlue
            while CACurrentMediaTime()<limit {
                let fresh=try await nextCalibrationFrame(after:observed,deadline:limit)
                observed=fresh.revision
                if Self.isBlue(fresh.pixels) {
                    try await requireCurrent(phone);confirmed=true;break
                }
            }
        } else {
            while ProcessInfo.processInfo.systemUptime<deadline {
                try await requireCurrent(phone)
                if let pixels=frames.latest().1,Self.isBlue(pixels) {confirmed=true;break}
                try await Task.sleep(nanoseconds:20_000_000)
            }
        }
        guard confirmed else{throw ScanError("原生相机背景尚未确认，已停止透明预览。")}
        mark("blueConfirmedMilliseconds")
        layer.device=renderer.metalDevice;layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly=false;layer.isOpaque=false;layer.maximumDrawableCount=2
        layer.allowsNextDrawableTimeout=true;layer.displaySyncEnabled=displaySyncEnabled
        let input=frames,statistics=statistics
        var lastRenderedRevision=0 // Only the dedicated render run loop accesses this.
        let driver=NativeMetalDisplayDriver(layer:layer,active:{input.latest().2},render:{drawable in
            let sample=input.latest()
            guard sample.2,sample.0 != lastRenderedRevision,let pixels=sample.1 else{return}
            _=try renderer.present(black:CIImage(cvPixelBuffer:pixels),drawable:drawable,stats:statistics,
                                   sourceReceivedAt:sample.3)
            lastRenderedRevision=sample.0
        },failure:{ [weak self] in Task { @MainActor in self?.recordFailure() } })
        displayDriver=driver
    }
    func startPresentation() {if !frozen {displayDriver?.start()}}
    func requestDrawableSize(_ size:CGSize) {if !frozen {displayDriver?.requestDrawableSize(size)}}
    /// Keep the last original UI over the desktop while the real phone decides
    /// the QR result. No stale pointer input is accepted during this interval.
    func freeze() {
        frozen=true;frames.stop()
        displayDriver?.stop()
        if let binding=decodedBinding {binding.mailbox.removeDecodedFrameObserver(binding.id);decodedBinding=nil}
    }
    func stop() async {
        noteEnd(.cleared);freeze()
        await displayDriver?.waitUntilStopped()
        let deadline=ProcessInfo.processInfo.systemUptime+0.5
        // Occluded drawables may have no presentation callback. Drain GPU work
        // only; keep the callback accounting visible in the final statistics.
        while ProcessInfo.processInfo.systemUptime<deadline,statistics.snapshot()["pendingGPU"] as? Int != 0 {
            try? await Task.sleep(nanoseconds:20_000_000)
        }
        displayDriver=nil
    }
}
