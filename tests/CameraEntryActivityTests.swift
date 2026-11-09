import Foundation
import Dispatch
@main enum CameraEntryActivityTests {
    final class Counts:@unchecked Sendable {
        let lock=NSLock(),ended=DispatchSemaphore(value:0)
        var starts=0,ends=0
        func begin()->NSObjectProtocol {lock.withLock{starts+=1};return NSObject()}
        func end(_ token:NSObjectProtocol){lock.withLock{ends+=1};ended.signal()}
        var balanced:Bool {lock.withLock{starts==ends}}
    }
    static func main() {
        for invalid in [Double.nan,Double.infinity,0,-1,100] {
            precondition(CameraEntryActivity(duration:invalid).duration==1.25)
        }
        let c=Counts(),activity=CameraEntryActivity(duration:0.02,begin:{c.begin()},end:{c.end($0)})
        precondition(activity.update(true));precondition(!activity.update(true))
        // Block this caller longer than the deadline: expiry must not need the
        // App loop/status request to finish before releasing its token.
        precondition(c.ended.wait(timeout:.now()+1) == .success)
        precondition(!activity.isActive && c.balanced)
        precondition(activity.update(true));activity.stop();activity.stop()
        precondition(c.balanced && !activity.isActive)
        for _ in 0..<40 {
            let c=Counts()
            do {
                let a=CameraEntryActivity(duration:0.001,begin:{c.begin()},end:{c.end($0)})
                _=a.update(true);Thread.sleep(forTimeInterval:0.001);a.stop()
                precondition(c.ended.wait(timeout:.now()+1) == .success)
                precondition(c.balanced && !a.isActive,"Stop/expiry ended a token twice")
            }
            precondition(c.balanced)
        }
        let deinitCounts=Counts()
        do {let a=CameraEntryActivity(duration:1,begin:{deinitCounts.begin()},end:{deinitCounts.end($0)});_=a.update(true)}
        precondition(deinitCounts.balanced)
        print("PASS expiry independent of caller/status wait; coalesced activity, expiry/stop races and deinit end exactly once")
    }
}
