import Foundation

/// Validate the complete root immediately before a move, against the group
/// recorded for recovery. One fresh read supplies both membership and user checks.
enum OwnedTaskMove {
    /// A requested package anywhere in a task must be considered. Never hide a
    /// mixed task by choosing its first/last activity as its package identity.
    static func applicationTasks(in snapshot:[AndroidTaskSnapshot],packageName:String,target:Int) throws ->[AndroidTaskSnapshot] {
        let moving=snapshot.filter{$0.userID==0 && $0.packageNames.contains(packageName) && $0.display != target}
        for root in Set(moving.map(\.rootID)) {
            let members=snapshot.filter{$0.rootID==root}
            guard Set(members.map(\.display)).count==1,members.allSatisfy({
                $0.userID==0 && !$0.rootContainsOtherUsers && !$0.rootContainsUnknownTasks && !$0.isHome &&
                $0.packageNames==[packageName] && $0.display != target
            }) else {throw ScanError("此应用与其他应用共享任务容器，无法安全地单独移入窗口。")}
        }
        return moving
    }
    /// Recovery policy: an already-owned root may contain same-user result
    /// activities added by its app. The recorded package remains its destination
    /// anchor; fresh whole-root/per-task-set checks still fence the actual move.
    static func originalDisplay(for task:AndroidTaskSnapshot,recorded:[AndroidOwnedTask])->Int {
        recorded.first{$0.id==task.id && task.packageNames.contains($0.packageName)}?.originalDisplay ?? 0
    }
    /// Validate new target tasks before adding any of them to recovery. A
    /// foreground package alone cannot certify an incomplete task root.
    static func applicationTasksOnTarget(in snapshot:[AndroidTaskSnapshot],packageName:String,target:Int) throws ->[AndroidTaskSnapshot] {
        let tasks=snapshot.filter{$0.display==target && $0.packageNames.contains(packageName)}
        guard tasks.allSatisfy({$0.userID==0 && !$0.isHome && !$0.rootContainsOtherUsers && !$0.rootContainsUnknownTasks}) else {
            throw ScanError("应用任务的归属尚未完整确认，已保留恢复记录。")
        }
        return tasks
    }
    static func applicationIsForeground(component:String?,taskID:Int?,in snapshot:[AndroidTaskSnapshot],packageName:String,target:Int)->Bool {
        guard component?.hasPrefix(packageName+"/")==true,let taskID,taskID>0,snapshot.filter({$0.id==taskID}).count==1,
              let tasks=try? applicationTasksOnTarget(in:snapshot,packageName:packageName,target:target),
              tasks.filter({$0.id==taskID}).count==1 else{return false}
        return true
    }
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
                  $0.userID==0 && !$0.rootContainsOtherUsers && !$0.rootContainsUnknownTasks && !$0.isHome && !$0.packageNames.isEmpty}) else{throw changed}
        let identities=Set(expected.map(\.id))
        // Include recorded IDs even if they moved to a different root. An empty
        // original root must not conceal that ownership change.
        let involved=current.filter{$0.rootID==first.rootID || identities.contains($0.id)}
        guard Set(involved.map(\.id)).count==involved.count,
              Set(involved.map(\.display)).count<=1 else{throw changed}
        for task in involved {
            guard let recorded=expected.first(where:{$0.id==task.id}),
                  task.rootID==recorded.rootID,task.packageNames==recorded.packageNames,
                  task.userID==0,!task.rootContainsOtherUsers,!task.rootContainsUnknownTasks,!task.isHome,
                  task.display==destination || (!arrived && task.display==recorded.display) else{throw changed}
        }
        // Finished children may disappear; unknown children, duplicated IDs and
        // reparented records cannot join. A wholly arrived group is a no-op.
        return involved
    }
}
