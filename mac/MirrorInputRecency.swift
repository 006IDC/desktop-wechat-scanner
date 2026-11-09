import Foundation

/// Owned by MirrorSession's lock. Only a successful write in the current
/// incarnation may request a short responsiveness window; no input is granted.
struct MirrorInputRecency {
    private var epoch=0,enabled=false
    private(set) var latest:Double?
    mutating func reset(epoch:Int,enabled:Bool) {
        self.epoch=epoch;self.enabled=enabled;latest=nil
    }
    mutating func wrote(epoch:Int,at now:Double) {
        guard enabled,self.epoch==epoch,now.isFinite,now>=0 else{return}
        latest=max(latest ?? now,now)
    }
}

/// Short, input-driven entry probing, never the ongoing camera frame cadence.
enum CameraEntryPolling {
    struct Decision {
        let holdActivity:Bool,statusInterval:Double,sleepNanoseconds:UInt64
    }
    static func decision(cameraActive:Bool,busy:Bool,lastInput:Double?,now:Double)->Decision {
        let recent = !cameraActive && now.isFinite && (lastInput.map{
            $0.isFinite && $0>=0 && now >= $0 && now-$0<1.25
        } ?? false)
        return Decision(holdActivity:recent,statusInterval:cameraActive ? 0.25:(recent ? 0.04:0.1),
                        sleepNanoseconds:recent && !busy ? 10_000_000:60_000_000)
    }
}
