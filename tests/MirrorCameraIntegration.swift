import Foundation
import Vision
import ImageIO
import UniformTypeIdentifiers

private final class MirrorCounter: @unchecked Sendable {
    private let lock=NSLock();private var frames=0,failure:String?,last:CGImage?
    func frame(_ image:CGImage){lock.withLock{frames+=1;last=image}}
    func jpeg() -> Data? {lock.withLock {guard let last else{return nil};let data=NSMutableData();let dest=CGImageDestinationCreateWithData(data,UTType.jpeg.identifier as CFString,1,nil)!;CGImageDestinationAddImage(dest,last,nil);CGImageDestinationFinalize(dest);return data as Data}}
    func fail(_ value:String){lock.withLock{failure=value}}
    func read()->(Int,String?){lock.withLock{(frames,failure)}}
}
@main struct MirrorCameraIntegration {
    static func words(_ data:Data) throws -> [(String,CGRect)] {
        let request=VNRecognizeTextRequest();request.recognitionLevel = .accurate
        request.recognitionLanguages=["zh-Hans","en-US"]
        try VNImageRequestHandler(data:data).perform([request])
        return (request.results ?? []).compactMap{r in
            guard let value=r.topCandidates(1).first?.string else{return nil}
            let b=r.boundingBox
            return (value,CGRect(x:b.minX*720,y:(1-b.maxY)*1280,width:b.width*720,height:b.height*1280))
        }
    }
    static func main() async {
        let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        let resources=URL(fileURLWithPath:CommandLine.arguments[1])
        let phone=PhoneSession(resources:resources),mirror=MirrorSession(),counter=MirrorCounter()
        do {
            _=try await phone.connect(openWechatOnConnect:false){print($0);fflush(stdout)}
            let endpoint=try await phone.mirrorEndpoint()
            try await phone.openWechat(onVirtualDisplay:false)
            try await mirror.start(adbURL:resources.appendingPathComponent("adb"),serverURL:root.appendingPathComponent(".tools/scrcpy/scrcpy-server-v5.0.1"),serial:endpoint.serial,displayID:0,onFrame:{counter.frame($0)},onFailure:{counter.fail($0)})
            for _ in 0..<20 {
                if counter.read().0>0 {break}
                try await Task.sleep(nanoseconds:250_000_000)
            }
            let initial=counter.read()
            print("MIRROR_INITIAL",initial.0,initial.1 ?? "ok");fflush(stdout)
            guard initial.0>0 else{throw ScanError(initial.1 ?? "No virtual display frames")}
            try await Task.sleep(nanoseconds:700_000_000)
            let home=try words(counter.jpeg()!)
            let safe=["微信","通讯录","发现","我","扫一扫","发起群聊","添加朋友","关闭","文本","朋友圈"]
            print("KNOWN_HOME_LABELS",home.filter{safe.contains($0.0)}.map{$0.0});fflush(stdout)
            guard home.contains(where:{$0.0.contains("通讯录") && $0.1.midY>1000}),
                  home.contains(where:{$0.0.hasPrefix("微信") && $0.1.midY<250}) else{throw ScanError("Expected WeChat home; no tap")}
            let titles=home.filter{$0.0.hasPrefix("微信") && $0.1.midY<250}
            guard titles.count==1 else{throw ScanError("Duplicate WeChat header on physical display") }
            print("PASS single normal WeChat header");fflush(stdout)
            guard let title=titles.min(by:{$0.1.minY<$1.1.minY}) else {throw ScanError("Missing WeChat header")}
            mirror.tap(x:665.0/720,y:title.1.midY/1280)
            try await Task.sleep(nanoseconds:800_000_000)
            let menu=try words(counter.jpeg()!)
            let known=["微信","通讯录","发现","我","扫一扫","发起群聊","添加朋友"]
            print("KNOWN_MENU_LABELS",menu.filter{known.contains($0.0)}.map{$0.0});fflush(stdout)
            guard menu.contains(where:{$0.0.contains("添加朋友")}),let scan=menu.first(where:{$0.0.contains("扫一扫")}) else{throw ScanError("Expected WeChat menu; no tap")}
            mirror.tap(x:scan.1.midX/720,y:scan.1.midY/1280)
            try await Task.sleep(nanoseconds:800_000_000)
            let foreground=try await phone.foreground(onVirtualDisplay:false)
            print("SCAN_COMPONENT",foreground ?? "none");fflush(stdout)
            guard foreground?.lowercased().contains("scanner")==true else{throw ScanError("Scanner detection failed")}

            try await phone.moveWechat(toVirtualDisplay:true)
            await mirror.stop()
            try await mirror.start(adbURL:resources.appendingPathComponent("adb"),serverURL:root.appendingPathComponent(".tools/scrcpy/scrcpy-server-v5.0.1"),serial:endpoint.serial,displayID:endpoint.display,onFrame:{counter.frame($0)},onFailure:{counter.fail($0)})
            try await Task.sleep(nanoseconds:800_000_000)
            try await phone.clear(epoch:2)
            let source=CommandLine.arguments.count>2 ? URL(fileURLWithPath:CommandLine.arguments[2]) : root.appendingPathComponent(".local/app-scan-test.png")
            let qr=try Data(contentsOf:source)
            try await phone.frame(qr,epoch:2)
            try await Task.sleep(nanoseconds:1_000_000_000)

            var passed=false
            for _ in 0..<14 {
                try await Task.sleep(nanoseconds:500_000_000)
                if try words(await phone.screenshot()).contains(where:{$0.0.contains("006IDC20261025C3")}){passed=true;break}
            }
            let result=counter.read()
            if let failure=result.1 {throw ScanError(failure)}
            guard passed,result.0>0 else{throw ScanError("QR result or native mirror frames missing")}
            print("PASS native virtual-display mirror, touch input, scanner detection, synthetic QR",result.0);fflush(stdout)
            try await phone.moveWechat(toVirtualDisplay:false)
            guard try await phone.foreground(onVirtualDisplay:false)?.hasPrefix("com.tencent.mm/")==true else {throw ScanError("WeChat result not returned to physical display")}
            print("PASS scan result returned to physical mirror")
            await mirror.stop()
            try await phone.mainHome()
            let cleanup=await phone.disconnect()
            guard cleanup.isEmpty else{throw ScanError(cleanup)}
            print("PASS verified camera cleanup after mirror stop")
        } catch {
            await mirror.stop();print("FAILED",error.localizedDescription)
            print("CLEANUP",await phone.disconnect());exit(1)
        }
    }
}
