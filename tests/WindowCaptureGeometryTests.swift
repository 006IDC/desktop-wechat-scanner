import AppKit
import CoreGraphics

/// Default: immutable synthetic rectangles/metadata only. --own-window also
/// queries fully transparent self-owned windows moved programmatically; never native drag.
@main enum WindowCaptureGeometryTests {
    private static func require(_ value:Bool,_ message:String) {
        if !value {fatalError(message)}
    }
    private static func cgBounds(_ frame:CGRect,top:CGFloat) -> CGRect {
        CGRect(x:frame.minX,y:top-frame.maxY,width:frame.width,height:frame.height)
    }
    @MainActor static func main() {
        if CommandLine.arguments.dropFirst().contains("--own-window") {ownWindowIntegration();return}
        let top:CGFloat=1080
        let cachedFrame=CGRect(x:100,y:200,width:360,height:700)
        let preview=CGRect(x:112,y:250,width:336,height:570)
        func corrected(_ server:CGRect?,primaryTop:CGFloat?=1080,frame:CGRect?=nil) -> CGRect {
            WindowCaptureGeometry.correctedRect(cachedRect:preview,appKitFrame:frame ?? cachedFrame,
                                                windowServerBounds:server,primaryScreenTop:primaryTop)
        }
        require(corrected(cgBounds(cachedFrame,top:top))==preview,"Stationary window changed ROI")

        // AppKit frame deliberately remains unchanged throughout this drag.
        for delta in [CGPoint(x:30,y:0),CGPoint(x:-75,y:90),CGPoint(x:225,y:-180)] {
            let server=cachedFrame.offsetBy(dx:delta.x,dy:delta.y)
            let result=corrected(cgBounds(server,top:top))
            require(result==preview.offsetBy(dx:delta.x,dy:delta.y),"Cached frame drag translation incorrect")
            require(result.size==preview.size,"Movement changed ROI size/aspect")
        }
        // Secondary displays can be left of, above, or below the primary. Use
        // the primary top in every case; no clipping or display-local origin.
        for origin in [CGPoint(x:-1600,y:100),CGPoint(x:-400,y:1300),CGPoint(x:300,y:-1000)] {
            let server=CGRect(origin:origin,size:cachedFrame.size)
            let expected=preview.offsetBy(dx:origin.x-cachedFrame.minX,dy:origin.y-cachedFrame.minY)
            require(corrected(cgBounds(server,top:top))==expected,"Negative/vertical display coordinate mapping failed")
        }
        let retina=cachedFrame.offsetBy(dx:15.5,dy:-9.5)
        require(corrected(cgBounds(retina,top:top))==preview.offsetBy(dx:15.5,dy:-9.5),
                "Retina point displacement was scaled or rounded")
        require(corrected(nil)==preview,"Missing WindowServer data changed ROI")
        require(corrected(.zero)==preview,"Zero-sized server bounds were accepted")
        require(corrected(.null)==preview,"Null server bounds were accepted")
        require(corrected(CGRect(x:CGFloat.nan,y:1,width:360,height:700))==preview,"NaN server bounds were accepted")
        require(corrected(CGRect(x:1,y:1,width:CGFloat.infinity,height:700))==preview,"Infinite server bounds were accepted")
        require(corrected(cgBounds(retina,top:top),primaryTop:nil)==preview,"Missing primary screen changed ROI")
        require(corrected(cgBounds(retina,top:top),primaryTop:.nan)==preview,"Invalid primary top changed ROI")
        require(corrected(cgBounds(retina,top:top),frame:.zero)==preview,"Invalid cached window frame was accepted")
        let resized=CGRect(x:300,y:300,width:500,height:850)
        require(corrected(cgBounds(resized,top:top))==preview,"In-flight resize scaled or remapped cached layout")
        let updatedPreview=CGRect(x:312,y:350,width:476,height:720)
        require(WindowCaptureGeometry.correctedRect(cachedRect:updatedPreview,appKitFrame:resized,
                                                     windowServerBounds:cgBounds(resized,top:top),primaryScreenTop:top)==updatedPreview,
                "Settled resize did not use new AppKit layout")

        func description(id:UInt32=42,pid:Int32=123,bounds:CGRect=cachedFrame) -> [String:Any] {
            [kCGWindowNumber as String:NSNumber(value:id),kCGWindowOwnerPID as String:NSNumber(value:pid),
             kCGWindowBounds as String:bounds.dictionaryRepresentation]
        }
        require(WindowCaptureGeometry.serverBounds(from:[description()],windowID:42,ownerPID:123)==cachedFrame,
                "Valid own-window metadata was rejected")
        require(WindowCaptureGeometry.serverBounds(from:[description(id:43)],windowID:42,ownerPID:123)==nil,"Foreign window ID was accepted")
        require(WindowCaptureGeometry.serverBounds(from:[description(pid:124)],windowID:42,ownerPID:123)==nil,"Foreign owner PID was accepted")
        var truncatedID=description();truncatedID[kCGWindowNumber as String]=NSNumber(value:UInt64(UInt32.max)+43)
        require(WindowCaptureGeometry.serverBounds(from:[truncatedID],windowID:42,ownerPID:123)==nil,"Out-of-range window ID was truncated into own ID")
        var fractionalID=description();fractionalID[kCGWindowNumber as String]=NSNumber(value:42.5)
        require(WindowCaptureGeometry.serverBounds(from:[fractionalID],windowID:42,ownerPID:123)==nil,"Fractional window ID was truncated into own ID")
        require(WindowCaptureGeometry.serverBounds(from:[description(bounds:.zero)],windowID:42,ownerPID:123)==nil,"Invalid own-window bounds were accepted")
        require(WindowCaptureGeometry.serverBounds(from:[],windowID:42,ownerPID:123)==nil,"Missing own-window metadata was accepted")
        require(WindowCaptureGeometry.serverBounds(from:[[kCGWindowNumber as String:42,kCGWindowOwnerPID as String:123]],windowID:42,ownerPID:123)==nil,
                "Missing own-window bounds were accepted")
        require(WindowCaptureGeometry.windowIDArray(kCGNullWindowID)==nil,"Null window ID array was created")
        for id:CGWindowID in [1,42,UInt32.max] {
            let array=WindowCaptureGeometry.windowIDArray(id)!
            require(CFArrayGetCount(array)==1,"Exact-ID array contains more than one ID")
            require(UInt(bitPattern:CFArrayGetValueAtIndex(array,0))==UInt(id),"Window ID was boxed instead of encoded as raw pointer-sized value")
        }
        print("PASS own-window ID/PID metadata validation; stationary/cached native-drag geometry; negative/above/below displays; Retina points; missing/invalid server fallback; resize fallback and settled layout. Synthetic only, no native drag or UI performed.")
    }

