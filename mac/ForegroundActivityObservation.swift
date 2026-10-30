import Foundation

/// Diagnostic/launch observations remain scoped to one display. The legacy
/// nested-row choice is retained; an explicit display-top witness is separate.
enum ForegroundActivityObservation {
    static func select(in dump:String,display:Int,onlyDisplayTop:Bool=false)->(component:String,taskID:Int?,userID:Int?)? {
        var current:Int?,resumed:(component:String,taskID:Int?,userID:Int?)?,topRows=0
        for raw in dump.split(separator:"\n") {
            let line=raw.trimmingCharacters(in:.whitespaces)
            if line.hasPrefix("Display #") {
                current=Int(line.dropFirst(9).prefix(while:{$0.isNumber}))
            } else if current==display && (line.contains("topResumedActivity=") || (!onlyDisplayTop && line.contains("mResumedActivity:"))) {
                if onlyDisplayTop {topRows+=1}
                let fields=line.split(whereSeparator:{$0==" " || $0=="\t" || $0=="}"})
                if let component=fields.first(where:{$0.contains("/") && !$0.contains("://")}) {
                    let taskID=fields.first(where:{$0.hasPrefix("t") && Int($0.dropFirst()) != nil})
                        .flatMap{Int($0.dropFirst())}.flatMap{(1...Int(Int32.max)).contains($0) ? $0:nil}
                    let userID=fields.first(where:{$0.hasPrefix("u") && Int($0.dropFirst()) != nil})
                        .flatMap{Int($0.dropFirst())}.flatMap{(0...Int(Int32.max)).contains($0) ? $0:nil}
                    resumed=(String(component),taskID,userID)
                }
            }
        }
        if onlyDisplayTop && (topRows != 1 || resumed?.userID==nil || resumed?.taskID==nil) {return nil}
        return resumed
    }
    /// This only corroborates component identity. The caller must still validate
    /// the explicit task ID, full task ownership, target display and user.
    static func corroborates(top:String?,callback:String?,package:String,topUserID:Int?)->Bool {
        guard topUserID==0,let top,let callback else{return false}
        let a=AndroidApplication(packageName:package,component:top,name:"")
        let b=AndroidApplication(packageName:package,component:callback,name:"")
        return a.isValid && b.isValid && a.canonicalComponent==b.canonicalComponent
    }
}
