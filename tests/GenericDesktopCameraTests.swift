import Foundation
import CoreGraphics

@main enum GenericDesktopCameraTests {
    static func require(_ value:Bool,_ message:String="Check failed") {precondition(value,message)}
    enum Failure:Error {case synthetic}
    static func rejects(_ code:() throws -> Void) {
        do {try code();fatalError("Invalid camera source accepted")} catch {}
    }
    static func state(_ change:([String:Any])->[String:Any] = {$0}) throws -> PhoneCameraState {
        let fields:[String:Any] = ["version":1,"generation":2,"activeStreams":1,"desktopHome":true,
            "cameraOwner":"org.example.unadapted","ownerKnown":true,"ownerGeneration":5,
            "activities":[["displayId":7,"component":"org.example.unadapted/.AnyCameraPage"]],
            "desktopCameraSupported":true,"desktopCameraEnabled":true,"desktopCameraGeneration":3,
            "desktopCameraBindings":[["displayId":7,"packageName":"org.example.unadapted"]]]
        return try PhoneCameraState.decode(JSONSerialization.data(withJSONObject:change(fields)))
    }
    static func main() throws {
        let selected=try state()
        precondition(selected.scannerActivity()==nil && selected.captureActivity()?.displayId==7,"Third app still needs a scanner-page allowlist")
        for key in ["ownerKnown","desktopCameraEnabled"] {
            let blocked=try state{var f=$0;f[key]=false;if key=="desktopCameraEnabled"{f["desktopCameraBindings"]=[]};return f}
            precondition(blocked.captureActivity()==nil,"Camera use alone selected desktop input")
        }
        let wrong=try state{var f=$0;f["cameraOwner"]="org.other";return f};precondition(wrong.captureActivity()==nil)
        let unbound=try state{var f=$0;f["desktopCameraBindings"]=[];return f};precondition(unbound.captureActivity()==nil)
        let ambiguous=try state{var f=$0;f["activities"]=[["displayId":7,"component":"org.example.unadapted/.AnyCameraPage"],["displayId":8,"component":"org.example.unadapted/.Other"]];return f}
        precondition(ambiguous.captureActivity()==nil,"Ambiguous windows chose a camera target")
        for mutate:([String:Any])->[String:Any] in [
            {var f=$0;f["desktopCameraSupported"]=false;return f},
            {var f=$0;f["desktopCameraGeneration"] = -1;return f},
            {var f=$0;f["desktopCameraBindings"]=[["displayId":0,"packageName":"org.example.unadapted"]];return f},
            {var f=$0;f["desktopCameraBindings"]=[["displayId":7,"packageName":"bad;pkg"]];return f},
            {var f=$0;f["desktopCameraBindings"]=[["displayId":7,"packageName":"org.a"],["displayId":7,"packageName":"org.b"]];return f}
        ] {rejects{_ = try state(mutate)}}
        var detectorCalls=0
        let continuous=try DesktopCameraInput.delivery(generic:true){detectorCalls+=1;throw Failure.synthetic}
        precondition(continuous == .continuous && detectorCalls==0,"Generic camera invoked a QR detector or blocked a plain image")
        precondition(DesktopCameraInput.delivery(generic:false){false} == .waitForCode)
        precondition(DesktopCameraInput.delivery(generic:false){true} == .thenReturn)
        let right=DesktopCameraInput.framePlacement(size:CGSize(width:352,height:404),owner:CGRect(x:300,y:0,width:360,height:800),screen:CGRect(x:0,y:0,width:1440,height:900))
        precondition(!right.intersects(CGRect(x:300,y:0,width:360,height:800)) && CGRect(x:0,y:0,width:1440,height:900).contains(right))
        let left=DesktopCameraInput.framePlacement(size:CGSize(width:352,height:404),owner:CGRect(x:-400,y:0,width:360,height:800),screen:CGRect(x:-1440,y:0,width:1440,height:900))
        precondition(!left.intersects(CGRect(x:-400,y:0,width:360,height:800)) && left.maxX<=0,"Secondary-screen placement hid the real app")
        let binding=try PhoneSession.desktopCameraBindingBody(display:0x01020304,package:"org.example")
        precondition(binding.prefix(5)==Data([1,1,2,3,4]) && binding.dropFirst(5)==Data("org.example".utf8))
        require(try PhoneSession.desktopCameraBindingBody(display:7,package:nil)==Data([0,0,0,0,7]))
        rejects{_ = try PhoneSession.desktopCameraBindingBody(display:0,package:"org.example")}
        rejects{_ = try PhoneSession.desktopCameraBindingBody(display:7,package:"org.example;bad")}
        require(try DesktopCameraLaunch.accepted(Data([1]),clearing:false))
        require(try !DesktopCameraLaunch.accepted(Data([2]),clearing:false),"Non-camera app pretended to be bound")
        require(try !DesktopCameraLaunch.accepted(Data([0]),clearing:true))
        rejects{_ = try DesktopCameraLaunch.accepted(Data([0]),clearing:false)}
        rejects{_ = try DesktopCameraLaunch.accepted(Data([2]),clearing:true)}
        for failBind in [false,true] {
            var clears=0,launched=false
            do {
                _ = try DesktopCameraLaunch.perform(bind:{if failBind{throw Failure.synthetic};return true},launch:{launched=true;throw Failure.synthetic},clear:{clears+=1})
                fatalError("Failed launch accepted")
            } catch Failure.synthetic {}
            precondition(clears==1 && launched == !failBind,"Failed/uncertain binding did not compensate")
        }
        var cleared=false
        require(try !DesktopCameraLaunch.perform(bind:{false},launch:{},clear:{cleared=true}) && !cleared,"Ordinary app was blocked or camera-ready falsely asserted")
        do {_ = try DesktopCameraLaunch.perform(bind:{true},launch:{throw Failure.synthetic},clear:{throw Failure.synthetic});fatalError("Cleanup failure hidden")}
        catch is DesktopCameraLaunchFailure {}
        print("PASS generic third-app binding, plain-image delivery, legacy isolation, window placement, reply validation and launch compensation")
    }
}
