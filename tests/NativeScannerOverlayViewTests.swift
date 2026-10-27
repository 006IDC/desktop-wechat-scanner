import AppKit

@main enum NativeScannerOverlayViewTests {
    @MainActor static func main() {
        let app=NSApplication.shared;app.setActivationPolicy(.prohibited)
        let ui=ControlWindowController()
        let image=NSImage(size:NSSize(width:720,height:1280),flipped:false) {rect in
            NSColor.white.setFill();rect.fill();return true
        }
        ui.setPhoneImage(image)
        ui.window?.contentView?.layoutSubtreeIfNeeded()
        func find(_ view:NSView)->NSView? {
            if String(describing:type(of:view))=="PhonePreviewView" {return view}
            return view.subviews.lazy.compactMap(find).first
        }
        guard let window=ui.window,let root=window.contentView,let phone=find(root) else{fatalError("Missing native view")}
        var events=[UInt8]()
        ui.onTouch={action,_,_ in events.append(action)}
        let location=phone.convert(NSPoint(x:phone.bounds.midX,y:phone.bounds.midY),to:nil)
        let down=NSEvent.mouseEvent(with:.leftMouseDown,location:location,modifierFlags:[],timestamp:1,
            windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)!
        let up=NSEvent.mouseEvent(with:.leftMouseUp,location:location,modifierFlags:[],timestamp:2,
            windowNumber:window.windowNumber,context:nil,eventNumber:2,clickCount:1,pressure:0)!
        phone.mouseDown(with:down)
        precondition(events==[0],"Synthetic component touch did not start")
        let overlay=NativeScannerOverlay(display:7,package:"com.tencent.mm")
        ui.prepareNativeScanner(overlay)
        precondition(events==[0,1],"Calibration failed to release the active touch")
        phone.mouseDown(with:down);phone.mouseUp(with:up)
        precondition(events==[0,1],"Calibration accepted input through a stale frame")
        ui.showNativeScanner(overlay)
        precondition(ui.nativeScannerVisible && !window.isOpaque && window.styleMask.contains(.fullSizeContentView))
        phone.mouseDown(with:down)
        ui.freezeNativeScanner()
        precondition(events==[0,1,0,1],"QR handoff did not release the touch")
        phone.mouseDown(with:down);phone.mouseUp(with:up)
        precondition(events==[0,1,0,1],"Frozen scanner accepted input")
        ui.endNativeScanner()
        precondition(!ui.nativeScannerVisible && window.isOpaque && !window.styleMask.contains(.fullSizeContentView))
        phone.mouseDown(with:down);phone.mouseUp(with:up)
        precondition(events==[0,1,0,1,0,1],"Native input did not recover")
        phone.mouseDown(with:down)
        NotificationCenter.default.post(name:NSWindow.didResignKeyNotification,object:window)
        phone.mouseUp(with:up)
        precondition(events==[0,1,0,1,0,1,0,1],"Window focus loss left a pressed touch")
        print("PASS native overlay: full-window transparency and titlebar restoration; calibration/handoff release and reject touches; native input recovers. No phone, capture or OS input.")
    }
}
