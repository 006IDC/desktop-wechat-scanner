import Foundation
import CoreVideo

private final class FrameCount: @unchecked Sendable {
    private let lock=NSLock();private var value=0
    func add(){lock.withLock{value+=1}}
    var count:Int {lock.withLock{value}}
}

/// Explicit device test. Does not export images, identifiers or application catalog.
@main struct AppWindowIntegration {
    static func main() async {
        guard CommandLine.arguments.contains("--run-device-test") else {print("Explicit --run-device-test required");return}
        let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        let adb=root.appendingPathComponent(".local/adb-bundle/bin/adb")
        let phone=PhoneSession(resources:root.appendingPathComponent("build"),adbURL:adb)
        let mirror=MirrorSession(),frames=FrameCount()
        do {
            let requestedEndpoint:String?
            if let index=CommandLine.arguments.firstIndex(of:"--wireless-endpoint") {
                guard CommandLine.arguments.indices.contains(index+1) else {throw ScanError("Missing wireless endpoint")}
                requestedEndpoint=try ADBEndpoint(CommandLine.arguments[index+1]).value
            } else {requestedEndpoint=nil}
            let devices=try await ADBConnectionManager(adbURL:adb).devices().filter {device in
                guard device.authorization == .authorized else{return false}
                if let requestedEndpoint {return device.transport == .wireless && device.serial == requestedEndpoint}
                return device.transport == .usb
            }
            guard devices.count==1 else {throw ScanError("Need exactly one selected authorized phone")}
            _=try await phone.connect(openWechatOnConnect:false,selectedSerial:devices[0].serial){_ in}
            let apps=try await phone.applications()
            guard let wechat=apps.first(where:{$0.packageName=="com.tencent.mm"}),let scanner=await phone.scannerDisplay() else {throw ScanError("WeChat scanner target unavailable")}
            print("PASS authenticated application catalog and reserved display");fflush(stdout)
            let extra=try await phone.createAppDisplay()
            if let settings=apps.first(where:{$0.packageName=="com.android.settings"}) {
                try await phone.launchApplication(settings,on:extra.id)
                guard try await phone.foreground(display:extra.id)?.hasPrefix("com.android.settings/")==true else {throw ScanError("Settings not on app display")}
                print("PASS independent Settings application display");fflush(stdout)
            }
            try await phone.closeAppDisplay(extra.id)
            print("PASS extra display task restoration and release");fflush(stdout)
            try await phone.launchApplication(wechat,on:scanner.id)
            let endpoint=try await phone.mirrorEndpoint()
            try await mirror.startVideo(adbURL:adb,serverURL:root.appendingPathComponent(".tools/scrcpy/scrcpy-server-v5.0.1"),serial:endpoint.serial,displayID:scanner.id,onFrame:{_ in frames.add()},onFailure:{_ in})
            try await Task.sleep(nanoseconds:2_000_000_000)
            guard frames.count>0,try await phone.foreground(display:scanner.id)?.hasPrefix("com.tencent.mm/")==true else {throw ScanError("WeChat independent mirror unavailable")}
            print("PASS WeChat independent display decoded frames",frames.count);fflush(stdout)
            await mirror.stop();try await phone.restoreScannerApplications()
            print("PASS WeChat task restored; reserved display retained");fflush(stdout)
            let cleanup=await phone.disconnect()
            guard cleanup.isEmpty else {throw ScanError("Cleanup requires recovery")}
            print("PASS all owned resources cleaned")
        } catch {
            await mirror.stop()
            let cleanup=await phone.disconnect()
            print("FAILED",error.localizedDescription,"cleanup_ok",cleanup.isEmpty);exit(1)
        }
    }
}
