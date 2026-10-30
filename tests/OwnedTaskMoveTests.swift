import Foundation

// Compile with AndroidApplication.swift and OwnedTaskMove.swift only. No ADB,
// phone, UI, permission change, task movement or real recovery file is involved.
struct ScanError:LocalizedError {
    let message:String
    init(_ message:String){self.message=message}
    var errorDescription:String?{message}
}

@main enum OwnedTaskMoveTests {
    static func task(_ id:Int,display:Int=0,root:Int=10,pkg:String="org.example.selected",user:Int=0,
                     mixed:Bool=false,home:Bool=false)->AndroidTaskSnapshot {
        AndroidTaskSnapshot(id:id,display:display,packageName:pkg,rootID:root,isHome:home,
                            userID:user,rootContainsOtherUsers:mixed)
    }
    static func require(_ value:Bool){precondition(value)}
    static func rejects(_ operation:() throws->Void){
        do {try operation();fatalError("Changed or unowned task group accepted")}catch{}
    }
    static func main() throws {
        let expected=[task(11),task(12)],arrived=[task(11,display:7),task(12,display:7)]
        require(try OwnedTaskMove.rootToMove(expected:expected,current:expected,destination:7)==10)
        require(try OwnedTaskMove.rootToMove(expected:expected,current:arrived,destination:7)==nil)
        require(try OwnedTaskMove.rootToMove(expected:expected,current:[],destination:7)==nil)
        require(try OwnedTaskMove.rootToMove(expected:expected,current:[task(12)],destination:7)==10)
        try OwnedTaskMove.requireArrival(expected:expected,current:arrived,destination:7)
        try OwnedTaskMove.requireArrival(expected:expected,current:[task(12,display:7)],destination:7)
        try OwnedTaskMove.requireArrival(expected:expected,current:[],destination:7)
        // Unrelated roots/users remain outside the move, while a same-user
        // foreign child joining this root is refused on the final fresh read.
        let unrelated=task(80,display:0,root:80,pkg:"org.example.other",user:10)
        require(try OwnedTaskMove.rootToMove(expected:expected,current:expected+[unrelated],destination:7)==10)
        for changed in [
            expected+[task(13,pkg:"org.example.other")],
            expected+[task(13)],
            [task(11,pkg:"org.example.other"),task(12)],
            [task(11,user:10),task(12)],
            [task(11,mixed:true),task(12)],
            [task(11,home:true),task(12)],
            [task(11,root:90),task(12)],
            [task(11,display:3),task(12,display:3)],
            [task(11,display:7),task(12)],
            expected+[task(11)]
        ] {rejects{_ = try OwnedTaskMove.rootToMove(expected:expected,current:changed,destination:7)}}
        // A disappeared original root cannot hide IDs reparented into another root.
        rejects{_ = try OwnedTaskMove.rootToMove(expected:expected,current:[task(11,root:90)],destination:7)}
        for changed in [expected,[task(11,display:7,root:90)],arrived+[task(13,display:7)],
                        [task(11,display:7,pkg:"org.example.other")],[task(11,display:7,mixed:true)]] {
            rejects{try OwnedTaskMove.requireArrival(expected:expected,current:changed,destination:7)}
        }
        for invalid in [[],[task(11),task(11)],[task(11,home:true)],[task(11,user:10)],
                        [task(11),task(12,root:90)],[task(11),task(12,display:3)]] {
            rejects{_ = try OwnedTaskMove.rootToMove(expected:invalid,current:[],destination:7)}
        }
        rejects{_ = try OwnedTaskMove.rootToMove(expected:expected,current:expected,destination:-1)}
        rejects{_ = try OwnedTaskMove.rootToMove(expected:expected,current:expected,destination:Int.max)}
        // Restore accepts the exact already-owned mixed-package group; launch
        // separately restricts its planned group to the user's selected app.
        let resultGroup=[task(11,display:7),task(12,display:7,pkg:"org.example.result")]
        require(try OwnedTaskMove.rootToMove(expected:resultGroup,current:resultGroup,destination:0)==10)
        try OwnedTaskMove.requireArrival(expected:resultGroup,current:[task(11),task(12,pkg:"org.example.result")],destination:0)
        let parsedResult="""
        Display #7 (activities from top to bottom):
          * Task{root #10 U=0 sz=2 type=standard}
            * Task{selected #11 U=0 sz=1 type=standard}
              * Hist #0: ActivityRecord{a u0 org.example.selected/.Main t11}
            * Task{result #12 U=0 sz=1 type=standard}
              * Hist #0: ActivityRecord{b u0 org.example.result/.Main t12}
        """
        let parsed=try AndroidTaskSnapshot.parseChecked(parsedResult,requiredDisplay:7)
        require(parsed.count==2)
        require(try OwnedTaskMove.rootToMove(expected:parsed,current:parsed,destination:0)==10)
        let moved=try AndroidTaskSnapshot.parseChecked(parsedResult.replacingOccurrences(of:"Display #7",with:"Display #0"),requiredDisplay:0)
        try OwnedTaskMove.requireArrival(expected:parsed,current:moved,destination:0)
        // Even an empty added child belonging to another user taints the root.
        // The parser need not emit that empty child as an application task.
        let emptyOtherUser="""
        Display #0 (activities from top to bottom):
          * Task{root #10 U=0 sz=2 type=standard}
            * Task{selected #11 U=0 sz=1 type=standard}
              * Hist #0: ActivityRecord{a u0 org.example.selected/.Main t11}
            * Task{empty #12 U=10 sz=0 type=standard}
        """
        let tainted=try AndroidTaskSnapshot.parseChecked(emptyOtherUser,requiredDisplay:0)
        require(tainted.contains{$0.id==11 && $0.rootContainsOtherUsers})
        rejects{_ = try OwnedTaskMove.rootToMove(expected:[task(11)],current:tainted,destination:7)}
        let unrelatedMixed=AndroidTaskSnapshot(id:80,display:0,packageNames:["org.example.first","org.example.second"],rootID:80)
        require(try OwnedTaskMove.applicationTasks(in:expected+[unrelatedMixed],packageName:"org.example.selected",target:7)==expected)
        for package in unrelatedMixed.packageNames {
            rejects{_ = try OwnedTaskMove.applicationTasks(in:expected+[unrelatedMixed],packageName:package,target:7)}
        }
        rejects{_ = try OwnedTaskMove.applicationTasks(in:expected+[task(13,pkg:"org.example.other")],packageName:"org.example.selected",target:7)}
        rejects{_ = try OwnedTaskMove.applicationTasks(in:[task(11,home:true)],packageName:"org.example.selected",target:7)}
        rejects{_ = try OwnedTaskMove.applicationTasks(in:tainted,packageName:"org.example.selected",target:7)}
        let ownedMixed=AndroidTaskSnapshot(id:81,display:7,packageNames:["org.example.selected","org.example.result"],rootID:81)
        let mixedMoved=AndroidTaskSnapshot(id:81,display:3,packageNames:ownedMixed.packageNames,rootID:81)
        let oldRecord=AndroidOwnedTask(id:81,originalDisplay:3,packageName:"org.example.selected",ownedDisplay:7)
        require(OwnedTaskMove.originalDisplay(for:ownedMixed,recorded:[oldRecord])==3)
        require(OwnedTaskMove.originalDisplay(for:ownedMixed,recorded:[])==0)
        require(try OwnedTaskMove.rootToMove(expected:[ownedMixed],current:[ownedMixed],destination:3)==81)
        try OwnedTaskMove.requireArrival(expected:[ownedMixed],current:[mixedMoved],destination:3)
        for packages:Set<String> in [["org.example.selected"],["org.example.selected","org.example.result","org.example.new"]] {
            let changed=AndroidTaskSnapshot(id:81,display:3,packageNames:packages,rootID:81)
            rejects{try OwnedTaskMove.requireArrival(expected:[ownedMixed],current:[changed],destination:3)}
        }
        let embeddedMixed="""
        Display #0 (activities from top to bottom):
          * Task{mixed #82 U=0 sz=1 type=standard}
            * TaskFragment{a1 mode=fullscreen}
              * Hist #1: ActivityRecord{a u0 org.example.other/.Main t82}
              * Hist #0: ActivityRecord{b u0 org.example.selected/.Result t82}
        """
        let fragmentTasks=try AndroidTaskSnapshot.parseChecked(embeddedMixed,requiredDisplay:0)
        require(fragmentTasks[0].packageNames==["org.example.other","org.example.selected"])
        rejects{_ = try OwnedTaskMove.applicationTasks(in:fragmentTasks,packageName:"org.example.selected",target:7)}
        let sameUserEmpty=emptyOtherUser.replacingOccurrences(of:"U=10",with:"U=0")
        let unknownSibling=try AndroidTaskSnapshot.parseChecked(sameUserEmpty,requiredDisplay:0)
        require(unknownSibling.count==1 && unknownSibling[0].rootContainsUnknownTasks)
        rejects{_ = try OwnedTaskMove.applicationTasks(in:unknownSibling,packageName:"org.example.selected",target:7)}
        rejects{_ = try OwnedTaskMove.rootToMove(expected:[task(11)],current:unknownSibling,destination:7)}
        // Root-level unions stay the same if task package sets are exchanged.
        // Per-task identity must still reject that change.
        let pair=[ownedMixed,AndroidTaskSnapshot(id:83,display:7,packageNames:["org.example.third"],rootID:81)]
        let swapped=[AndroidTaskSnapshot(id:81,display:3,packageNames:["org.example.third"],rootID:81),
                     AndroidTaskSnapshot(id:83,display:3,packageNames:ownedMixed.packageNames,rootID:81)]
        rejects{try OwnedTaskMove.requireArrival(expected:pair,current:swapped,destination:3)}
        let twoRoots=[task(11),task(84,root:84)]
        require(try OwnedTaskMove.applicationTasks(in:twoRoots+[unrelatedMixed],packageName:"org.example.selected",target:7)==twoRoots)
        rejects{_ = try OwnedTaskMove.applicationTasks(in:[task(11),task(12,display:3)],packageName:"org.example.selected",target:7)}
        let component="org.example.selected/.Main"
        require(OwnedTaskMove.applicationIsForeground(component:component,taskID:11,in:arrived,packageName:"org.example.selected",target:7))
        for id:Int? in [nil,0,90] {
            require(!OwnedTaskMove.applicationIsForeground(component:component,taskID:id,in:arrived,packageName:"org.example.selected",target:7))
        }
        require(!OwnedTaskMove.applicationIsForeground(component:component,taskID:11,in:expected,packageName:"org.example.selected",target:7))
        require(!OwnedTaskMove.applicationIsForeground(component:component,taskID:11,in:arrived+[task(11)],packageName:"org.example.selected",target:7))
        require(!OwnedTaskMove.applicationIsForeground(component:"org.example.other/.Main",taskID:11,in:arrived,packageName:"org.example.selected",target:7))
        let unknownTarget=try AndroidTaskSnapshot.parseChecked(sameUserEmpty.replacingOccurrences(of:"Display #0",with:"Display #7"),requiredDisplay:7)
        // The production caller runs this plan before its recovery-write loop.
        rejects{_ = try OwnedTaskMove.applicationTasksOnTarget(in:unknownTarget,packageName:"org.example.selected",target:7)}
        require(!OwnedTaskMove.applicationIsForeground(component:component,taskID:11,in:unknownTarget,packageName:"org.example.selected",target:7))
        for invalid in [[task(11,display:7,home:true)],[task(11,display:7,user:10)],[task(11,display:7,mixed:true)]] {
            rejects{_ = try OwnedTaskMove.applicationTasksOnTarget(in:invalid,packageName:"org.example.selected",target:7)}
            require(!OwnedTaskMove.applicationIsForeground(component:component,taskID:11,in:invalid,packageName:"org.example.selected",target:7))
        }
        require(try OwnedTaskMove.applicationTasksOnTarget(in:[ownedMixed],packageName:"org.example.selected",target:7)==[ownedMixed])
        require(OwnedTaskMove.applicationIsForeground(component:component,taskID:81,in:[ownedMixed],packageName:"org.example.selected",target:7))
        print("PASS single-read whole-root validation: foreign child, mixed user, HOME, reparent/reuse, split display, disappearance, arrival and idempotent restore; no device or UI")
    }
}
