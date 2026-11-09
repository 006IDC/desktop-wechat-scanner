import Foundation
@main enum MirrorInputRecencyTests {
    static func main() {
        var r=MirrorInputRecency();r.reset(epoch:1,enabled:true)
        precondition(r.latest==nil)
        r.wrote(epoch:0,at:1);r.wrote(epoch:1,at:.nan);precondition(r.latest==nil)
        r.wrote(epoch:1,at:10);r.wrote(epoch:1,at:9);precondition(r.latest==10)
        let recent=CameraEntryPolling.decision(cameraActive:false,busy:false,lastInput:r.latest,now:10.1)
        precondition(recent.holdActivity && recent.statusInterval==0.04 && recent.sleepNanoseconds==10_000_000)
        let busy=CameraEntryPolling.decision(cameraActive:false,busy:true,lastInput:r.latest,now:10.1)
        precondition(busy.holdActivity && busy.sleepNanoseconds==60_000_000)
        let active=CameraEntryPolling.decision(cameraActive:true,busy:false,lastInput:r.latest,now:10.1)
        precondition(!active.holdActivity && active.statusInterval==0.25 && active.sleepNanoseconds==60_000_000)
        for clock in [9.0,11.25,100.0,Double.nan] {
            let p=CameraEntryPolling.decision(cameraActive:false,busy:false,lastInput:r.latest,now:clock)
            precondition(!p.holdActivity && p.statusInterval==0.1 && p.sleepNanoseconds==60_000_000)
        }
        r.reset(epoch:2,enabled:false);r.wrote(epoch:1,at:11);r.wrote(epoch:2,at:11);precondition(r.latest==nil)
        r.reset(epoch:3,enabled:true);r.wrote(epoch:1,at:12);precondition(r.latest==nil)
        r.wrote(epoch:3,at:12);precondition(r.latest==12)
        print("PASS accepted current-epoch writes only; no stale/stopped-input revival; bounded idle/active/busy entry probing and future-clock rejection")
    }
}
