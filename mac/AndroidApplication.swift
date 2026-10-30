import Foundation

struct AndroidApplication: Codable, Identifiable, Equatable, Sendable {
    let packageName: String
    let component: String
    let name: String
    var id: String { component }
    var canonicalComponent: String {
        let parts = component.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return component }
        return packageName + "/" + (parts[1].hasPrefix(".") ? packageName + parts[1] : String(parts[1]))
    }
    var isValid: Bool {
        guard packageName.range(of: "^[A-Za-z_][A-Za-z0-9_]*(\\.[A-Za-z_][A-Za-z0-9_]*)+$", options: .regularExpression) != nil,
              component.utf8.count <= 512, name.count <= 160, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        let parts = component.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts[0] == packageName &&
            String(parts[1]).range(of: "^\\.?[A-Za-z_$][A-Za-z0-9_$]*(\\.[A-Za-z_$][A-Za-z0-9_$]*)*$", options: .regularExpression) != nil
    }
    static func decodeCatalog(_ data: Data) throws -> [Self] {
        guard data.count <= 512 * 1024 else { throw ScanError("手机应用列表过大。") }
        let apps = try JSONDecoder().decode([Self].self, from: data)
        guard apps.count <= 500, apps.allSatisfy(\.isValid), Set(apps.map(\.component)).count == apps.count else { throw ScanError("手机应用列表无效。") }
        return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

struct AndroidAppDisplay: Codable, Identifiable, Equatable, Sendable {
    let id: Int
    let width: Int
    let height: Int
    let dpi: Int
    var independentLock: Bool? = nil
    var isValid: Bool { id > 0 && (1...4096).contains(width) && (1...4096).contains(height) && (1...2000).contains(dpi) }
}

/// Ephemeral authenticated stream; never persist or log its token.
struct DirectMirrorDescriptor: Codable, Sendable {
    let display:Int
    let socket:String
    let token:String
    let width:Int
    let height:Int
    var isValid:Bool {
        display>0 && (1...4096).contains(width) && (1...4096).contains(height) &&
        socket.range(of:"^006idc_video_[0-9a-f]{32}$",options:.regularExpression) != nil &&
        token.range(of:"^[0-9a-f]{32}$",options:.regularExpression) != nil
    }
}

/// Only identifiers needed for moving a task back; no intent extras or content.
struct AndroidOwnedTask: Codable, Equatable {
    let id: Int
    let originalDisplay: Int
    let packageName: String
    let ownedDisplay: Int
}

struct AndroidTaskSnapshot: Equatable {
    let id: Int
    let display: Int
    let packageNames: Set<String>
    /// A cross-app activity stack has no single package identity.
    var packageName: String? {packageNames.count==1 ? packageNames.first:nil}
    let rootID: Int
    let userID: Int
    let rootContainsOtherUsers: Bool
    let rootContainsUnknownTasks: Bool
    let isHome: Bool
    init(id: Int, display: Int, packageName: String, rootID: Int, isHome: Bool = false,
         userID: Int = 0, rootContainsOtherUsers: Bool = false,rootContainsUnknownTasks:Bool=false) {
        self.init(id:id,display:display,packageNames:[packageName],rootID:rootID,isHome:isHome,
                  userID:userID,rootContainsOtherUsers:rootContainsOtherUsers,rootContainsUnknownTasks:rootContainsUnknownTasks)
    }
    init(id:Int,display:Int,packageNames:Set<String>,rootID:Int,isHome:Bool=false,
         userID:Int=0,rootContainsOtherUsers:Bool=false,rootContainsUnknownTasks:Bool=false) {
        self.id = id
        self.display = display
        self.packageNames = packageNames
        self.rootID = rootID
        self.userID = userID
        self.rootContainsOtherUsers = rootContainsOtherUsers
        self.rootContainsUnknownTasks = rootContainsUnknownTasks
        self.isHome = isHome
    }
    /// Convenience for historical fixtures; production must use parseChecked.
    static func parse(_ dump: String) -> [Self] { (try? scan(dump, strict: false, requiredDisplay: nil)) ?? [] }
    static func parseChecked(_ dump: String, requiredDisplay: Int? = nil) throws -> [Self] {
        try scan(dump, strict: true, requiredDisplay: requiredDisplay)
    }
    struct ValidationError:LocalizedError {
        enum Reason:String {case duplicateDisplay,malformedDisplay,malformedTask,malformedTaskFields,taskFragment,orphanFragment,nonPositiveTask,otherUserOnTarget,malformedHistory,userMismatch,conflictingTask,missingDisplay,childCountMismatch,unknownChildren}
        let reason:Reason
        var expectedChildren:Int?=nil,observedChildren:Int?=nil,onTarget:Bool?=nil
        var errorDescription:String? {"无法完整核实手机任务树，已保留窗口和恢复记录。"}
    }
    private struct TaskNode {
        let indent: Int
        let display:Int
        let id: Int
        let rootID:Int
        let size: Int?
        let isHome: Bool
        let userID: Int?
        var isFragment=false
        var childTasks = 0
        var histories = 0
    }
    private struct RootKey: Hashable {
        let display: Int
        let id: Int
    }
    private static func scan(_ dump: String, strict: Bool, requiredDisplay: Int?) throws -> [Self] {
        var display: Int?, displayIndent = -1, tasks: [Int: Self] = [:]
        var displays = Set<Int>(), containerDiagnostics = false
        var taskHeaders=Set<Int>()
        var nodes: [TaskNode] = [], roots: [Int] = []
        var rootUsers: [RootKey: Set<Int>] = [:]
        let displayPattern = try! NSRegularExpression(pattern: "^Display #([0-9]+) \\(activities from top to bottom\\):$")
        let taskPattern = try! NSRegularExpression(pattern: "^\\*\\s+Task\\{[^}]* #([0-9]+)(?:[ }])")
        let fragmentPattern = try! NSRegularExpression(pattern:"^\\*\\s+TaskFragment\\{[0-9a-fA-F]+ mode=[A-Za-z0-9_-]+(?:[ }])")
        let sizePattern = try! NSRegularExpression(pattern: "(?:^|\\s)sz=([0-9]+)(?:[ }])")
        let taskUserPattern = try! NSRegularExpression(pattern: "(?:^|\\s)U=([0-9]+)(?:[ }])")
        let historyStart = try! NSRegularExpression(pattern: "^(?:\\*\\s*)?Hist\\b")
        let historyPattern = try! NSRegularExpression(pattern: "^\\*\\s+Hist\\s+#[0-9]+:\\s+ActivityRecord\\{[^}]* u([0-9]+) ([A-Za-z_][A-Za-z0-9_.]*)/[^ }]+ t([0-9]+)(?:[ }])")
        for raw in dump.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let indent = raw.prefix(while: { $0 == " " || $0 == "\t" }).count
            let ns = line as NSString
            let range = NSRange(location: 0, length: ns.length)
            if line.hasPrefix("RootWindowContainer") || line.hasPrefix("WindowContainer") || line.hasPrefix("mRootWindowContainer") {
                containerDiagnostics = true; display = nil; roots.removeAll(); continue
            }
            guard !containerDiagnostics else { continue }
            if let match = displayPattern.firstMatch(in: line, range: range), let id = Int(ns.substring(with: match.range(at: 1))) {
                if strict && !displays.insert(id).inserted { throw ValidationError(reason:.duplicateDisplay) }
                displays.insert(id); display = id; displayIndent = indent; roots.removeAll(); continue
            }
            if line.hasPrefix("Display #") {
                if strict { throw ValidationError(reason:.malformedDisplay) }
                display = nil; roots.removeAll(); continue
            }
            guard let currentDisplay = display else { continue }
            if indent <= displayIndent { display = nil; roots.removeAll(); continue }
            while let last = roots.last, nodes[last].indent >= indent { roots.removeLast() }
            if let match = taskPattern.firstMatch(in: line, range: range), let id = Int(ns.substring(with: match.range(at: 1))), id > 0 {
                // Multiple Hist records may share an id; real Task headers
                // may not. Do not let the activity aggregation hide reuse.
                if strict,!taskHeaders.insert(id).inserted {throw ValidationError(reason:.conflictingTask)}
                let size = sizePattern.firstMatch(in: line, range: range).flatMap { Int(ns.substring(with: $0.range(at: 1))) }
                let userID = taskUserPattern.firstMatch(in: line, range: range).flatMap { Int(ns.substring(with: $0.range(at: 1))) }
                // Only the authoritative Task header after its numeric ID may
                // declare home. A task name or activity package is not evidence.
                let tail = ns.substring(from: NSMaxRange(match.range(at: 1)))
                    .split(separator: "}", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
                let isHome = tail.range(of: "(?:^|\\s)type=home(?:\\s|$)", options: .regularExpression) != nil
                if strict && ((line.contains("sz=") && size == nil) || (line.contains("U=") && userID == nil)) { throw ValidationError(reason:.malformedTaskFields) }
                if strict && requiredDisplay.map({ $0 > 0 && currentDisplay == $0 }) == true && userID.map({ $0 != 0 }) == true { throw ValidationError(reason:.otherUserOnTarget) }
                let rootKey = RootKey(display: currentDisplay, id: roots.first.map { nodes[$0].id } ?? id)
                if let userID { rootUsers[rootKey, default: []].insert(userID) }
                if let parent = roots.last { nodes[parent].childTasks += 1 }
                nodes.append(TaskNode(indent: indent, display:currentDisplay, id: id,rootID:rootKey.id, size: size, isHome: isHome, userID: userID)); roots.append(nodes.count - 1); continue
            }
            if fragmentPattern.firstMatch(in:line,range:range) != nil {
                // Android 16 TaskFragment.dump recursively nests activities but
                // their Hist task ID still refers to the nearest real Task.
                // A fragment is one direct child, never a movable task itself.
                guard let parent=roots.last,let owner=roots.last(where:{!nodes[$0].isFragment}) else {
                    if strict {throw ValidationError(reason:.orphanFragment)};continue
                }
                nodes[parent].childTasks+=1
                let task=nodes[owner]
                nodes.append(TaskNode(indent:indent,display:currentDisplay,id:task.id,rootID:task.rootID,size:nil,isHome:task.isHome,userID:task.userID,isFragment:true))
                roots.append(nodes.count-1);continue
            }
            if strict && line.hasPrefix("*") && line.dropFirst().trimmingCharacters(in: .whitespaces).hasPrefix("Task") {
                let header=line.dropFirst().trimmingCharacters(in:.whitespaces)
                let reason:ValidationError.Reason=header.hasPrefix("TaskFragment{") ? .taskFragment:((header.contains("#0 ") || header.contains("#-1 ")) ? .nonPositiveTask:.malformedTask)
                throw ValidationError(reason:reason)
            }
            guard historyStart.firstMatch(in: line, range: range) != nil else { continue }
            guard let leaf = roots.last, let root = roots.first,
                  let match = historyPattern.firstMatch(in: line, range: range),
                  let user = Int(ns.substring(with: match.range(at: 1))),
                  let id = Int(ns.substring(with: match.range(at: 3))), id == nodes[leaf].id else {
                if strict { throw ValidationError(reason:.malformedHistory) }; continue
            }
            nodes[leaf].histories += 1
            if strict && (nodes[leaf].userID.map({ $0 != user }) == true ||
                          (requiredDisplay.map({ $0 > 0 && currentDisplay == $0 }) == true && user != 0)) { throw ValidationError(reason:.userMismatch) }
            let rootKey = RootKey(display: currentDisplay, id: nodes[root].id)
            rootUsers[rootKey, default: []].insert(user)
            let entry = Self(id: id, display: currentDisplay, packageName: ns.substring(with: match.range(at: 2)),
                             rootID: nodes[root].id, isHome: nodes[root].isHome, userID: user)
            if strict, let old = tasks[id], old.display != entry.display || old.rootID != entry.rootID || old.isHome != entry.isHome || old.userID != entry.userID { throw ValidationError(reason:.conflictingTask) }
            // Hist records are activities, not task owners. Android can keep
            // activities from several packages in one otherwise coherent task.
            tasks[id] = Self(id:id,display:entry.display,packageNames:(tasks[id]?.packageNames ?? []).union(entry.packageNames),
                             rootID:entry.rootID,isHome:entry.isHome,userID:entry.userID)
        }
        if strict {
            guard !displays.isEmpty, requiredDisplay.map({ displays.contains($0) }) ?? true else { throw ValidationError(reason:.missingDisplay) }
            for node in nodes {
                let recognizedChildren = node.childTasks + node.histories
                if let size = node.size {
                    // sz counts direct children, not activities in descendants:
                    // a split root with two empty child tasks is legitimately sz=2.
                    guard recognizedChildren == size else { throw ValidationError(reason:.childCountMismatch,expectedChildren:size,observedChildren:recognizedChildren,onTarget:requiredDisplay==node.display) }
                } else {
                    guard recognizedChildren > 0 else { throw ValidationError(reason:.unknownChildren) }
                }
            }
        }
        // Empty real leaf Tasks have no package identity. They must not be
        // hidden when another activity-bearing task in that root is moved.
        let unknownRoots=Set(nodes.filter{!$0.isFragment && $0.childTasks==0 && $0.histories==0}
            .map{RootKey(display:$0.display,id:$0.rootID)})
        return tasks.values.map { entry in
            Self(id: entry.id, display: entry.display, packageNames: entry.packageNames,
                 rootID: entry.rootID, isHome: entry.isHome, userID: entry.userID,
                 rootContainsOtherUsers: rootUsers[RootKey(display: entry.display, id: entry.rootID)]?.contains(where: { $0 != 0 }) == true,
                 rootContainsUnknownTasks:unknownRoots.contains(RootKey(display:entry.display,id:entry.rootID)))
        }.sorted { $0.id < $1.id }
    }
}
