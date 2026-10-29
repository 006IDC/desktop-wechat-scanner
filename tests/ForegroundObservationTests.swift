import Foundation
@main enum ForegroundObservationTests {
    static func main() {
        let text="""
        Display #0 (activities from top to bottom):
          topResumedActivity=ActivityRecord{a u0 com.example.physical/.Home t20}
        Display #7 (activities from top to bottom):
          topResumedActivity=ActivityRecord{b u0 com.example.first/.Home t40}
          mResumedActivity: ActivityRecord{c u0 com.example.last/.Home t42}
        """
        let selected=PhoneSession.foregroundObservation(in:text,display:7)
        precondition(selected?.component=="com.example.last/.Home" && selected?.taskID==42)
        precondition(PhoneSession.foregroundObservation(in:text,display:0)?.taskID==20)
        precondition(PhoneSession.foregroundObservation(in:text,display:8)==nil)
        for tag in ["t-1","t0","t999999999999999999999","missing"] {
            let row="Display #7:\n topResumedActivity=ActivityRecord{x u0 com.example.app/.Home \(tag)}"
            let observed=PhoneSession.foregroundObservation(in:row,display:7)
            precondition(observed?.component=="com.example.app/.Home" && observed?.taskID==nil)
        }
        let uri="Display #7:\n topResumedActivity=https://example.test/ t1"
        precondition(PhoneSession.foregroundObservation(in:uri,display:7)==nil)
        print("PASS foreground selection preserved, associated task tag, display scope and malformed metadata rejection; no device")
    }
}
