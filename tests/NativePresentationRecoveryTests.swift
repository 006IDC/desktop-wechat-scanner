import Foundation

@main enum NativePresentationRecoveryTests {
    static func main() {
        let stats=NativeMattePresentationStats()
        precondition(!stats.hasPresentedSource(after:10))
        stats.received(at:11)
        stats.submitted()
        stats.completed(ok:true,gpuMilliseconds:1)
        precondition(!stats.hasPresentedSource(after:10),"Decode/GPU completion reopened input before presentation")
        stats.presented(at:0,sourceReceivedAt:11)
        precondition(!stats.hasPresentedSource(after:10),"Occluded drawable without usable presentation time reopened input")
        stats.presented(at:12,sourceReceivedAt:9)
        precondition(!stats.hasPresentedSource(after:10),"A late old drawable reopened input")
        stats.presented(at:12,sourceReceivedAt:11)
        precondition(stats.hasPresentedSource(after:10))
        // Clear ACK occurs later than recovery entry. A pre-clear drawable
        // cannot reopen input merely because the ACK flag has now been set.
        let clearedAt=11.5
        precondition(!stats.hasPresentedSource(after:clearedAt))
        stats.presented(at:13,sourceReceivedAt:12)
        precondition(stats.hasPresentedSource(after:clearedAt))
        precondition(!stats.hasPresentedSource(after:12))
        stats.presented(at:13,sourceReceivedAt:.nan)
        stats.presented(at:13,sourceReceivedAt:14)
        precondition(!stats.hasPresentedSource(after:12),"Invalid/future receipt metadata reopened input")
        precondition(!stats.hasPresentedSource(after:.nan))
        print("PASS source receipt after recovery must have a valid drawable presentation before input resumes")
    }
}
