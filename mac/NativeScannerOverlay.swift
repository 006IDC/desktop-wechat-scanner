import AppKit
import CoreImage
import CoreVideo

/// Opt-in native-camera presentation. The product owns capture/epoch/cleanup;
/// this object only calibrates the verified scanner and renders original pixels.
@MainActor final class NativeScannerOverlay {
    private final class Frames: @unchecked Sendable {
        private let lock=NSLock()
        private var revision=0,pixels:CVPixelBuffer?,active=true
        func publish(_ value:CVPixelBuffer) {lock.withLock {if active {revision += 1;pixels=value}}}
        func latest()->(Int,CVPixelBuffer?,Bool) {lock.withLock {(revision,pixels,active)}}
        func stop() {lock.withLock {active=false;pixels=nil}}
    }
    private let frames=Frames()
    private var worker:Task<Void,Never>?
    private var identity:(Int,Int)?
    private let display:Int,package:String
    let layer=CAMetalLayer()
    let statistics=NativeMattePresentationStats()
    private(set) var frozen=false
    private(set) var failure:String?
    private func recordFailure() {failure="原生扫码显示中断。"}
    init(display:Int,package:String) {self.display=display;self.package=package}
    func receive(_ pixels:CVPixelBuffer) {frames.publish(pixels)}
    func matches(_ state:PhoneCameraState)->Bool {
        guard let scanner=state.scannerActivity(),scanner.displayId==display,scanner.package==package else{return false}
        return identity.map {$0 == (state.generation,state.ownerGeneration)} ?? true
    }
    private func requireCurrent(_ phone:PhoneSession) async throws {
        try Task.checkCancellation()
        let state=try await phone.cameraState()
        guard matches(state) else{throw ScanError("原生扫码状态已变化，已停止校准。")}
        if identity == nil {identity=(state.generation,state.ownerGeneration)}
    }
    private nonisolated static func background(blue:Bool) throws -> Data {
        let image=CIImage(color:CIColor(red:0,green:0,blue:blue ? 1:0))
            .cropped(to:CGRect(x:0,y:0,width:720,height:1280))
        guard let space=CGColorSpace(name:CGColorSpace.sRGB),
              let data=CIContext().pngRepresentation(of:image,format:.RGBA8,colorSpace:space) else {
            throw ScanError("无法生成原生相机校准帧。")
        }
        return data
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
        // Initially support the native layout exercised by the real USB probe.
        guard display > 0,package=="com.tencent.mm" else{throw ScanError("当前原生透明预览尚未验证此应用。")}
        try await requireCurrent(phone)
        let black=try await Task.detached {try Self.background(blue:false)}.value
        _=try await phone.frame(black,epoch:epoch)
        try await Task.sleep(nanoseconds:350_000_000)
        var samples=[CVPixelBuffer](),last=frames.latest().0
        for _ in 0..<9 {
            let deadline=ProcessInfo.processInfo.systemUptime+2
            while frames.latest().0<=last && ProcessInfo.processInfo.systemUptime<deadline {
                try Task.checkCancellation();try await Task.sleep(nanoseconds:10_000_000)
            }
            let sample=frames.latest()
            guard sample.2,sample.0>last,let pixels=sample.1 else{throw ScanError("原生扫码校准未收到新画面。")}
            try await requireCurrent(phone)
            samples.append(pixels);last=sample.0
            try await Task.sleep(nanoseconds:80_000_000)
        }
        let renderer=try await Task.detached(priority:.userInitiated) {
            let images=samples.map {CIImage(cvPixelBuffer:$0)}
            return try NativeScannerMatte(black:images[0],white:images[0],
                algorithm:.blueWithNativeColorBias,blueCalibration:images)
        }.value
        samples.removeAll()
        try await requireCurrent(phone)
        let blue=try await Task.detached {try Self.background(blue:true)}.value
        _=try await phone.frame(blue,epoch:epoch)
        let deadline=ProcessInfo.processInfo.systemUptime+3
        var confirmed=false
        while ProcessInfo.processInfo.systemUptime<deadline {
            try await requireCurrent(phone)
            if let pixels=frames.latest().1,Self.isBlue(pixels) {confirmed=true;break}
            try await Task.sleep(nanoseconds:20_000_000)
        }
        guard confirmed else{throw ScanError("原生相机背景尚未确认，已停止透明预览。")}
        layer.device=renderer.metalDevice;layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly=false;layer.isOpaque=false;layer.maximumDrawableCount=2
        layer.allowsNextDrawableTimeout=true;layer.displaySyncEnabled=true
        // Layer is attached/sized by the native view before this worker starts.
        worker=Task.detached(priority:.userInitiated) { [frames,layer,statistics,weak self] in
            var last=0
            do {
                while !Task.isCancelled {
                    let sample=frames.latest()
                    guard sample.2 else{break}
                    if sample.0 != last,let pixels=sample.1,layer.drawableSize.width>0,layer.drawableSize.height>0 {
                        _=try renderer.present(black:CIImage(cvPixelBuffer:pixels),layer:layer,stats:statistics)
                        last=sample.0
                    }
                    try await Task.sleep(nanoseconds:5_000_000)
                }
            } catch {
                if let owner=self,!Task.isCancelled {await owner.recordFailure()}
            }
            let deadline=ProcessInfo.processInfo.systemUptime+0.5
            // Hidden windows may never present their final drawable. Waiting
            // for its presentation callback would turn Back/close into a pause.
            // GPU completion is sufficient for releasing renderer resources;
            // the statistics still disclose pending presentation callbacks.
            while ProcessInfo.processInfo.systemUptime<deadline,statistics.snapshot()["pendingGPU"] as? Int != 0 {
                try? await Task.sleep(nanoseconds:20_000_000)
            }
        }
    }
    /// Keep the last original UI over the desktop while the real phone decides
    /// the QR result. No stale pointer input is accepted during this interval.
    func freeze() {frozen=true;frames.stop()}
    func stop() async {freeze();await worker?.value;worker=nil}
}
