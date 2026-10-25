import Foundation
import CoreGraphics

private final class FrameStats: @unchecked Sendable {
    private let lock=NSLock()
    private var count=0, width=0, height=0, failure:String?
    func frame(_ image:CGImage){lock.withLock{count+=1;width=image.width;height=image.height}}
    func fail(_ message:String){lock.withLock{failure=message}}
    func snapshot()->(Int,Int,Int,String?){lock.withLock{(count,width,height,failure)}}
}

@main struct MirrorIntegration {
    static func main() async {
        let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        let adb=root.appendingPathComponent(".tools/sdk/platform-tools/adb")
        let server=root.appendingPathComponent(".tools/scrcpy/scrcpy-server-v5.0.1")
        let mirror=MirrorSession(),stats=FrameStats()
        do {
            let rows=try ShellCommand.run(adb,["devices","-l"]).split(separator:"\n")
                .map{$0.split(whereSeparator:{$0==" " || $0=="\t"}).map(String.init)}
            let devices=rows.filter{$0.count>1 && $0[1]=="device" && $0.contains(where:{$0.hasPrefix("usb:")})}
            guard devices.count==1 else{throw ScanError("Expected one authorized USB device")}
            try await mirror.start(adbURL:adb,serverURL:server,serial:devices[0][0],displayID:0,
                                   onFrame:{stats.frame($0)},onFailure:{stats.fail($0)})
            try await Task.sleep(nanoseconds:3_000_000_000)
            let first=stats.snapshot()
            if let failure=first.3 {throw ScanError(failure)}
            guard first.0>0 else{throw ScanError("No decoded display-0 frame")}
            print("PASS display0 H264 hardware decoded",first.0,"frames",first.1,first.2);fflush(stdout)
            mirror.key(3) // User-requested phone mirror: navigate only to Home.
            try await Task.sleep(nanoseconds:2_000_000_000)
            let after=stats.snapshot()
            if let failure=after.3 {throw ScanError(failure)}
            guard after.0>first.0 else{throw ScanError("No frame after Home control")}
            print("PASS Home control produced new mirror frames",after.0-first.0);fflush(stdout)
            await mirror.stop()
            print("PASS mirror stopped")
        } catch {
            await mirror.stop();print("FAILED",error.localizedDescription);exit(1)
        }
    }
}
