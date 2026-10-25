import Foundation
import CoreVideo
import Vision

/// Synthetic-only phone integration. No camera or chat frame is saved or printed.
private final class RawMirrorSink: @unchecked Sendable {
    struct Snapshot: @unchecked Sendable {
        let frames:Int
        let latest:CVPixelBuffer?
        let receivedAt:TimeInterval
        let failed:Bool
    }
    private let lock=NSLock()
    private var frames=0, latest:CVPixelBuffer?, receivedAt=0.0, failed=false
    func frame(_ pixelBuffer:CVPixelBuffer) {
        lock.withLock {
            frames+=1;latest=pixelBuffer;receivedAt=ProcessInfo.processInfo.systemUptime
        }
    }
    func fail() {lock.withLock {failed=true}}
    func snapshot()->Snapshot {
        lock.withLock {Snapshot(frames:frames,latest:latest,receivedAt:receivedAt,failed:failed)}
    }
}

@main enum RawMirrorIntegration {
    private static let expected="006IDC20261025C3"

    private static func words(_ pixelBuffer:CVPixelBuffer) throws -> [(String,CGRect)] {
        let request=VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages=["zh-Hans","en-US"]
        try VNImageRequestHandler(cvPixelBuffer:pixelBuffer).perform([request])
        return (request.results ?? []).compactMap { item in
            guard let value=item.topCandidates(1).first?.string else{return nil}
            let b=item.boundingBox
            return (value,CGRect(x:b.minX,y:1-b.maxY,width:b.width,height:b.height))
        }
    }
    private static func words(_ data:Data) throws -> [(String,CGRect)] {
        let request=VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages=["zh-Hans","en-US"]
        try VNImageRequestHandler(data:data).perform([request])
        return (request.results ?? []).compactMap { item in
            guard let value=item.topCandidates(1).first?.string else{return nil}
            let b=item.boundingBox
            return (value,CGRect(x:b.minX,y:1-b.maxY,width:b.width,height:b.height))
        }
    }
    private static func verifySyntheticQR(_ data:Data) throws {
        let request=VNDetectBarcodesRequest()
        request.symbologies=[.qr]
        try VNImageRequestHandler(data:data).perform([request])
        guard request.results?.contains(where:{$0.payloadStringValue==expected})==true else {
            throw ScanError("Synthetic C3 fixture is not the expected QR")
        }
    }
    private static func waitForFrame(_ sink:RawMirrorSink,
                                     after:TimeInterval=0,timeout:TimeInterval=8) async throws -> RawMirrorSink.Snapshot {
        let deadline=ProcessInfo.processInfo.systemUptime+timeout
        while ProcessInfo.processInfo.systemUptime<deadline {
            let state=sink.snapshot()
            guard !state.failed else{throw ScanError("Mirror stream failed")}
            if state.latest != nil && state.receivedAt>after {return state}
            try await Task.sleep(nanoseconds:80_000_000)
        }
        throw ScanError("Mirror first frame timed out")
    }
    private static func scannerVisible(_ sink:RawMirrorSink,after:TimeInterval,
                                       timeout:TimeInterval=8) async throws -> RawMirrorSink.Snapshot? {
        let deadline=ProcessInfo.processInfo.systemUptime+timeout
        var previous=0
        while ProcessInfo.processInfo.systemUptime<deadline {
            let state=sink.snapshot()
            guard !state.failed else{throw ScanError("Virtual mirror failed")}
            if state.frames>previous,state.receivedAt>after,let frame=state.latest {
                previous=state.frames
                if try words(frame).contains(where:{$0.0.replacingOccurrences(of:" ",with:"").contains("扫一扫")}) {
                    return state
                }
            }
            try await Task.sleep(nanoseconds:250_000_000)
        }
        return nil
    }
    private static func resultVisible(_ phone:PhoneSession) async throws -> Bool {
        for _ in 0..<14 {
            try await Task.sleep(nanoseconds:500_000_000)
            if try words(await phone.screenshot()).contains(where:{$0.0.contains(expected)}) {return true}
        }
        return false
    }
    static func main() async {
        guard CommandLine.arguments.count>=2 else {
            print("USAGE RawMirrorIntegration <resources-directory> [synthetic-c3-image]")
            exit(2)
        }
        let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        let resources=URL(fileURLWithPath:CommandLine.arguments[1])
        let server=root.appendingPathComponent(".tools/scrcpy/scrcpy-server-v5.0.1")
        let fixture=CommandLine.arguments.count>2 ? URL(fileURLWithPath:CommandLine.arguments[2]) : root.appendingPathComponent(".local/app-scan-test.png")
        let phone=PhoneSession(resources:resources)
        let physical=MirrorSession(),virtual=MirrorSession()
        let physicalSink=RawMirrorSink(),virtualSink=RawMirrorSink()
        var moved=false,connected=false
        do {
            let qr=try Data(contentsOf:fixture)
            try verifySyntheticQR(qr)
            _=try await phone.connect(openWechatOnConnect:false){_ in}
            connected=true
            let endpoint=try await phone.mirrorEndpoint()
            try await phone.openWechat(onVirtualDisplay:false)
            try await physical.startVideo(adbURL:resources.appendingPathComponent("adb"),serverURL:server,
                                          serial:endpoint.serial,displayID:0,
                                          onFrame:{physicalSink.frame($0)},onFailure:{_ in physicalSink.fail()})
            _=try await waitForFrame(physicalSink)
            print("PASS physical_raw_first_frame");fflush(stdout)
            try await virtual.startVideo(adbURL:resources.appendingPathComponent("adb"),serverURL:server,
                                         serial:endpoint.serial,displayID:endpoint.display,
                                         onFrame:{virtualSink.frame($0)},onFailure:{_ in virtualSink.fail()})
            // An empty virtual display need not emit a frame until a task arrives.
            print("PASS dual_raw_streams_ready physical_frames=\(physicalSink.snapshot().frames) virtual_frames=\(virtualSink.snapshot().frames)")

            try await Task.sleep(nanoseconds:550_000_000)
            guard let homeFrame=physicalSink.snapshot().latest else{throw ScanError("Physical frame unavailable")}
            let home=try words(homeFrame)
            let titles=home.filter{$0.0.hasPrefix("微信") && $0.1.midY<0.20}
            guard titles.count==1,
                  home.contains(where:{$0.0.contains("通讯录") && $0.1.midY>0.78}),
                  home.contains(where:{$0.0.contains("发现") && $0.1.midY>0.78}) else {
                throw ScanError("Expected single-header WeChat home; no touch sent")
            }
            print("PASS physical_wechat_single_header")
            physical.tap(x:665.0/720,y:titles[0].1.midY)
            try await Task.sleep(nanoseconds:800_000_000)
            guard let menuFrame=physicalSink.snapshot().latest else{throw ScanError("Menu frame unavailable")}
            let menu=try words(menuFrame)
            guard menu.contains(where:{$0.0.contains("添加朋友")}),
                  let scan=menu.first(where:{$0.0.contains("扫一扫")}) else {
                throw ScanError("Expected WeChat menu; no scanner touch sent")
            }
            physical.tap(x:scan.1.midX,y:scan.1.midY)
            try await Task.sleep(nanoseconds:800_000_000)
            guard let physicalScanner=try await phone.foreground(onVirtualDisplay:false),
                  physicalScanner.hasPrefix("com.tencent.mm/"),
                  physicalScanner.lowercased().contains("scanner") else {
                throw ScanError("Expected physical WeChat scanner before task move")
            }
            print("PASS physical_scanner_open")

            let moveStart=ProcessInfo.processInfo.systemUptime
            try await phone.moveWechat(toVirtualDisplay:true)
            moved=true
            let moveEnd=ProcessInfo.processInfo.systemUptime
            let first=try await waitForFrame(virtualSink,after:moveStart)
            let moveToFirst=(first.receivedAt-moveStart)*1000
            let moveCommand=(moveEnd-moveStart)*1000
            print(String(format:"MOVE_TO_FIRST_VIRTUAL_FRAME move_command_ms=%.3f total_ms=%.3f physical_frames=%d virtual_frames=%d",
                         moveCommand,moveToFirst,physicalSink.snapshot().frames,first.frames))
            guard let virtualScanner=try await phone.foreground(onVirtualDisplay:true),
                  virtualScanner.hasPrefix("com.tencent.mm/"),
                  virtualScanner.lowercased().contains("scanner"),
                  let scannerFrame=try await scannerVisible(virtualSink,after:moveStart) else {
                throw ScanError("Scanner not ready on virtual mirror")
            }
            print(String(format:"PASS virtual_scanner_raw_preview scanner_frame_ms=%.3f",(scannerFrame.receivedAt-moveStart)*1000))

            try await phone.clear(epoch:2)
            try await phone.frame(qr,epoch:2)
            guard try await resultVisible(phone) else{throw ScanError("Synthetic C3 QR result not visible")}
            print("PASS synthetic_c3_result virtual_frames=\(virtualSink.snapshot().frames)")

            let returnStart=ProcessInfo.processInfo.systemUptime
            try await phone.moveWechat(toVirtualDisplay:false)
            moved=false
            guard try await phone.foreground(onVirtualDisplay:false)?.hasPrefix("com.tencent.mm/")==true else {
                throw ScanError("WeChat result not returned to physical display")
            }
            _=try await waitForFrame(physicalSink,after:returnStart)
            print("PASS result_returned_physical")
            try await phone.clear(epoch:3)
            await virtual.stop();await physical.stop()
            try await phone.mainHome()
            let cleanup=await phone.disconnect();connected=false
            guard cleanup.isEmpty else{throw ScanError("Phone cleanup incomplete")}
            print("PASS dual_mirror_and_camera_cleanup")
        } catch {
            if moved {try? await phone.moveWechat(toVirtualDisplay:false)}
            if connected {try? await phone.clear(epoch:4)}
            await virtual.stop();await physical.stop()
            if connected {
                let cleanup=await phone.disconnect()
                print(cleanup.isEmpty ? "CLEANUP_PASS" : "CLEANUP_INCOMPLETE")
            }
            print("FAILED_RAW_MIRROR_INTEGRATION",error.localizedDescription)
            exit(1)
        }
    }
}
