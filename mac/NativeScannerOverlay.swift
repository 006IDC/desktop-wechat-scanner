import AppKit
import CoreImage
import CoreVideo
import QuartzCore

/// Opt-in native-camera presentation. The product owns capture/epoch/cleanup;
/// this object only calibrates the verified scanner and renders original pixels.
@MainActor final class NativeScannerOverlay {
    private let frames=NativeScannerFrames()
    private let keyGate=NativePreviewKeyGate()
    private var keyReference:NativePreviewKeyReference?
    private(set) var sourceLease:PhoneSession.NativePreviewLease?
    private var acquiringSource=false,sourceRelease:Task<Void,Error>?
    let interleaved:Bool
    var retiredFrameFilter:((CVPixelBuffer)->Bool)? {
        guard interleaved else{return nil}
        if let keyReference {return {keyReference.matches($0)}}
        // A failed calibration has no exact carrier identity. Suppress only
        // the short decoder tail; an ordinary blue App must not stay frozen.
        let deadline=ProcessInfo.processInfo.systemUptime+0.3
        return {ProcessInfo.processInfo.systemUptime<deadline && Self.isBlue($0)}
    }
    private var decodedBinding:(mailbox:MirrorVideoMailbox,id:UUID,generation:Int)?
    var decodedFrameDelivery:Bool {
        guard let binding=decodedBinding else{return false}
        return binding.mailbox.hasDecodedFrameObserver(binding.id,generation:binding.generation)
    }
    private var displayDriver:NativeMetalDisplayDriver?
    private var renderer:NativeScannerMatte?,presentationStarted=false
    var frameSelectionStatistics:[String:Int] {keyGate.statistics()}
    var presentationClock:String {displayDriver == nil ? "notStarted":"metalDisplayLink"}
    private struct Identity:Equatable {let stream:Int,owner:Int,component:String,binding:Int,capture:Int?}
    private var identity:Identity?
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
    // Carrier loss can mean that the original App covered/left its camera.
    // Retire the transparent presentation, rather than classifying it as a
    // transport/GPU failure. The controller still clears the source before input.
    private var carrierRecovery:NativeCarrierRecovery?
    private(set) var recoverySourceCleared=false
    private var recoveryClearedAt:TimeInterval?
    func confirmRecoverySourceClear() {if carrierRecovery != nil {recoveryClearedAt=ProcessInfo.processInfo.systemUptime;recoverySourceCleared=true}}
    var carrierRecoveryRequested:Bool {carrierRecovery != nil}
    @discardableResult
    func requestCarrierRecovery()->Bool {
        if carrierRecoveryRequested {return true}
        guard interleaved,renderFailure==nil,decodedFrameDelivery,
              !keyGate.current(at:ProcessInfo.processInfo.systemUptime) else{return false}
        recoveryClearedAt=nil;recoverySourceCleared=false;carrierRecovery=NativeCarrierRecovery(at:ProcessInfo.processInfo.systemUptime);return true
    }
    /// A scheduling hint only. Reopening input still needs a subsequent
    /// authenticated state snapshot through resolveCarrierRecovery below.
    var recoveryReadyForValidation:Bool {
        guard carrierRecovery != nil,recoverySourceCleared,let recoveryClearedAt else{return false}
        return keyGate.current(at:ProcessInfo.processInfo.systemUptime) && statistics.hasPresentedSource(after:recoveryClearedAt)
    }
    func resolveCarrierRecovery(in state:PhoneCameraState)->NativeCarrierRecovery.Decision {
        let decision=carrierRecovery?.decide(at:ProcessInfo.processInfo.systemUptime,
            matches:matches(state) && renderFailure==nil && decodedFrameDelivery,
            freshCarrier:recoverySourceCleared && keyGate.current(at:ProcessInfo.processInfo.systemUptime),
            freshPresentation:recoveryClearedAt.map{statistics.hasPresentedSource(after:$0)} ?? false) ?? .retire
        if decision == .resumed {carrierRecovery=nil}
        return decision
    }
    var failure:String? {
        if decodedBinding != nil,!decodedFrameDelivery {return "手机画面连接已变化。请退出扫一扫后重新进入；仍失败时请重连手机。"}
        if interleaved,!keyGate.current(at:ProcessInfo.processInfo.systemUptime) {return "手机相机画面已切换，透明取景已停止。请退出扫一扫后重新进入。"}
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
        termination["sameGeneration"]=identity?.stream==state.generation
        termination["sameOwnerGeneration"]=identity?.owner==state.ownerGeneration
        termination["sameCaptureGeneration"]=identity?.capture==state.captureGeneration
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
        if let changed=error as? CameraFrameExpiredError {termination["sourceInvalidated"]=changed.sourceInvalidated}
        if let scan=error as? ScanError {
            switch scan.message {
            case "手机相机画面已切换，透明取景已停止。请退出扫一扫后重新进入。":termination["failureKind"]="carrierExpired"
            case "扫码画面显示中断。请退出扫一扫后重新进入。":termination["failureKind"]="nativeRenderer"
            case "手机画面连接已变化。请退出扫一扫后重新进入；仍失败时请重连手机。":termination["failureKind"]="decodedBinding"
            default:break
            }
        }
        if let transient=error as? DesktopCaptureTransientError {
            switch transient {
            case .frameExpired:termination["transient"]=1
            case .frameNotReady:termination["transient"]=2
            case .encodingBusy:termination["transient"]=3
            }
        }
    }
    private func recordFailure() {renderFailure="扫码画面显示中断。请退出扫一扫后重新进入。"}
    init(display:Int,package:String,fastCalibration:Bool=false,batchedCalibration:Bool=false,solidCalibrationEnabled:Bool=true,displaySyncEnabled:Bool=true,interleaved:Bool=false) {
        self.interleaved=interleaved
        self.display=display;self.package=package;self.fastCalibration=fastCalibration || batchedCalibration
        self.batchedCalibration=batchedCalibration
        self.solidCalibrationEnabled=solidCalibrationEnabled
        self.displaySyncEnabled=displaySyncEnabled
    }
    /// Show genuine black-background frames during calibration, so opening the
    /// Android scanner keeps its own animation. Hide only the blue-key phase.
    func receive(_ pixels:CVPixelBuffer)->Bool {
        if decodedBinding == nil,keyGate.accepts(pixels),frames.publish(pixels) {statistics.received(at:ProcessInfo.processInfo.systemUptime)}
        return hidesCalibrationFrames || frozen
    }
    /// Bind only after the caller verified the exact mirror display/incarnation.
    /// Capture the thread-safe frame slot, never this MainActor UI object.
    func observeDecodedFrames(in mailbox:MirrorVideoMailbox,generation:Int) throws {
        guard decodedBinding == nil,!frozen else{throw ScanError("手机扫码预览已停止。请退出扫一扫后重新进入。")}
        let input=frames,statistics=statistics,gate=keyGate
        guard let id=mailbox.observeDecodedFrames(generation:generation,onInvalidated:{input.stop()},receive:{pixels in
            if gate.accepts(pixels),input.publish(pixels) {statistics.received(at:ProcessInfo.processInfo.systemUptime)}
        }) else{throw ScanError("手机画面连接已变化。请退出扫一扫后重新进入；仍失败时请重连手机。")}
        decodedBinding=(mailbox,id,generation)
    }
    func matches(_ state:PhoneCameraState)->Bool {
        guard let scanner=interleaved ? state.captureActivity():state.scannerActivity(),scanner.displayId==display,scanner.package==package else{return false}
        let value=Identity(stream:state.generation,owner:state.ownerGeneration,component:scanner.component,binding:state.desktopCameraGeneration,capture:state.captureGeneration)
        return identity.map {$0 == value} ?? true
    }
    @discardableResult
    private func requireCurrent(_ phone:PhoneSession) async throws -> PhoneCameraState {
        try Task.checkCancellation()
        guard !frozen else{throw CancellationError()}
        if decodedBinding != nil,!decodedFrameDelivery {throw ScanError("手机画面连接已变化。请退出扫一扫后重新进入；仍失败时请重连手机。")}
        let state=try await phone.cameraState()
        try Task.checkCancellation()
        guard !frozen else{throw CancellationError()}
        if decodedBinding != nil,!decodedFrameDelivery {throw ScanError("手机画面连接已变化。请退出扫一扫后重新进入；仍失败时请重连手机。")}
        guard matches(state) else{throw ScanError("手机扫码画面已切换，透明取景已停止。请退出扫一扫后重新进入。")}
        if identity == nil,let activity=interleaved ? state.captureActivity():state.scannerActivity() {
            identity=Identity(stream:state.generation,owner:state.ownerGeneration,component:activity.component,binding:state.desktopCameraGeneration,capture:state.captureGeneration)
        }
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
        catch NativeScannerFrames.Failure.concurrentWait {throw ScanError("扫码预览准备已中断。请退出扫一扫后重新进入。")}
        catch NativeScannerFrames.Failure.timedOut {throw ScanError("暂时没有收到手机扫码画面。请退出扫一扫后重新进入。")}
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
        if interleaved {try await prepareInterleaved(phone:phone,epoch:epoch);return}
        let began=ProcessInfo.processInfo.systemUptime
        func mark(_ stage:String) {calibrationTiming[stage]=(ProcessInfo.processInfo.systemUptime-began)*1000}
        // scannerActivity() is the single authoritative allowlist for owner,
        // exact route and owned display. Unknown camera apps cannot calibrate.
        guard display > 0 else{throw ScanError("无法连接当前手机应用窗口。请断开后重新连接手机，再打开应用的扫一扫。")}
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
            guard !samples.isEmpty else{throw ScanError("手机扫码画面尚未准备好，透明取景已停止。请退出扫一扫后重新进入。")}
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
            guard sample.2,sample.0>last,let pixels=sample.1 else{throw ScanError("暂时没有收到手机扫码画面。请退出扫一扫后重新进入。")}
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
        guard confirmed else{throw ScanError("无法确认手机扫码画面，透明取景已停止。请退出扫一扫后重新进入。")}
        mark("blueConfirmedMilliseconds")
        installRenderer(renderer)
    }
    private func prepareInterleaved(phone:PhoneSession,epoch:Int) async throws {
        guard !acquiringSource,sourceLease==nil,!frozen else{throw CancellationError()}
        acquiringSource=true;defer{acquiringSource=false}
        let began=ProcessInfo.processInfo.systemUptime
        let state=try await requireCurrent(phone)
        guard state.interleavedPreviewSupported,state.desktopCameraEnabled,state.activeStreams==1 else{
            throw ScanError("当前相机不支持透明取景。请关闭“原生扫码界面（试用）”，使用普通扫码框重试。")
        }
        // Establish black before enabling the carrier: no coded frame may flash
        // through the ordinary phone surface while calibration is being prepared.
        _=try await phone.solidCalibrationFrame(blue:false,epoch:epoch)
        guard let capture=state.captureGeneration else{throw ScanError("当前手机连接无法开启透明取景。请关闭“原生扫码界面（试用）”，使用普通扫码框重试。")}
        try await NativePreviewLeaseHandoff.acquire(begin:{
            try await phone.beginNativePreview(display:display,epoch:epoch,capture:capture)
        },adopt:{lease in
            guard !frozen,sourceLease==nil,decodedBinding==nil || decodedFrameDelivery else{throw CancellationError()}
            sourceLease=lease
        },retire:{try await phone.endNativePreview($0)})
        do {try await calibrateInterleaved(phone:phone,epoch:epoch,began:began)}
        catch {try? await releaseSource(phone:phone);throw error}
    }
    private func calibrateInterleaved(phone:PhoneSession,epoch:Int,began:TimeInterval) async throws {
        try await requireCurrent(phone)
        let prepared=try await withThrowingTaskGroup(of:(Int,NativeScannerMatte.CalibrationBatch,Double).self) {group in
            // At most nine immutable uploads, owned and joined by this lease's
            // preparation. Cancellation/failure cannot leave a publisher behind.
            defer {group.cancelAll()}
            var samples=[CVPixelBuffer]()
            for phase:UInt8 in 0...2 {
                if phase>0 {hidesCalibrationFrames=true}
                let before=frames.latest().0
                guard let sourceLease else{throw CancellationError()}
                let phaseBegan=ProcessInfo.processInfo.systemUptime
                try await phone.nativePreviewCalibration(phase,lease:sourceLease)
                calibrationTiming["phase\(phase)CommandMilliseconds"]=(ProcessInfo.processInfo.systemUptime-phaseBegan)*1000
                var firstAccepted:Double?,lastReceipt=0.0,rejected=0,ownershipMilliseconds=0.0
                let deadline=CACurrentMediaTime()+2
                var observed=before,lastAccepted=0.0,accepted=0,nextStateCheck=CACurrentMediaTime()+0.08
                while accepted<3 {
                    let sample=try await nextCalibrationFrame(after:observed,notBefore:lastAccepted>0 ? lastAccepted+0.04:0,deadline:deadline)
                    observed=sample.revision
                    if CACurrentMediaTime()>=nextStateCheck {
                        let checkBegan=ProcessInfo.processInfo.systemUptime
                        try await requireCurrent(phone);ownershipMilliseconds+=(ProcessInfo.processInfo.systemUptime-checkBegan)*1000
                        nextStateCheck=CACurrentMediaTime()+0.08
                    }
                    let ready=phase==0 ? NativeCalibrationReadiness.blackEndpointVisible(sample.pixels):
                        (phase==1 ? NativeCalibrationReadiness.whiteEndpointVisible(sample.pixels):Self.isBlue(sample.pixels))
                    guard ready else{rejected+=1;continue}
                    if firstAccepted==nil {
                        firstAccepted=sample.receivedAt
                        calibrationTiming["phase\(phase)FirstMatchMilliseconds"]=(ProcessInfo.processInfo.systemUptime-phaseBegan)*1000
                    }
                    let index=samples.count,pixels=sample.pixels
                    samples.append(pixels);lastAccepted=sample.receivedAt;lastReceipt=sample.receivedAt;accepted+=1
                    group.addTask(priority:.userInitiated) {
                        try Task.checkCancellation()
                        let uploadBegan=ProcessInfo.processInfo.systemUptime
                        let batch=try NativeScannerMatte.prepareCalibrationBatch([CIImage(cvPixelBuffer:pixels)])
                        return (index,batch,(ProcessInfo.processInfo.systemUptime-uploadBegan)*1000)
                    }
                }
                try await requireCurrent(phone)
                calibrationTiming["phase\(phase)ReadyMilliseconds"]=(ProcessInfo.processInfo.systemUptime-began)*1000
                calibrationTiming["phase\(phase)SampleSpanMilliseconds"]=(lastReceipt-(firstAccepted ?? lastReceipt))*1000
                calibrationTiming["phase\(phase)RejectedFrames"]=Double(rejected)
                calibrationTiming["phase\(phase)OwnershipCheckMilliseconds"]=ownershipMilliseconds
            }
            let joinBegan=ProcessInfo.processInfo.systemUptime
            var batches=[NativeScannerMatte.CalibrationBatch?](repeating:nil,count:9)
            for try await (index,batch,milliseconds) in group {
                batches[index]=batch;calibrationTiming["sample\(index)UploadMilliseconds"]=milliseconds
            }
            calibrationTiming["uploadJoinMilliseconds"]=(ProcessInfo.processInfo.systemUptime-joinBegan)*1000
            let rendererBegan=ProcessInfo.processInfo.systemUptime
            let complete=batches.compactMap{$0}
            guard complete.count==9 else{throw NativeScannerMatte.Unavailable("prepared_calibration")}
            let result=try await Task.detached(priority:.userInitiated) {
                try Task.checkCancellation()
                let reference=try NativePreviewKeyReference(samples:samples)
                let images=samples.map{CIImage(cvPixelBuffer:$0)}
                let renderer=try NativeScannerMatte(black:images[0],white:images[3],algorithm:.spatialBlue,
                    blueCalibration:images,preparedCalibration:complete)
                return (reference,renderer)
            }.value
            calibrationTiming["rendererPreparationMilliseconds"]=(ProcessInfo.processInfo.systemUptime-rendererBegan)*1000
            return result
        }
        try await requireCurrent(phone)
        let confirmationBegan=ProcessInfo.processInfo.systemUptime,deadline=CACurrentMediaTime()+0.3
        var latest=frames.latest(),confirmed=false,observed=latest.0
        while true {
            guard latest.2 else{throw CancellationError()}
            if let pixels=latest.1 {
                let fraction=prepared.0.matchFraction(pixels)
                calibrationTiming["carrierConfirmationMatchFraction"]=fraction
                if fraction>=0.9,ProcessInfo.processInfo.systemUptime-latest.3<0.3 {confirmed=true;break}
            }
            guard CACurrentMediaTime()<deadline else{break}
            let sample=try await nextCalibrationFrame(after:observed,deadline:deadline)
            observed=sample.revision;latest=(sample.revision,sample.pixels,true,sample.receivedAt)
        }
        guard confirmed else{throw ScanError("手机扫码画面无法用于透明取景。请关闭“原生扫码界面（试用）”，使用普通扫码框重试。")}
        try await requireCurrent(phone)
        calibrationTiming["carrierConfirmationWaitMilliseconds"]=(ProcessInfo.processInfo.systemUptime-confirmationBegan)*1000
        keyReference=prepared.0;keyGate.begin(prepared.0,verifiedAt:latest.3)
        installRenderer(prepared.1)
        calibrationTiming["interleavedPreviewReadyMilliseconds"]=(ProcessInfo.processInfo.systemUptime-began)*1000
    }
    private func installRenderer(_ renderer:NativeScannerMatte) {
        self.renderer=renderer
        layer.device=renderer.metalDevice;layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly=false;layer.isOpaque=false;layer.maximumDrawableCount=2
        layer.allowsNextDrawableTimeout=true;layer.displaySyncEnabled=displaySyncEnabled
        let input=frames,statistics=statistics,gate=keyGate
        var lastRenderedRevision=0 // Only the dedicated render run loop accesses this.
        let driver=NativeMetalDisplayDriver(layer:layer,active:{input.latest().2},render:{drawable in
            let sample=input.latest()
            guard gate.current(at:ProcessInfo.processInfo.systemUptime),sample.2,sample.0 != lastRenderedRevision,let pixels=sample.1 else{return}
            _=try renderer.present(black:CIImage(cvPixelBuffer:pixels),drawable:drawable,stats:statistics,
                                   sourceReceivedAt:sample.3)
            lastRenderedRevision=sample.0
        },failure:{ [weak self] in Task { @MainActor in self?.recordFailure() } })
        displayDriver=driver
    }
    func startPresentation() {if !frozen {presentationStarted=true;displayDriver?.start()}}
    /// Explicit headless verification. Never races the display driver, acquires
    /// a drawable, captures a Mac screen, or exports the rendered phone pixels.
    func diagnosticRenderingSummary() async throws ->[String:Double] {
        let sample=frames.latest()
        guard !presentationStarted,!frozen,sample.2,let pixels=sample.1,let renderer,
              !interleaved || keyReference?.matches(pixels)==true else{throw ScanError("原生显示诊断状态已变化。")}
        return try await Task.detached(priority:.userInitiated) {
            let began=ProcessInfo.processInfo.systemUptime,image=try renderer.render(black:CIImage(cvPixelBuffer:pixels))
            let width=image.width,height=image.height,row=width*4
            var bytes=[UInt8](repeating:0,count:row*height)
            return try bytes.withUnsafeMutableBytes {memory in
                guard let context=CGContext(data:memory.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:row,
                    space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue) else{throw ScanError("原生显示诊断不可用。")}
                context.draw(image,in:CGRect(x:0,y:0,width:width,height:height))
                let p=memory.bindMemory(to:UInt8.self);var total=0,transparent=0,opaque=0,alpha=0
                for y in stride(from:height/3,to:height*2/3,by:4) {for x in stride(from:width/3,to:width*2/3,by:4) {
                    let a=Int(p[y*row+x*4+3]);total+=1;alpha+=a;if a<16 {transparent+=1};if a>240 {opaque+=1}
                }}
                return ["renderAndReadbackMilliseconds":(ProcessInfo.processInfo.systemUptime-began)*1000,
                    "centralSamples":Double(total),"centralTransparentFraction":Double(transparent)/Double(max(1,total)),
                    "centralOpaqueFraction":Double(opaque)/Double(max(1,total)),"centralMeanAlpha":Double(alpha)/Double(max(1,total)*255)]
            }
        }.value
    }
    func requestDrawableSize(_ size:CGSize) {if !frozen {displayDriver?.requestDrawableSize(size)}}
    /// Keep the last original UI over the desktop while the real phone decides
    /// the QR result. No stale pointer input is accepted during this interval.
    func freeze() {
        frozen=true;keyGate.stop();frames.stop()
        displayDriver?.stop()
        if let binding=decodedBinding {binding.mailbox.removeDecodedFrameObserver(binding.id);decodedBinding=nil}
    }
    func releaseSource(phone:PhoneSession) async throws {
        if let sourceRelease {try await sourceRelease.value;return}
        guard let lease=sourceLease else{return}
        let job=Task {try await phone.endNativePreview(lease)}
        sourceRelease=job
        do {
            try await job.value
            if sourceLease==lease {sourceLease=nil}
            sourceRelease=nil
        }catch {sourceRelease=nil;throw error}
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
        displayDriver=nil;renderer=nil
    }
}
