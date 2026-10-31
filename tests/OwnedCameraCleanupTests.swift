import Foundation
@main enum OwnedCameraCleanupTests {
    static func state(streams:Int=1,generation:Int=1,ownerKnown:Bool=true,owner:String?="com.tencent.mm",display:Int=7,
                      component:String="com.tencent.mm/.plugin.scanner.ui.BaseScanUI") throws -> PhoneCameraState {
        let data:[String:Any]=["version":1,"generation":generation,"activeStreams":streams,
            "activities":[["displayId":display,"component":component]],"desktopHome":true,
            "cameraOwner":owner as Any? ?? NSNull(),"ownerKnown":ownerKnown,"ownerGeneration":3]
        return try PhoneCameraState.decode(JSONSerialization.data(withJSONObject:data))
    }
    static func run(_ states:[PhoneCameraState]) -> (Bool,Int) {
        var reads=0,clock=0.0
        do {
            try OwnedCameraCleanup.quiesce(read:{let value=states[min(reads,states.count-1)];reads+=1;return value},
                now:{clock},wait:{clock+=0.1})
            return (true,reads)
        } catch {return (false,reads)}
    }
    static func main() throws {
        let active=try state(),idle=try state(streams:0,owner:nil)
        var r=run([idle]);precondition(r.0 && r.1==2,"Closure needs two matching observations")
        r=run([try state(streams:0)]);precondition(!r.0,"Idle but still-open camera was released")
        r=run([try state(streams:0,ownerKnown:false,owner:nil)]);precondition(!r.0,"Unknown owner was released")
        r=run([active,active,idle,idle]);precondition(r.0 && r.1==4)
        r=run([idle,try state(streams:0,generation:2,owner:nil),idle,idle]);precondition(r.0 && r.1==4,"Unstable generation was accepted")
        r=run([active]);precondition(!r.0 && r.1<30,"Live camera was treated as safe to destroy")
        var failed=false
        do {try OwnedCameraCleanup.quiesce(read:{throw ScanError("read failure")})} catch {failed=true}
        precondition(failed,"Status failure was ignored")
        let failedProducer:[String:Any]=["version":1,"generation":1,"activeStreams":0,"activities":[],"desktopHome":true,
            "ownerKnown":true,"cameraOwner":NSNull(),"ownerGeneration":3,"requestDriverHealthy":false]
        let closed=try PhoneCameraState.decode(JSONSerialization.data(withJSONObject:failedProducer))
        precondition(closed.ownerKnown && !closed.requestDriverHealthy && closed.captureActivity()==nil)
        r=run([closed]);precondition(r.0 && r.1==2,"A failed producer made known closed ownership impossible to confirm")
        print("PASS owned camera cleanup: no app input, stable known closed owner twice, fail closed on active/unknown/read error")
    }
}
