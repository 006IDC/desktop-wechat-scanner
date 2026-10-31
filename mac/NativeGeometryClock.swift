import Foundation

/// A fixed 30 Hz phase with 2 ms timer leeway. Re-basing every deadline on
/// `now` turns tiny 60 Hz timer jitter into repeated 50 ms publication gaps.
/// Missed slots are skipped, never queued. This schedules geometry, not access.
struct NativeGeometryClock {
    private var origin:TimeInterval?
    private var lastSlot:Int64 = -1
    mutating func due(at now:TimeInterval)->Bool {
        guard now.isFinite,now>=0 else{return false}
        if origin==nil {origin=now;lastSlot=0;return true}
        guard let origin,now>=origin else{return false}
        let value=(now-origin+0.002)*30
        guard value.isFinite,value<Double(Int64.max) else{return false}
        let slot=Int64(value.rounded(.down))
        guard slot>lastSlot else{return false}
        lastSlot=slot;return true
    }
}
