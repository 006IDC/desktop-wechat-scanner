import Foundation

@main enum NativeCapturePacerTests {
    static func main() {
        var pacer=NativeCapturePacer()
        precondition(pacer.admit(publishedAt:1,now:1.002))
        precondition(!pacer.admit(publishedAt:1,now:1.003),"One publication produced duplicate work")
        precondition(!pacer.admit(publishedAt:1.033,now:1.050),"Work began just before the next ROI retirement")
        precondition(pacer.admit(publishedAt:1.066,now:1.068),"Fresh publication after a missed slot was lost")
        precondition(pacer.admit(publishedAt:1.100,now:1.102),"Unchanged geometry with new desktop content was blocked")
        precondition(!pacer.admit(publishedAt:2,now:1.9))
        var invalidClock=NativeCapturePacer()
        precondition(!invalidClock.admit(publishedAt:-1,now:-0.999))
        precondition(!pacer.admit(publishedAt:.nan,now:2))
        precondition(!pacer.admit(publishedAt:2,now:.infinity))
        print("PASS native capture follows fresh publications, skips late slots and never duplicates a publication")
    }
}
