import Foundation
@main enum ForegroundLaunchWitnessTests {
    static func main() {
        let dump="""
        Display #0:
          topResumedActivity=ActivityRecord{a u0 com.example.physical/.Page t2}
        Display #7:
          topResumedActivity=ActivityRecord{a u0 com.example.app/.Page t3}
          mResumedActivity: ActivityRecord{b u0 com.example.home/.Page t4}
        """
        precondition(ForegroundActivityObservation.select(in:dump,display:7)?.taskID==4)
        let top=ForegroundActivityObservation.select(in:dump,display:7,onlyDisplayTop:true)
        precondition(top?.taskID==3)
        precondition(ForegroundActivityObservation.corroborates(top:top?.component,callback:"com.example.app/com.example.app.Page",package:"com.example.app",topUserID:top?.userID))
        for callback in [nil,"com.example.app/.Other","com.example.other/.Page","https://example.test/"] {
            precondition(!ForegroundActivityObservation.corroborates(top:top?.component,callback:callback,package:"com.example.app",topUserID:top?.userID))
        }
        precondition(ForegroundActivityObservation.select(in:dump,display:8,onlyDisplayTop:true)==nil)
        let duplicate=dump+"\n topResumedActivity=ActivityRecord{x u0 com.example.app/.Page t9}"
        precondition(ForegroundActivityObservation.select(in:duplicate,display:7,onlyDisplayTop:true)==nil)
        for user in [nil,-1,10] {
            precondition(!ForegroundActivityObservation.corroborates(top:top?.component,callback:top?.component,package:"com.example.app",topUserID:user))
        }
        let malformed=dump+"\n topResumedActivity=ActivityRecord{broken}"
        precondition(ForegroundActivityObservation.select(in:malformed,display:7,onlyDisplayTop:true)==nil)
        let missingUser="Display #7:\n topResumedActivity=ActivityRecord{x com.example.app/.Page t3}"
        precondition(ForegroundActivityObservation.select(in:missingUser,display:7,onlyDisplayTop:true)==nil)
        print("PASS explicit display top separate from nested rows; callback component corroboration and ambiguity rejection")
    }
}
