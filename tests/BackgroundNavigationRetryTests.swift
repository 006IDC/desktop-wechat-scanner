import Foundation

@main enum BackgroundNavigationRetryTests {
    @MainActor static func main() throws {
        func frame(_ receipt:Double,_ launch:Double=1,_ now:Double=1.5)->Bool {
            BackgroundScanDiagnostic.navigationFrameIsCurrent(receivedAt:receipt,startCommandIssuedAt:launch,now:now)
        }
        precondition(frame(1.2),"Fresh post-command pixels were rejected merely because navigation started later")
        precondition(!frame(0.9),"Pre-command pixels became navigation evidence")
        precondition(!frame(2) && !frame(.nan) && !frame(1.2,.infinity) && !frame(1.2,1,.nan))
        precondition(!frame(1,1,2) && frame(1,1,1.999),"One-second input fence changed")
        precondition(!frame(-1,-2,0),"Invalid command clock was accepted")
        let component="com.example.camera/.Home"
        func state(owner:String?=nil,known:Bool=true,streams:Int=0,page:String?=nil)->PhoneCameraState {
            let fields:[String:Any]=["version":1,"generation":1,"activeStreams":streams,"desktopHome":true,
                "ownerKnown":known,"ownerGeneration":1,"cameraOwner":owner as Any? ?? NSNull(),
                "activities":[["displayId":7,"component":page ?? component]]]
            return try! PhoneCameraState.decode(JSONSerialization.data(withJSONObject:fields))
        }
        var retry=ScannerNavigationOCR.PlusRetry()
        func allowed(_ state:PhoneCameraState,_ time:Double=2,_ frame:Double=1.9,_ display:Int=7)->Bool {
            BackgroundScanDiagnostic.canRetryScan(state,display:display,component:component,at:time,frameReceivedAt:frame,retry:retry)
        }
        precondition(!allowed(state()),"No initial tap was recorded")
        retry.recordTap(at:1,frameReceivedAt:0.9)
        precondition(allowed(state()))
        precondition(!allowed(state(),1.7,1.6) && !allowed(state(),2,1),"Cooldown or post-tap evidence missing")
        precondition(!allowed(state(known:false)) && !allowed(state(owner:"com.example.camera")) && !allowed(state(streams:1)))
        precondition(!allowed(state(page:"com.example.camera/.Other")) && !allowed(state(),2,1.9,8),"Route changed")
        retry.recordTap(at:2,frameReceivedAt:1.9);retry.recordTap(at:3,frameReceivedAt:2.9)
        precondition(!allowed(state(),4,3.9),"Unbounded retries")
        print("PASS bounded same-route scan retry, known closed camera, cooldown and fresh post-tap frame; no UI or phone")
    }
}
