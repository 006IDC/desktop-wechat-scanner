import Foundation

/// Check early transitions sooner without increasing the eight task snapshots
/// or shortening the final observation window of the former 200ms cadence.
enum ApplicationLaunchConfirmation {
    static let maximumChecks = 8
    static let nativeMaximumChecks = 9
    static func delay(afterCheck index:Int)->TimeInterval? {
        guard (0..<maximumChecks-1).contains(index) else{return nil}
        return [0.1,0.1,0.2,0.2,0.3,0.3,0.2][index]
    }
    /// Faster queries must not accidentally exhaust all checks before a slow
    /// app can resume. Native-capable sessions get a final 2s opportunity;
    /// the usual one-time unavailable fallback still applies to that request.
    static func delay(afterCheck index:Int,nativeGrace:Bool,elapsed:TimeInterval)->TimeInterval? {
        if let ordinary=delay(afterCheck:index){return ordinary}
        guard nativeGrace,index==maximumChecks-1,elapsed.isFinite,elapsed>=0 else{return nil}
        return max(0,2-elapsed)
    }
    static func pause(_ duration:TimeInterval,
                      clock:()->TimeInterval={ProcessInfo.processInfo.systemUptime},
                      sleep:(TimeInterval)->Void={Thread.sleep(forTimeInterval:$0)},
                      checkCancellation:() throws ->Void={try Task.checkCancellation()}) throws {
        let deadline=clock()+duration
        while clock()<deadline {
            try checkCancellation()
            sleep(min(0.1,max(0,deadline-clock())))
        }
        try checkCancellation()
    }
}
