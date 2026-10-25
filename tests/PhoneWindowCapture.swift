import AppKit
import Vision

@main struct PhoneWindowCapture {
    @MainActor static func main(){
        let app=NSApplication.shared;app.setActivationPolicy(.regular)
        let control=ControlWindowController();control.showWindow(nil)
        control.update(status:"桌面相机已开启",detail:"合成测试窗口",connected:true,busy:false,paused:false)
        control.setCameraActive(true)
        Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds:600_000_000)
                let values=try JSONDecoder().decode([Double].self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
                let captureRect=control.desktopCaptureRect
                guard captureRect.width>100,let window=control.window else{throw ScanError("Phone window capture region invalid")}
                let target=CGPoint(x:values[0]+values[2]/2,y:values[1]+values[3]/2)
                let origin=window.frame.origin
                window.setFrameOrigin(CGPoint(x:origin.x+target.x-captureRect.midX,y:origin.y+target.y-captureRect.midY))
                let capture=DesktopCapture();try await capture.prepare()
                try await Task.sleep(nanoseconds:400_000_000)
                for _ in 0..<3 {
                    let data=try await capture.capture(control.desktopCaptureRect)
                    let request=VNDetectBarcodesRequest();request.symbologies=[.qr]
                    try VNImageRequestHandler(data:data).perform([request])
                    guard request.results?.contains(where:{$0.payloadStringValue=="006IDC20261025C3"})==true else{throw ScanError("Behind-window QR not decoded")}
                    try data.write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
                }
                print("PASS real desktop behind phone window, self excluded, 3 QR frames")
                exit(0)
            } catch {print("FAILED",error.localizedDescription);exit(1)}
        }
        withExtendedLifetime(control){app.run()}
    }
}
