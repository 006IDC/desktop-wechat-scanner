import AppKit
@preconcurrency import ScreenCaptureKit
import CoreImage
import CoreMedia
import ImageIO
import UniformTypeIdentifiers

/// This one frame can be discarded. The caller must read a fresh rectangle
/// before retrying, and bound consecutive failures at the session level.
/// Stream startup, permission and display errors are deliberately not included.
enum DesktopCaptureTransientError: LocalizedError, Equatable, Sendable {
    case frameExpired
    case frameNotReady
    case encodingBusy
    var errorDescription: String? {
        switch self {
        case .frameExpired: return "本次桌面画面已过时。"
        case .frameNotReady: return "桌面画面暂未就绪。"
        case .encodingBusy: return "桌面画面正在处理。"
        }
    }
}

// One-shot completion shared by callback, timeout and cancellation paths.
private final class CaptureReply<T>: @unchecked Sendable {
    private let lock=NSLock()
    private var continuation:CheckedContinuation<T,Error>?
    private var result:Result<T,Error>?
    private var finished=false
    func install(_ continuation:CheckedContinuation<T,Error>) {
        lock.lock()
        if let result {self.result=nil;lock.unlock();continuation.resume(with:result)}
        else {self.continuation=continuation;lock.unlock()}
    }
    @discardableResult func finish(_ result:Result<T,Error>) -> Bool {
        lock.lock()
        guard !finished else {lock.unlock();return false}
        finished=true;let continuation=self.continuation;self.continuation=nil
        if continuation == nil {self.result=result}
        lock.unlock();continuation?.resume(with:result);return true
    }
}

private func captureOperation<T>(timeout:TimeInterval, message:String, timeoutError:Error?=nil,
                                _ operation:@escaping (CaptureReply<T>)->Void) async throws -> T {
    let reply=CaptureReply<T>()
    return try await withTaskCancellationHandler(operation:{
        try await withCheckedThrowingContinuation { continuation in
            reply.install(continuation)
            if Task.isCancelled {reply.finish(.failure(CancellationError()));return}
            DispatchQueue.global(qos:.userInitiated).asyncAfter(deadline:.now()+timeout) {
                reply.finish(.failure(timeoutError ?? ScanError(message)))
            }
            operation(reply)
        }
    },onCancel:{reply.finish(.failure(CancellationError()))})
}

// NSScreen uses a global bottom-left origin; Core Image also crops bottom-up.
// Scaling uses the actual delivered buffer dimensions, including Retina/scaled displays.
enum DesktopCaptureGeometry {
    private static func isValid(_ rect:CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && rect.origin.x.isFinite && rect.origin.y.isFinite &&
        rect.size.width.isFinite && rect.size.height.isFinite && rect.size.width>0 && rect.size.height>0 &&
        rect.maxX.isFinite && rect.maxY.isFinite
    }
    // Prefer the display covering most of the ROI. An entirely offscreen ROI uses
    // the nearest display, preserving its scale while its uncovered pixels stay white.
    static func screenIndex(for rect:CGRect,screens:[CGRect]) throws -> Int? {
        guard isValid(rect) else{throw ScanError("桌面采集区域尺寸无效。")}
        var selected:Int?,bestArea:CGFloat = -1,bestDistance=CGFloat.infinity
        for (index,screen) in screens.enumerated() where isValid(screen) {
            let overlap=rect.intersection(screen)
            let area=overlap.isNull ? 0 : overlap.width*overlap.height
            let dx=max(0,max(screen.minX-rect.maxX,rect.minX-screen.maxX))
            let dy=max(0,max(screen.minY-rect.maxY,rect.minY-screen.maxY))
            let distance=hypot(dx,dy)
            if area>bestArea || (area==bestArea && distance<bestDistance) {
                selected=index;bestArea=area;bestDistance=distance
            }
        }
        return selected
    }
    static func pixelCrop(rect:CGRect, screen:CGRect, pixels:CGSize) throws -> CGRect {
        guard isValid(rect),isValid(screen),pixels.width.isFinite,pixels.height.isFinite,
              pixels.width>0,pixels.height>0 else {throw ScanError("桌面采集区域尺寸无效。")}
        // Do not clip the ROI: doing so would enlarge the remaining content and
        // change the phone-to-desktop scale while dragging over a screen edge.
        let crop=CGRect(x:(rect.minX-screen.minX)*pixels.width/screen.width,
                        y:(rect.minY-screen.minY)*pixels.height/screen.height,
                        width:rect.width*pixels.width/screen.width,
                        height:rect.height*pixels.height/screen.height)
        guard isValid(crop) else{throw ScanError("桌面采集区域尺寸无效。")}
        return crop
    }
    static func outputSize(_ source:CGSize, maximumDimension:Int) throws -> CGSize {
        guard source.width>0, source.height>0, source.width.isFinite, source.height.isFinite,
              maximumDimension>0 else {throw ScanError("桌面采集尺寸无效。")}
        let scale=min(1,CGFloat(maximumDimension)/max(source.width,source.height))
        return CGSize(width:max(1,(source.width*scale).rounded()),height:max(1,(source.height*scale).rounded()))
    }
}

