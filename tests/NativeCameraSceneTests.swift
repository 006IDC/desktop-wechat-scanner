import Foundation

@main enum NativeCameraSceneTests {
    static func state(_ component:String,stream:Int=4,owner:Int=6,binding:Int=8,capture:Int=10,bound:Bool=true) throws ->PhoneCameraState {
        let fields:[String:Any]=["version":1,"generation":stream,"ownerGeneration":owner,"captureGeneration":capture,
            "activeStreams":1,"ownerKnown":true,"cameraOwner":"org.example.camera","desktopHome":true,
            "desktopCameraEnabled":true,"desktopCameraSupported":true,"desktopCameraGeneration":binding,
            "desktopCameraBindings":bound ? [["displayId":7,"packageName":"org.example.camera"]]:[],
            "activities":[["displayId":7,"component":"org.example.camera/."+component]]]
        return try PhoneCameraState.decode(JSONSerialization.data(withJSONObject:fields))
    }
    static func main() throws {
        let initial=try state("Opening"),scanner=try state("Scanner",capture:11),result=try state("Result",capture:12)
        var attempt=NativeCameraScene(state:initial)!
        precondition(attempt.retryStartupTransition(in:scanner))
        precondition(!attempt.retryStartupTransition(in:result),"Startup transitions became unbounded")
        precondition(attempt.markVerified(in:scanner))
        precondition(!attempt.permits(result.captureActivity()!,in:result),"A live background camera restarted calibration over its result page")
        precondition(!attempt.retryStartupTransition(in:result),"A verified scene followed the result page")
        precondition(attempt.permits(scanner.captureActivity()!,in:scanner),"Returning to the verified scanner stayed blocked")
        // First owner check admitted Scanner; the second read saw Result before
        // an overlay was created. Use the actual catch policy, then return.
        precondition(attempt.permits(scanner.captureActivity()!,in:scanner))
        precondition(!attempt.permits(result.captureActivity()!,in:result))
        precondition(attempt.recoverPreparation(in:result) == .showApplication,"A no-overlay result failure latched off automatic resume")
        precondition(attempt.permits(scanner.captureActivity()!,in:scanner))
        precondition(attempt.recoverPreparation(in:scanner) == .stop,"An unrelated failure retried forever on the same scene")
        let unrelatedBinding=try state("Result",binding:9,capture:13)
        precondition(!attempt.permits(unrelatedBinding.captureActivity()!,in:unrelatedBinding),"Another window's binding erased result suppression")
        let unrelatedForeground=try PhoneCameraState.decode(JSONSerialization.data(withJSONObject:["version":1,"generation":4,"ownerGeneration":6,
            "activeStreams":1,"ownerKnown":true,"cameraOwner":"org.example.camera","desktopHome":true,
            "desktopCameraEnabled":true,"desktopCameraSupported":true,"desktopCameraGeneration":9,
            "desktopCameraBindings":[["displayId":7,"packageName":"org.example.camera"]],
            "activities":[["displayId":7,"component":"org.example.other/.Page"]]]))
        precondition(attempt.sameSource(in:unrelatedForeground),"A temporary other foreground forgot the still-open camera")
        for next in [try state("Result",stream:5),try state("Result",owner:7),try state("Result",bound:false)] {
            precondition(!attempt.sameSource(in:next),"A retired source kept its suppression")
        }
        let manual=NativeCameraScene(state:result)!
        precondition(manual.permits(result.captureActivity()!,in:result),"An explicit new probe could not select another scene")
        print("PASS native scene result suppression, bounded startup transition, resume and source retirement")
    }
}
