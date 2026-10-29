import Foundation
import CoreGraphics

@main enum DiagnosticSnapshotScopeTests {
    static func main() async throws {
        let capture=DesktopCapture()
        let target=DesktopCaptureTarget(rect:CGRect(x:0,y:0,width:200,height:200),displayID:1,
            screenFrame:CGRect(x:0,y:0,width:1000,height:1000),pixelSize:CGSize(width:2000,height:2000),selectedAt:ProcessInfo.processInfo.systemUptime)
        do {_=try await capture.captureDiagnosticSnapshot(target);fatalError("Snapshot accepted a non-diagnostic desktop source")}
        catch let error as ScanError {precondition(error.message=="单帧研究需要既有授权和自有测试板。")}
        do {try await capture.startDiagnosticStream(target);fatalError("Warmup accepted a non-diagnostic source")}
        catch let error as ScanError {precondition(error.message=="连续预备需要既有授权和自有测试板。")}
        await capture.stop()
        print("PASS diagnostic snapshot/warmup reject ordinary desktop before metadata or capture access; no windows/device")
    }
}