/// Immutable UI geometry. Publishing this snapshot is the only main-actor work
/// needed by the background camera pump; no NSScreen survives across the boundary.
struct DesktopCaptureTarget: Sendable {
    let rect:CGRect
    let displayID:CGDirectDisplayID
    let screenFrame:CGRect
    let pixelSize:CGSize
    let selectedAt:TimeInterval

    @MainActor static func current(for rect:CGRect) throws -> DesktopCaptureTarget {
        let selectedAt=ProcessInfo.processInfo.systemUptime
        let screens=NSScreen.screens
        guard let index=try DesktopCaptureGeometry.screenIndex(for:rect,screens:screens.map(\.frame)) else {
            throw ScanError("没有可用的桌面显示器。")
        }
        let screen=screens[index]
        guard let id=screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else {
            throw ScanError("无法取得桌面显示器。")
        }
        let target=DesktopCaptureTarget(rect:rect,displayID:id,screenFrame:screen.frame,
                                        pixelSize:CGSize(width:CGDisplayPixelsWide(id),height:CGDisplayPixelsHigh(id)),
                                        selectedAt:selectedAt)
        try target.validate()
        return target
    }

    func validate() throws {
        _=try DesktopCaptureGeometry.pixelCrop(rect:rect,screen:screenFrame,pixels:pixelSize)
        // SCStream dimensions are integer pixels. Check before converting an
        // externally supplied snapshot so invalid values never trap in Int().
        guard pixelSize.width>=1,pixelSize.height>=1,
              pixelSize.width<CGFloat(Int.max),pixelSize.height<CGFloat(Int.max),
              pixelSize.width.rounded()==pixelSize.width,pixelSize.height.rounded()==pixelSize.height else {
            throw ScanError("桌面采集尺寸无效。")
        }
    }
    func requireFresh(at now:TimeInterval) throws {
        guard selectedAt.isFinite,now.isFinite,now-selectedAt<=0.5 else {
            throw DesktopCaptureTransientError.frameExpired
        }
    }
}

struct DesktopFrame: @unchecked Sendable {
    let pixels:CVPixelBuffer
    // Time the ROI was selected for processing, not the last screen-content change.
    let selectedAt:TimeInterval
    func requireFresh(at now:TimeInterval) throws {
        guard selectedAt.isFinite, now.isFinite, now-selectedAt<=0.5 else {
            throw DesktopCaptureTransientError.frameExpired
        }
    }
}

// ScreenCaptureKit's output callback never encodes or waits for the consumer.
// This store retains at most one latest surface; an encoder may retain one more.
final class DesktopFrameStore: @unchecked Sendable {
    private let lock=NSLock()
    private var pixels:CVPixelBuffer?
    private var failure:Error?
    private var active=true
    func accept(_ pixels:CVPixelBuffer?, status:SCFrameStatus) {
        lock.lock();defer {lock.unlock()}
        guard active else{return}
        switch status {
        case .complete:
            self.pixels=pixels
        case .idle:
            // Idle means unchanged content, not a promised periodic heartbeat.
            break
        default:self.pixels=nil
        }
    }
    // `now` is the caller's ROI selection time, even if stream readiness came later.
    func latest(now:TimeInterval) throws -> DesktopFrame? {
        lock.lock();defer {lock.unlock()}
        if let failure {throw failure}
        guard active else{throw CancellationError()}
        // A healthy stream may emit nothing for a static display. Keep its last
        // accepted surface until a replacement or explicit invalidation arrives.
        guard let pixels else{return nil}
        return DesktopFrame(pixels:pixels,selectedAt:now)
    }
    func finish(_ error:Error=CancellationError()) {
        lock.lock();active=false;pixels=nil;failure=error;lock.unlock()
    }
}

