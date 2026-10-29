import Foundation

/// Validate the complete root immediately before a move, against the group
/// recorded for recovery. One fresh read supplies both membership and user checks.
enum OwnedTaskMove {
    static func rootToMove(expected:[AndroidTaskSnapshot], current:[AndroidTaskSnapshot], destination:Int) throws -> Int? {
        let group=try validate(expected:expected,current:current,destination:destination,arrived:false)
        guard let first=group.first,first.display != destination else{return nil}
        return first.rootID
    }

    static func requireArrival(expected:[AndroidTaskSnapshot], current:[AndroidTaskSnapshot], destination:Int) throws {
        _=try validate(expected:expected,current:current,destination:destination,arrived:true)
    }

    private static func validate(expected:[AndroidTaskSnapshot], current:[AndroidTaskSnapshot], destination:Int,
                                 arrived:Bool) throws -> [AndroidTaskSnapshot] {
        let changed=ScanError("应用任务组在迁移前后发生变化，已保留恢复记录。")
        guard destination>=0,destination<=Int(Int32.max),let first=expected.first,
              first.rootID>0,first.display>=0,Set(expected.map(\.id)).count==expected.count,
              expected.allSatisfy({$0.id>0 && $0.rootID==first.rootID && $0.display==first.display &&
                  $0.userID==0 && !$0.rootContainsOtherUsers && !$0.isHome}) else{throw changed}
        let identities=Set(expected.map(\.id))
        // Include recorded IDs even if they moved to a different root. An empty
        // original root must not conceal that ownership change.
        let involved=current.filter{$0.rootID==first.rootID || identities.contains($0.id)}
        guard Set(involved.map(\.id)).count==involved.count,
              Set(involved.map(\.display)).count<=1 else{throw changed}
        for task in involved {
            guard let recorded=expected.first(where:{$0.id==task.id}),
                  task.rootID==recorded.rootID,task.packageName==recorded.packageName,
                  task.userID==0,!task.rootContainsOtherUsers,!task.isHome,
                  task.display==destination || (!arrived && task.display==recorded.display) else{throw changed}
        }
        // Finished children may disappear; unknown children, duplicated IDs and
        // reparented records cannot join. A wholly arrived group is a no-op.
        return involved
    }
}
