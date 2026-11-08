import Foundation

/// A fixed 30 Hz phase with 2 ms timer leeway. Re-basing every deadline on
/// `now` turns tiny 60 Hz timer jitter into repeated 50 ms publication gaps.
/// Missed slots are skipped, never queued. A processing budget may skip further
/// slots under load; it does not authorize frames or change rendering cadence.
struct NativeGeometryClock {
    private var origin:TimeInterval?
    private var lastSlot:Int64 = -1
    private var lastPublication:TimeInterval?
    mutating func due(at now:TimeInterval,minimumInterval:Double=0)->Bool {
        guard now.isFinite,now>=0,minimumInterval.isFinite,minimumInterval>=0,minimumInterval<=0.1 else{return false}
        if origin==nil {origin=now;lastSlot=0;lastPublication=now;return true}
        guard let origin,now>=origin else{return false}
        let value=(now-origin+0.002)*30
        guard value.isFinite,value<Double(Int64.max) else{return false}
        let slot=Int64(value.rounded(.down))
        guard slot>lastSlot else{return false}
        if minimumInterval>0,let lastPublication,now-lastPublication<minimumInterval-0.002 {return false}
        lastSlot=slot;lastPublication=now;return true
    }
}