private final class DesktopStreamOutput:NSObject,SCStreamOutput,SCStreamDelegate,@unchecked Sendable {
    let frames=DesktopFrameStore()
    func stream(_ stream:SCStream,didOutputSampleBuffer sampleBuffer:CMSampleBuffer,of type:SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer),
              let info=CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,createIfNecessary:false) as? [[SCStreamFrameInfo:Any]],
              let raw=info.first?[.status] as? Int, let status=SCFrameStatus(rawValue:raw) else{return}
        let timestamp=CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let sampleTime=CMTimeGetSeconds(timestamp)
        let hostTime=CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        // Reject an already delayed replacement; absence of callbacks alone does
        // not imply staleness. Invalidation statuses apply even with an old PTS.
        if status == .complete, timestamp.isValid, sampleTime.isFinite, hostTime-sampleTime>0.5 {
            frames.accept(nil,status:.complete);return
        }
        frames.accept(CMSampleBufferGetImageBuffer(sampleBuffer),status:status)
    }
    func stream(_ stream:SCStream,didStopWithError error:Error) {frames.finish(error)}
}

// The context and JPEG work live on this queue, never on the main/UI actor.
final class DesktopFrameEncoder: @unchecked Sendable {
    private let queue=DispatchQueue(label:"com.idc006.desktop.jpeg",qos:.userInitiated)
    private let context=CIContext(options:[.cacheIntermediates:false])
    private let colorSpace=CGColorSpace(name:CGColorSpace.sRGB)!
    private let lock=NSLock()
    private var encoding=false
    private func begin() -> Bool {
        lock.lock();defer{lock.unlock()}
        guard !encoding else{return false};encoding=true;return true
    }
    private func end() {lock.lock();encoding=false;lock.unlock()}
    func encode(_ frame:DesktopFrame,rect:CGRect,screen:CGRect,maximumDimension:Int) async throws -> Data {
        return try await captureOperation(timeout:3,message:"桌面图像编码超时。",timeoutError:DesktopCaptureTransientError.frameExpired) { reply in
            guard self.begin() else {reply.finish(.failure(DesktopCaptureTransientError.encodingBusy));return}
            self.queue.async {
                let result:Result<Data,Error>
                do {
                    try frame.requireFresh(at:ProcessInfo.processInfo.systemUptime)
                    let data=try self.jpeg(frame.pixels,rect:rect,screen:screen,maximumDimension:maximumDimension)
                    try frame.requireFresh(at:ProcessInfo.processInfo.systemUptime)
                    result = .success(data)
                } catch {result = .failure(error)}
                self.end()
                reply.finish(result)
            }
        }
    }
    // Internal synchronous entry used only on the encoding queue or with synthetic fixtures.
    func jpeg(_ pixels:CVPixelBuffer,rect:CGRect,screen:CGRect,maximumDimension:Int) throws -> Data {
        let image=CIImage(cvPixelBuffer:pixels)
        let crop=try DesktopCaptureGeometry.pixelCrop(rect:rect,screen:screen,pixels:image.extent.size)
        let size=try DesktopCaptureGeometry.outputSize(crop.size,maximumDimension:maximumDimension)
        // Only pixels intersecting this selected display come from the source.
        // Uncovered edges (including another display) use white, not stretched or old pixels.
        let white=CIImage(color:CIColor(red:1,green:1,blue:1)).cropped(to:crop)
        let visible=crop.intersection(image.extent)
        let padded=visible.isNull || visible.isEmpty ? white
            : image.cropped(to:visible).composited(over:white).cropped(to:crop)
        let normalized=padded.transformed(by:CGAffineTransform(translationX:-crop.minX,y:-crop.minY))
        let scaled=normalized.transformed(by:CGAffineTransform(scaleX:size.width/crop.width,y:size.height/crop.height))
        guard let result=context.createCGImage(scaled,from:CGRect(origin:.zero,size:size),format:.RGBA8,colorSpace:colorSpace) else {throw ScanError("无法读取扫码区域。")}
        let data=NSMutableData()
        guard let destination=CGImageDestinationCreateWithData(data,UTType.jpeg.identifier as CFString,1,nil) else {throw ScanError("无法编码桌面画面。")}
        CGImageDestinationAddImage(destination,result,[kCGImageDestinationLossyCompressionQuality:0.88] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {throw ScanError("桌面图像编码失败。")}
        return data as Data
    }
}

actor DesktopCapture {
    private var content:SCShareableContent?
    private var stream:SCStream?
    private var stoppingTask:Task<Void,Never>?
    private var output:DesktopStreamOutput?
    private var displayID:CGDirectDisplayID?
    private var screenFrame:CGRect?
    private var pixelSize:CGSize?
    private var generation=0
    private var captureInFlight=false
    private var preparationInFlight=false
    private let sampleQueue=DispatchQueue(label:"com.idc006.desktop.stream",qos:.userInteractive)
    private let encoder=DesktopFrameEncoder()
    private(set) var permissionBlocked=false

    func prepare() async throws {
        try checkPermission()
        if content != nil{return}
        guard !preparationInFlight else {throw ScanError("屏幕采集正在准备，请稍后重试。")}
        preparationInFlight=true;defer{preparationInFlight=false}
        let token=generation
        do {
            let value:SCShareableContent=try await captureOperation(timeout:12,message:"屏幕捕获启动超时。请确认系统设置中的屏幕录制权限已允许。") { reply in
                SCShareableContent.getExcludingDesktopWindows(false,onScreenWindowsOnly:true) { value,error in
                    if let value {reply.finish(.success(value))}
                    else {reply.finish(.failure(error ?? ScanError("无法获取屏幕录制权限。")))}
                }
            }
            try Task.checkCancellation()
            guard token==generation else {throw CancellationError()}
            content=value
        } catch {
            markPermissionFailure(error)
            throw error
        }
    }

    // Compatibility entry for old callers/tests. The product pump publishes its
    // own snapshot and uses capture(target), which never hops to the main actor.
    func capture(_ rect:CGRect, maximumDimension:Int=1600) async throws -> Data {
        try Task.checkCancellation()
        let target=try await MainActor.run {try DesktopCaptureTarget.current(for:rect)}
        return try await capture(target,maximumDimension:maximumDimension)
    }

    func capture(_ target:DesktopCaptureTarget, maximumDimension:Int=1600) async throws -> Data {
        try checkPermission();try Task.checkCancellation()
        try target.validate()
        try target.requireFresh(at:ProcessInfo.processInfo.systemUptime)
        let requestedAt=target.selectedAt
        guard !captureInFlight else {throw DesktopCaptureTransientError.encodingBusy}
        captureInFlight=true;defer{captureInFlight=false}
        guard maximumDimension>0 else{throw ScanError("桌面采集尺寸无效。")}
        do {
            try await ensureStream(display:target.displayID,screen:target.screenFrame,pixels:target.pixelSize)
            let token=generation
            guard let output else{throw CancellationError()}
            // A late stream switch/first frame cannot extend this ROI's lifetime.
            let deadline=requestedAt+0.5
            var frame:DesktopFrame?
            while frame == nil {
                try Task.checkCancellation()
                guard token==generation else{throw CancellationError()}
                frame=try output.frames.latest(now:requestedAt)
                if frame == nil {
                    guard ProcessInfo.processInfo.systemUptime<deadline else {throw DesktopCaptureTransientError.frameNotReady}
                    try await Task.sleep(nanoseconds:10_000_000)
                }
            }
            let data=try await encoder.encode(frame!,rect:target.rect,screen:target.screenFrame,maximumDimension:maximumDimension)
            try Task.checkCancellation()
            guard token==generation else {throw CancellationError()}
            try frame!.requireFresh(at:ProcessInfo.processInfo.systemUptime)
            return data
        } catch {markPermissionFailure(error);throw error}
    }

    private func ensureStream(display id:CGDirectDisplayID,screen:CGRect,pixels:CGSize) async throws {
        if stream != nil, displayID==id, screenFrame==screen, pixelSize==pixels{return}
        let expectedGeneration=generation+1
        await stop()
        try Task.checkCancellation()
        guard generation==expectedGeneration else{throw CancellationError()}
        let token=generation
        if content?.displays.contains(where:{$0.displayID==id}) == false {content=nil}
        try await prepare()
        guard token==generation, let content,
              let display=content.displays.first(where:{$0.displayID==id}) else {throw ScanError("显示器已变化，请重新开始扫码。")}
        let ownApps=content.applications.filter{$0.processID==ProcessInfo.processInfo.processIdentifier}
        guard !ownApps.isEmpty else {throw ScanError("无法排除本 App，请重新打开 App。")}
        let filter=SCContentFilter(display:display,excludingApplications:ownApps,exceptingWindows:[])
        let config=SCStreamConfiguration()
        // Capture a stable full-display surface. Moving/resizing the consumer only changes its crop.
        config.sourceRect=CGRect(origin:.zero,size:screen.size)
        config.width=Int(pixels.width);config.height=Int(pixels.height)
        config.pixelFormat=kCVPixelFormatType_32BGRA
        config.minimumFrameInterval=CMTime(value:1,timescale:30)
        config.queueDepth=3;config.showsCursor=false;config.capturesAudio=false
        config.preservesAspectRatio=true;config.ignoreShadowsSingleWindow=true
        let output=DesktopStreamOutput()
        let stream=SCStream(filter:filter,configuration:config,delegate:output)
        try stream.addStreamOutput(output,type:.screen,sampleHandlerQueue:sampleQueue)
        self.output=output;self.stream=stream;displayID=id;screenFrame=screen;pixelSize=pixels
        do {
            let _:Void=try await captureOperation(timeout:5,message:"桌面连续采集启动超时，请重新开始扫码。") { reply in
                stream.startCapture { error in
                    let accepted=reply.finish(error.map{.failure($0)} ?? .success(()))
                    // A delayed successful start must not leak a stream after cancellation/timeout.
                    if !accepted, error == nil {stream.stopCapture(completionHandler:nil)}
                }
            }
            try Task.checkCancellation()
            guard token==generation else {throw CancellationError()}
        } catch {
            output.frames.finish(error)
            if self.stream === stream {await stop()}
            else {try? await stream.stopCapture()}
            throw error
        }
    }

    // Call when desktop-camera mode stops and before process termination.
    func stop() async {
        generation += 1
        output?.frames.finish()
        let previous=stream
        stream=nil;output=nil;displayID=nil;screenFrame=nil;pixelSize=nil
        guard let previous else {await stoppingTask?.value;return}
        let cleanup=Task {
        // Cleanup must run even when its caller's capture Task has already been cancelled.
        let _:Void?=try? await withCheckedThrowingContinuation { continuation in
            let reply=CaptureReply<Void>()
            reply.install(continuation)
            DispatchQueue.global().asyncAfter(deadline:.now()+3){reply.finish(.success(()))}
            previous.stopCapture{_ in reply.finish(.success(()))}
        }
        }
        stoppingTask=cleanup
        await cleanup.value
    }
    private func checkPermission() throws {
        if permissionBlocked && CGPreflightScreenCaptureAccess() {permissionBlocked=false}
        if permissionBlocked {throw ScanError("请处理系统授权后重新打开 App；本次运行不会重复请求权限。")}
    }
    private func markPermissionFailure(_ error:Error) {
        let e=error as NSError
        if e.domain==SCStreamErrorDomain && e.code==SCStreamError.Code.userDeclined.rawValue {permissionBlocked=true}
    }
    deinit {
        // Fallback for callers which release the owner without explicitly awaiting stop().
        stream?.stopCapture(completionHandler:nil)
    }
}
