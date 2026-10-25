import AppKit
import Vision
import ImageIO
import UniformTypeIdentifiers

// Run only by the main agent against a separate QRBoard synthetic fixture.
// Arguments: rect.json output.jpg. The known payload is 006IDC20261025C3.
// stdout per-frame rows: frame_index capture_ms
// stdout final row: frame_count elapsed_s fps mean_ms p50_ms p95_ms max_ms
// Only the fixture rectangle from the final JPEG is persisted; all other frames stay in memory.
@main struct DesktopMovingCapture {
    private static let expected="006IDC20261025C3"
    private static func now() -> Double {ProcessInfo.processInfo.systemUptime}

    @MainActor private static func syntheticPhone() -> NSImage {
        NSImage(size:NSSize(width:1268,height:2756),flipped:false) { rect in
            NSColor(calibratedRed:0.06,green:0.15,blue:0.11,alpha:1).setFill();rect.fill()
            NSColor(calibratedRed:0.18,green:0.72,blue:0.43,alpha:1).setFill()
            CGRect(x:120,y:1050,width:1028,height:620).fill()
            ("合成测试画面" as NSString).draw(at:CGPoint(x:270,y:1400),withAttributes:[
                .font:NSFont.systemFont(ofSize:100,weight:.semibold),.foregroundColor:NSColor.white])
            ("不连接手机" as NSString).draw(at:CGPoint(x:350,y:1240),withAttributes:[
                .font:NSFont.systemFont(ofSize:75),.foregroundColor:NSColor.white])
            return true
        }
    }

    @MainActor private static func align(_ controller:ControlWindowController,to target:CGPoint) throws {
        guard let window=controller.window,let content=window.contentView else{throw ScanError("Missing synthetic test window")}
        content.layoutSubtreeIfNeeded()
        let region=controller.desktopCaptureRect
        guard region.width>100,region.height>100 else{throw ScanError("Invalid production capture rectangle")}
        let origin=window.frame.origin
        window.setFrameOrigin(CGPoint(x:origin.x+target.x-region.midX,y:origin.y+target.y-region.midY))
        content.layoutSubtreeIfNeeded();window.displayIfNeeded()
    }

    // Crop using JPEG's top-left raster convention. Pixels outside the explicitly
    // supplied synthetic QR rectangle are never written to disk.
    private static func fixtureJPEG(_ data:Data,captured:CGRect,fixture:CGRect) throws -> Data {
        guard captured.contains(fixture),let source=CGImageSourceCreateWithData(data as CFData,nil),
              let image=CGImageSourceCreateImageAtIndex(source,0,nil) else{throw ScanError("Synthetic QR does not fit inside the production phone capture rectangle")}
        let sx=CGFloat(image.width)/captured.width,sy=CGFloat(image.height)/captured.height
        let raw=CGRect(x:(fixture.minX-captured.minX)*sx,y:(captured.maxY-fixture.maxY)*sy,
                       width:fixture.width*sx,height:fixture.height*sy)
        // Round inward so no pixel outside the declared fixture is saved.
        let bounds=CGRect(x:ceil(raw.minX),y:ceil(raw.minY),
                          width:floor(raw.maxX)-ceil(raw.minX),height:floor(raw.maxY)-ceil(raw.minY))
        guard bounds.width>0,bounds.height>0,let cropped=image.cropping(to:bounds) else{throw ScanError("Cannot crop synthetic QR fixture")}
        let output=NSMutableData()
        guard let destination=CGImageDestinationCreateWithData(output,UTType.jpeg.identifier as CFString,1,nil) else{throw ScanError("Cannot encode final synthetic region")}
        CGImageDestinationAddImage(destination,cropped,[kCGImageDestinationLossyCompressionQuality:0.95] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else{throw ScanError("Cannot finish final synthetic JPEG")}
        return output as Data
    }

    @MainActor static func main() {
        let app=NSApplication.shared;app.setActivationPolicy(.regular)
        let controller=ControlWindowController()
        controller.setPhoneImage(syntheticPhone())
        controller.setCameraActive(true);controller.setMode("桌面相机")
        controller.update(status:"合成采集测试",detail:"不连接手机，仅验证独立二维码测试窗",connected:true,busy:false,paused:false)
        controller.showWindow(nil)
        Task { @MainActor in
            let capture=DesktopCapture()
            do {
                guard CommandLine.arguments.count==3 else{throw ScanError("Usage: DesktopMovingCapture rect.json output.jpg")}
                let values=try JSONDecoder().decode([Double].self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
                guard values.count==4,values.allSatisfy({$0.isFinite}),values[2]>0,values[3]>0 else{throw ScanError("Invalid synthetic fixture rectangle")}
                let fixture=CGRect(x:values[0],y:values[1],width:values[2],height:values[3])
                let center=CGPoint(x:fixture.midX,y:fixture.midY)
                try await Task.sleep(nanoseconds:600_000_000)
                try align(controller,to:center)
                guard controller.desktopCaptureRect.contains(fixture) else{throw ScanError("QRBoard fixture too large; use a synthetic QR side such as 180 points")}
                try await capture.prepare()
                try await Task.sleep(nanoseconds:400_000_000)
                var latencies:[Double]=[],last=Data(),lastRect=CGRect.zero
                let started=now()
                @MainActor func record() async throws {
                    let frameStarted=now(),rect=controller.desktopCaptureRect
                    let data=try await capture.capture(rect)
                    let duration=(now()-frameStarted)*1000
                    latencies.append(duration);last=data;lastRect=rect
                    print(String(format:"%d %.3f",latencies.count,duration))
                    let remainder=1.0/30-(now()-frameStarted)
                    if remainder>0 {try await Task.sleep(nanoseconds:UInt64(remainder*1_000_000_000))}
                }
                // A static display may stop delivering callbacks; this must remain usable.
                let staticDeadline=now()+3.1
                repeat {try await record()} while now()<staticDeadline
                // One round trip through exact left/right 30-point extremes, 61 captures.
                for index in 0...60 {
                    let offset=30*sin(2*Double.pi*Double(index)/60)
                    try align(controller,to:CGPoint(x:center.x+offset,y:center.y))
                    try await record()
                }
                try align(controller,to:center)
                try await record()
                let elapsed=now()-started
                let jpeg=try fixtureJPEG(last,captured:lastRect,fixture:fixture)
                let request=VNDetectBarcodesRequest();request.symbologies=[.qr]
                try VNImageRequestHandler(data:jpeg).perform([request])
                guard request.results?.contains(where:{$0.payloadStringValue==expected})==true else{throw ScanError("Final synthetic C3 QR not decoded")}
                try jpeg.write(to:URL(fileURLWithPath:CommandLine.arguments[2]),options:.atomic)
                await capture.stop()
                let sorted=latencies.sorted()
                func percentile(_ quantile:Double) -> Double {sorted[min(sorted.count-1,Int(ceil(quantile*Double(sorted.count)))-1)]}
                print(String(format:"%d %.3f %.3f %.3f %.3f %.3f %.3f",latencies.count,elapsed,Double(latencies.count)/elapsed,
                             latencies.reduce(0,+)/Double(latencies.count),percentile(0.50),percentile(0.95),sorted.last!))
                exit(0)
            } catch {
                await capture.stop()
                FileHandle.standardError.write(Data(("FAILED: "+error.localizedDescription+"\n").utf8))
                exit(1)
            }
        }
        withExtendedLifetime(controller){app.run()}
    }
}
