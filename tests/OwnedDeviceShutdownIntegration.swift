import Foundation

/// Explicit USB device probe. Opens no third-party application, captures no
/// screen, and reports only fixed lifecycle stages. Not run by unit tests.
@main enum OwnedDeviceShutdownIntegration {
    static func main() async {
        guard CommandLine.arguments.count==4,CommandLine.arguments[1]=="--run-device-test" else {
            print("Requires --run-device-test <resources directory> <adb binary>");exit(2)
        }
        let resources=URL(fileURLWithPath:CommandLine.arguments[2])
        let phone=PhoneSession(resources:resources,adbURL:URL(fileURLWithPath:CommandLine.arguments[3]))
        var connected=false
        do {
            _=try await phone.connect(openWechatOnConnect:false,allowLockedApplications:true,desktopHome:true,balancedDisplay:true,realtimeVideo:true,progress:{_ in})
            connected=true
            let state=try await phone.cameraState()
            print("beforeCleanup streamCount=\(state.activeStreams) ownerKnown=\(state.ownerKnown) ownerClosed=\(state.cameraOwner==nil)")
        } catch {
            print("connectFailed stage=\(await phone.connectionStage)")
        }
        let problem=await phone.disconnect(),stage=await phone.cleanupStage
        let reasons=["verify_device","stop_owned_streams","detach_owned_surfaces","sleep_api","wait_owned_displays_off","verify_primary_unchanged"]
        let reason=reasons.first(where:{problem.contains($0)}) ?? "unspecified"
        print("cleanupSucceeded=\(problem.isEmpty) cleanupStage=\(stage) sleepFailureStage=\(reason)")
        exit(connected && problem.isEmpty ? 0:1)
    }
}
