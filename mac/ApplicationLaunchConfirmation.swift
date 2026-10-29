import Foundation

/// Check early transitions sooner without increasing the eight task snapshots
/// or shortening the final observation window of the former 200ms cadence.
enum ApplicationLaunchConfirmation {
    static let maximumChecks = 8
    static func delay(afterCheck index:Int)->TimeInterval? {
        guard (0..<maximumChecks-1).contains(index) else{return nil}
        return [0.1,0.1,0.2,0.2,0.3,0.3,0.2][index]
    }
}
