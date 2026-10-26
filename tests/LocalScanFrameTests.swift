import AppKit
import AVFoundation

/// Hidden, own-window rendering only. No desktop capture, phone or shared UI input.
@main enum LocalScanFrameTests {
    @MainActor static func main() throws {
        _=NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
        let frame=ScanFrameController()
        guard let window=frame.window,let root=window.contentView else{fatalError("No frame window")}
        defer{frame.onClose=nil;window.close()}
        precondition(!window.isOpaque && window.backgroundColor == .clear,"Frame is not truly transparent")
        precondition(root.layer?.sublayers?.contains(where:{$0 is AVSampleBufferDisplayLayer}) != true,
                     "Frame unexpectedly contains a phone video preview")
        window.setFrameOrigin(NSPoint(x:321,y:123))
        precondition(frame.captureRect == CGRect(x:337,y:139,width:320,height:320),"Capture and visible opening differ")
        root.layoutSubtreeIfNeeded()
        guard let image=root.bitmapImageRepForCachingDisplay(in:root.bounds) else{fatalError("No own view bitmap")}
        root.cacheDisplay(in:root.bounds,to:image)
        precondition((image.colorAt(x:image.pixelsWide/2,y:image.pixelsHigh/2)?.alphaComponent ?? 1)<0.01,
                     "Scan opening has an opaque fill")
        func buttons(_ view:NSView)->[NSButton] {
            (view as? NSButton).map{[$0]} ?? view.subviews.flatMap{buttons($0)}
        }
        let controls=buttons(root)
        var pauses=0,rescans=0,returns=0
        frame.onPause={pauses+=1};frame.onRescan={rescans+=1};frame.onClose={returns+=1}
        controls.first{$0.title=="暂停"}?.performClick(nil)
        frame.setPaused(true)
        precondition(controls.contains{$0.title=="继续"},"Paused frame has no resume")
        controls.first{$0.title=="继续"}?.performClick(nil)
        controls.first{$0.title=="再扫"}?.performClick(nil)
        controls.first{$0.title=="返回"}?.performClick(nil)
        window.cancelOperation(nil)
        window.performClose(nil)
        window.close()
        precondition(pauses==2 && rescans==1 && returns==4,"Frame controls, Escape or window close failed")
        if CommandLine.arguments.contains("--render-fixture"),let data=image.representation(using:.png,properties:[:]) {
            try data.write(to:URL(fileURLWithPath:".local/local-scan-frame-fixture.png"))
        }
        print("PASS: transparent opening, matched ROI, no video surface, pause/resume/retry/return/Escape")
    }
}