    @MainActor private static func ownWindowIntegration() {
        // WindowServer gives never-ordered windows zero bounds. Register two
        // fully transparent, click-through windows behind other windows instead;
        // never activate, move the pointer, take pixels or touch another app.
        let app=NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.finishLaunching()
        guard let primary=NSScreen.screens.first else {fatalError("No Quartz GUI session for own-window integration")}
        let origin=CGPoint(x:primary.frame.midX-120,y:primary.frame.midY-90)
        let window=NSWindow(contentRect:CGRect(origin:origin,size:CGSize(width:240,height:180)),
                            styleMask:[.titled],backing:.buffered,defer:false)
        let decoy=NSWindow(contentRect:CGRect(x:origin.x+280,y:origin.y,width:100,height:100),
                           styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;decoy.isReleasedWhenClosed=false
        for own in [window,decoy] {
            own.alphaValue=0;own.ignoresMouseEvents=true;own.orderBack(nil)
        }
        RunLoop.current.run(until:Date(timeIntervalSinceNow:0.05))
        defer{window.close();decoy.close()}
        require(window.alphaValue==0 && decoy.alphaValue==0,"Own-window integration unexpectedly showed UI")
        let id=CGWindowID(window.windowNumber),pid=ProcessInfo.processInfo.processIdentifier
        require(id != CGWindowID(decoy.windowNumber),"Fixture windows share one identifier")
        let cachedFrame=window.frame,cachedPreview=cachedFrame.insetBy(dx:12,dy:25),top=primary.frame.maxY
        var queryMilliseconds=[Double](),maximumError:CGFloat=0
        func query() -> CGRect {
            let began=ProcessInfo.processInfo.systemUptime
            guard let descriptions=WindowCaptureGeometry.ownWindowDescriptions(for:window) else {fatalError("Own exact-ID metadata query returned nil")}
            queryMilliseconds.append((ProcessInfo.processInfo.systemUptime-began)*1000)
            require(descriptions.count==1,"Exact-ID query returned zero or multiple windows")
            guard let bounds=WindowCaptureGeometry.serverBounds(from:descriptions,windowID:id,ownerPID:pid) else {
                fatalError("Own exact-ID metadata failed ID/PID/bounds validation: \(descriptions.first?[kCGWindowBounds as String] as Any)")
            }
            return bounds
        }
        for delta in [CGPoint.zero,CGPoint(x:35,y:0),CGPoint(x:-20,y:45),CGPoint(x:50,y:-30),CGPoint(x:-40,y:-25)] {
            window.setFrameOrigin(CGPoint(x:cachedFrame.minX+delta.x,y:cachedFrame.minY+delta.y))
            let expectedFrame=window.frame
            let deadline=ProcessInfo.processInfo.systemUptime+0.5
            var bounds=query()
            while abs(bounds.minX-expectedFrame.minX)>1 || abs((top-bounds.maxY)-expectedFrame.minY)>1 {
                require(ProcessInfo.processInfo.systemUptime<deadline,"WindowServer bounds did not follow programmatic own-window movement")
                RunLoop.current.run(until:Date(timeIntervalSinceNow:0.005))
                bounds=query()
            }
            let actual=WindowCaptureGeometry.correctedRect(cachedRect:cachedPreview,appKitFrame:cachedFrame,
                                                           windowServerBounds:bounds,primaryScreenTop:top)
            let expected=cachedPreview.offsetBy(dx:expectedFrame.minX-cachedFrame.minX,dy:expectedFrame.minY-cachedFrame.minY)
            let error=hypot(actual.minX-expected.minX,actual.minY-expected.minY)
            maximumError=max(maximumError,error)
            require(error<=1 && actual.size==cachedPreview.size,"Real metadata correction changed point scale or ROI dimensions")
            let currentPreview=expectedFrame.insetBy(dx:12,dy:25)
            let current=WindowCaptureGeometry.correctedCaptureRect(for:window,cachedRect:currentPreview)
            require(hypot(current.minX-currentPreview.minX,current.minY-currentPreview.minY)<=1,"Integrated correction moved a current own-window ROI")
        }
        for _ in 0..<120 {_=query()}
        let sorted=queryMilliseconds.sorted()
        let p50=sorted[sorted.count/2],p95=sorted[Int(Double(sorted.count-1)*0.95)]
        require(window.alphaValue==0 && decoy.alphaValue==0 && window.ignoresMouseEvents && decoy.ignoresMouseEvents,
                "Own-window integration made transparent/click-through windows visible or interactive")
        print(String(format:"PASS own_window_api programmed_positions=5 query_samples=%d query_p50_ms=%.4f query_p95_ms=%.4f query_max_ms=%.4f maximum_geometry_error_pt=%.4f; exact_ID_only_with_decoy; transparent_clickthrough_windows; no_native_drag_no_pixels_no_phone",sorted.count,p50,p95,sorted.last!,maximumError))
    }
}
