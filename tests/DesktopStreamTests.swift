import AppKit
import CoreImage
import ScreenCaptureKit
import ImageIO

@main struct DesktopStreamTests {
    static func require(_ condition:Bool,_ message:String) {
        guard condition else{fatalError(message)}
    }
    static func rejects(_ block:() throws -> Void) {
        do {try block();fatalError("Expected rejection")}
        catch {require(!(error is DesktopCaptureTransientError),"Fatal input/lifecycle error became a retryable frame error")}
    }
    static func fixture() throws -> CVPixelBuffer {
        var buffer:CVPixelBuffer?
        let status=CVPixelBufferCreate(kCFAllocatorDefault,400,200,kCVPixelFormatType_32BGRA,
                                      [kCVPixelBufferCGImageCompatibilityKey:true,kCVPixelBufferCGBitmapContextCompatibilityKey:true] as CFDictionary,&buffer)
        require(status==kCVReturnSuccess,"Synthetic pixel allocation failed: \(status)")
        let pixels=buffer!
        CVBufferSetAttachment(pixels,kCVImageBufferCGColorSpaceKey,CGColorSpace(name:CGColorSpace.sRGB)!, .shouldPropagate)
        CVPixelBufferLockBaseAddress(pixels,[])
        let base=CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to:UInt8.self)
        let stride=CVPixelBufferGetBytesPerRow(pixels)
        // Raw screen buffer row zero is at the TOP: red/green above blue/yellow.
        for y in 0..<200 {for x in 0..<400 {
            let offset=y*stride+x*4
            let top=y<100,left=x<200
            base[offset]=top ? 0 : (left ? 255 : 0)
            base[offset+1]=left ? 0 : 255
            base[offset+2]=top ? (left ? 255 : 0) : (left ? 0 : 255)
            base[offset+3]=255
        }}
        CVPixelBufferUnlockBaseAddress(pixels,[])
        return pixels
    }
    static func verifyJPEG(_ data:Data,width:Int,height:Int,color:(Int,Int,Int),at point:CGPoint?=nil) throws {
        let source=CGImageSourceCreateWithData(data as CFData,nil)!
        let image=CGImageSourceCreateImageAtIndex(source,0,nil)!
        require(image.width==width && image.height==height,"JPEG aspect/size incorrect")
        let bitmap=NSBitmapImageRep(cgImage:image)
        let sample=bitmap.colorAt(x:point.map{Int($0.x)} ?? width/2,y:point.map{Int($0.y)} ?? height/2)!.usingColorSpace(.sRGB)!
        require(abs(Int(sample.redComponent*255)-color.0)<64 && abs(Int(sample.greenComponent*255)-color.1)<64 && abs(Int(sample.blueComponent*255)-color.2)<64,
                "Crop vertically flipped or on wrong display quadrant: \(sample)")
    }
    @MainActor static func verifyBackgroundAdmission(screen:CGRect) async throws {
        // Deliberately occupy the main actor while a detached caller presents an
        // expired synthetic target. Admission must not read NSScreen, ask for
        // permission or wait for the main actor. No desktop stream is started.
        let capture=DesktopCapture(), completed=DispatchSemaphore(value:0)
        let expired=DesktopCaptureTarget(rect:screen,displayID:1,screenFrame:screen,
                                        pixelSize:CGSize(width:800,height:400),
                                        selectedAt:ProcessInfo.processInfo.systemUptime-1)
        let task=Task.detached { () -> Bool in
            defer {completed.signal()}
            do {_=try await capture.capture(expired);return false}
            catch let error as DesktopCaptureTransientError {return error == .frameExpired}
            catch {return false}
        }
        func occupyMainActorUntilCompletion() {
            require(completed.wait(timeout:.now()+2) == .success,"Target admission waited for occupied MainActor")
        }
        occupyMainActorUntilCompletion()
        require(await task.value,"Expired snapshot did not fail with typed transient error")
        require(!(await capture.permissionBlocked),"Synthetic target admission touched permission state")

        let canceled=Task.detached { () throws -> Data in
            withUnsafeCurrentTask{$0?.cancel()}
            return try await capture.capture(expired)
        }
        do {_=try await canceled.value;fatalError("Canceled target returned data")}
        catch is CancellationError {}
        await capture.stop()
    }
    static func main() async throws {
        let screen=CGRect(x:-800,y:300,width:400,height:200)
        let snapshot=DesktopCaptureTarget(rect:screen,displayID:1,screenFrame:screen,
                                          pixelSize:CGSize(width:800,height:400),selectedAt:10)
        try snapshot.validate();try snapshot.requireFresh(at:10.5)
        do {try snapshot.requireFresh(at:10.5001);fatalError("Expired UI snapshot accepted")}
        catch let error as DesktopCaptureTransientError {require(error == .frameExpired,"Wrong target expiry reason")}
        for invalidPixels in [CGSize(width:0,height:400),CGSize(width:CGFloat.nan,height:400),CGSize(width:800.5,height:400),CGSize(width:CGFloat.infinity,height:400)] {
            rejects {try DesktopCaptureTarget(rect:screen,displayID:1,screenFrame:screen,pixelSize:invalidPixels,selectedAt:10).validate()}
        }
        try await verifyBackgroundAdmission(screen:screen)
        let crop=try DesktopCaptureGeometry.pixelCrop(rect:CGRect(x:-700,y:350,width:200,height:100),screen:screen,pixels:CGSize(width:800,height:400))
        require(crop==CGRect(x:200,y:100,width:400,height:200),"Retina/global offset mapping failed")
        let tall=try DesktopCaptureGeometry.outputSize(CGSize(width:1600,height:3200),maximumDimension:1600)
        require(tall==CGSize(width:800,height:1600),"Portrait aspect ratio failed")
        let wide=try DesktopCaptureGeometry.outputSize(CGSize(width:2400,height:900),maximumDimension:1600)
        require(wide==CGSize(width:1600,height:600),"Landscape aspect ratio failed")
        let partialCrop=try DesktopCaptureGeometry.pixelCrop(rect:CGRect(x:-900,y:300,width:200,height:100),screen:screen,pixels:CGSize(width:800,height:400))
        require(partialCrop==CGRect(x:-200,y:0,width:400,height:200),"Partial ROI was clipped or enlarged")
        let other=CGRect(x:-400,y:300,width:400,height:200)
        require(try DesktopCaptureGeometry.screenIndex(for:CGRect(x:-450,y:350,width:200,height:100),screens:[screen,other])==1,"Largest-overlap display was not selected")
        require(try DesktopCaptureGeometry.screenIndex(for:CGRect(x:50,y:350,width:100,height:100),screens:[screen,other])==1,"Entirely offscreen ROI did not select nearest display")
        require(try DesktopCaptureGeometry.screenIndex(for:CGRect(x:0,y:0,width:100,height:100),screens:[])==nil,"Missing displays produced an index")
        rejects {_=try DesktopCaptureGeometry.pixelCrop(rect:CGRect(x:-800,y:300,width:0,height:100),screen:screen,pixels:CGSize(width:800,height:400))}
        rejects {_=try DesktopCaptureGeometry.pixelCrop(rect:CGRect(x:CGFloat.nan,y:300,width:100,height:100),screen:screen,pixels:CGSize(width:800,height:400))}
        rejects {_=try DesktopCaptureGeometry.screenIndex(for:CGRect(x:-800,y:300,width:0,height:100),screens:[screen])}
        rejects {_=try DesktopCaptureGeometry.screenIndex(for:CGRect(x:CGFloat.nan,y:300,width:100,height:100),screens:[screen])}
        let pixels=try fixture(), encoder=DesktopFrameEncoder()
        let partial=try encoder.jpeg(pixels,rect:CGRect(x:-900,y:300,width:200,height:100),screen:screen,maximumDimension:1600)
        try verifyJPEG(partial,width:200,height:100,color:(255,255,255),at:CGPoint(x:25,y:50))
        try verifyJPEG(partial,width:200,height:100,color:(0,0,255),at:CGPoint(x:175,y:50))
        let top=try encoder.jpeg(pixels,rect:CGRect(x:-800,y:450,width:200,height:100),screen:screen,maximumDimension:1600)
        try verifyJPEG(top,width:200,height:100,color:(255,255,255),at:CGPoint(x:100,y:25))
        try verifyJPEG(top,width:200,height:100,color:(255,0,0),at:CGPoint(x:100,y:75))
        let outside=try encoder.jpeg(pixels,rect:CGRect(x:100,y:700,width:200,height:100),screen:screen,maximumDimension:1600)
        for point in [CGPoint(x:5,y:5),CGPoint(x:100,y:50),CGPoint(x:195,y:95)] {
            try verifyJPEG(outside,width:200,height:100,color:(255,255,255),at:point)
        }
        let tallOutside=try encoder.jpeg(pixels,rect:CGRect(x:100,y:700,width:200,height:400),screen:screen,maximumDimension:200)
        try verifyJPEG(tallOutside,width:100,height:200,color:(255,255,255))
        try verifyJPEG(encoder.jpeg(pixels,rect:CGRect(x:-800,y:400,width:200,height:100),screen:screen,maximumDimension:1600),width:200,height:100,color:(255,0,0))
        try verifyJPEG(encoder.jpeg(pixels,rect:CGRect(x:-800,y:300,width:200,height:100),screen:screen,maximumDimension:1600),width:200,height:100,color:(0,0,255))
        try verifyJPEG(encoder.jpeg(pixels,rect:CGRect(x:-600,y:400,width:200,height:100),screen:screen,maximumDimension:100),width:100,height:50,color:(0,255,0))
        let store=DesktopFrameStore()
        require(try store.latest(now:10)==nil,"Uninitialized stream returned a frame")
        store.accept(pixels,status:.complete)
        require(try store.latest(now:10.1)?.pixels === pixels,"Latest surface missing")
        require(try store.latest(now:40)?.pixels === pixels,"Static desktop expired without a replacement or invalidation")
        require(try store.latest(now:40)?.selectedAt == 40,"Processing budget incorrectly used the old content-change time")
        store.accept(nil,status:.idle)
        require(try store.latest(now:40.8)?.pixels === pixels,"Idle status lost the current surface")
        let newer=try fixture()
        store.accept(newer,status:.complete)
        require(try store.latest(now:41.1)?.pixels === newer,"Newer surface did not replace previous frame")
        store.accept(nil,status:.suspended)
        require(try store.latest(now:41.3)==nil,"Suspended stream leaked its last frame")
        store.accept(pixels,status:.complete)
        store.accept(nil,status:.blank)
        require(try store.latest(now:41.4)==nil,"Blank stream leaked its last frame")
        store.accept(pixels,status:.complete)
        store.accept(nil,status:.stopped)
        require(try store.latest(now:41.5)==nil,"Stopped stream leaked its last frame")
        store.accept(pixels,status:.complete);store.finish()
        rejects {_=try store.latest(now:42.1)}
        store.accept(newer,status:.complete)
        rejects {_=try store.latest(now:43.1)}
        // A frame's ROI budget includes stream/queue/UI delays, not just JPEG work.
        let boundary=DesktopFrame(pixels:pixels,selectedAt:10)
        try boundary.requireFresh(at:10.5)
        do {try boundary.requireFresh(at:10.5001);fatalError("Accepted ROI beyond 500ms")}
        catch let error as DesktopCaptureTransientError {require(error == .frameExpired,"Wrong transient expiry reason")}
        let expired=DesktopFrame(pixels:pixels,selectedAt:ProcessInfo.processInfo.systemUptime-1)
        do {
            _=try await encoder.encode(expired,rect:screen,screen:screen,maximumDimension:1600)
            fatalError("Late encoder returned old ROI JPEG")
        } catch let error as DesktopCaptureTransientError {
            require(error == .frameExpired,"Expired frame did not preserve its retryable reason")
            require(!error.localizedDescription.isEmpty,"Transient frame error lacks a user-readable reason")
        }
        // No display/permission API is called: cancellation must not wedge the encoder.
        let canceled=Task { () throws -> Data in
            withUnsafeCurrentTask{$0?.cancel()}
            // Cancellation takes priority even when the selected frame is already old.
            return try await encoder.encode(expired,rect:screen,screen:screen,maximumDimension:1600)
        }
        do {_=try await canceled.value;fatalError("Canceled encoder returned data")}catch is CancellationError{}
        let encoded=try await encoder.encode(DesktopFrame(pixels:pixels,selectedAt:ProcessInfo.processInfo.systemUptime),rect:screen,screen:screen,maximumDimension:1600)
        require(!encoded.isEmpty,"Encoding after canceled call failed")
        print("PASS desktop geometry: Retina/offset/portrait/landscape/invalid; largest-overlap/nearest-display; synthetic JPEG partial-edge white padding, entirely-offscreen white/aspect, top/bottom orientation; latest replacement, static-without-heartbeats/idle/blank/suspended/stopped frames; Sendable target validation, detached admission while MainActor occupied, target cancellation; 500ms ROI expiry typed transient, cancellation priority/recovery")
    }
}
