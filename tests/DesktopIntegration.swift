import AppKit
import Vision
@main struct DesktopIntegration {
    @MainActor static func main() {
        let app=NSApplication.shared;app.setActivationPolicy(.regular)
        let control=ControlWindowController();control.showWindow(nil)
        control.window?.setFrameOrigin(CGPoint(x:20,y:20))
        let scan=ScanFrameController()
        let values=try! JSONDecoder().decode([Double].self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
        scan.show();scan.window?.setFrameOrigin(CGPoint(x:values[0]-16,y:values[1]-16))
        Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds:700_000_000)
                let capture=DesktopCapture();try await capture.prepare()
                try await Task.sleep(nanoseconds:500_000_000)
                for _ in 0..<3 {
                    let data=try await capture.capture(scan.captureRect)
                    let qr=VNDetectBarcodesRequest();qr.symbologies=[.qr]
                    try VNImageRequestHandler(data:data).perform([qr])
                    guard qr.results?.contains(where:{$0.payloadStringValue==CommandLine.arguments[3]})==true else {throw ScanError("Captured QR differs from fixture")}
                    try data.write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
                    try await Task.sleep(nanoseconds:160_000_000)
                }
                print("PASS actual desktop frame, own transparent overlay excluded, 3 captures decoded")
                exit(0)
            } catch {print("FAILED",error.localizedDescription);exit(1)}
        }
        withExtendedLifetime((scan,control)){app.run()}
    }
}
