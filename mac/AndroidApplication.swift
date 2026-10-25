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
    let packageName: String
    let rootID: Int
    /// Convenience for historical fixtures; production must use parseChecked.
    static func parse(_ dump: String) -> [Self] { (try? scan(dump, strict: false, requiredDisplay: nil)) ?? [] }
    static func parseChecked(_ dump: String, requiredDisplay: Int? = nil) throws -> [Self] {
        try scan(dump, strict: true, requiredDisplay: requiredDisplay)
    }
    private struct TaskNode {
        let indent: Int
        let id: Int
        let size: Int?
        var childTasks = 0
        var histories = 0
    }
    private static func scan(_ dump: String, strict: Bool, requiredDisplay: Int?) throws -> [Self] {
        var display: Int?, displayIndent = -1, tasks: [Int: Self] = [:]
        var displays = Set<Int>(), containerDiagnostics = false
        var nodes: [TaskNode] = [], roots: [Int] = []
        let displayPattern = try! NSRegularExpression(pattern: "^Display #([0-9]+) \\(activities from top to bottom\\):$")
        let taskPattern = try! NSRegularExpression(pattern: "^\\*\\s+Task\\{[^}]* #([0-9]+)(?:[ }])")
        let sizePattern = try! NSRegularExpression(pattern: "(?:^|\\s)sz=([0-9]+)(?:[ }])")
        let historyStart = try! NSRegularExpression(pattern: "^(?:\\*\\s*)?Hist\\b")
        let historyPattern = try! NSRegularExpression(pattern: "^\\*\\s+Hist\\s+#[0-9]+:\\s+ActivityRecord\\{[^}]* u([0-9]+) ([A-Za-z_][A-Za-z0-9_.]*)/[^ }]+ t([0-9]+)(?:[ }])")
        let invalid = ScanError("无法完整核实手机任务树，已保留窗口和恢复记录。")
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
                if strict && !displays.insert(id).inserted { throw invalid }
                displays.insert(id); display = id; displayIndent = indent; roots.removeAll(); continue
            }
            if line.hasPrefix("Display #") {
                if strict { throw invalid }
                display = nil; roots.removeAll(); continue
            }
            guard let currentDisplay = display else { continue }
            if indent <= displayIndent { display = nil; roots.removeAll(); continue }
            while let last = roots.last, nodes[last].indent >= indent { roots.removeLast() }
            if let match = taskPattern.firstMatch(in: line, range: range), let id = Int(ns.substring(with: match.range(at: 1))), id > 0 {
                let size = sizePattern.firstMatch(in: line, range: range).flatMap { Int(ns.substring(with: $0.range(at: 1))) }
                if strict && line.contains("sz=") && size == nil { throw invalid }
                if let parent = roots.last { nodes[parent].childTasks += 1 }
                nodes.append(TaskNode(indent: indent, id: id, size: size)); roots.append(nodes.count - 1); continue
            }
            if strict && line.hasPrefix("*") && line.dropFirst().trimmingCharacters(in: .whitespaces).hasPrefix("Task") { throw invalid }
            guard historyStart.firstMatch(in: line, range: range) != nil else { continue }
            guard let leaf = roots.last, let root = roots.first,
                  let match = historyPattern.firstMatch(in: line, range: range),
                  let user = Int(ns.substring(with: match.range(at: 1))),
                  let id = Int(ns.substring(with: match.range(at: 3))), id == nodes[leaf].id else {
                if strict { throw invalid }; continue
            }
            nodes[leaf].histories += 1
            guard user == 0 else {
                if strict { throw invalid }
                continue
            }
            let entry = Self(id: id, display: currentDisplay, packageName: ns.substring(with: match.range(at: 2)), rootID: nodes[root].id)
            if strict, let old = tasks[id], old.display != entry.display || old.rootID != entry.rootID { throw invalid }
            tasks[id] = entry
        }
        if strict {
            guard !displays.isEmpty, requiredDisplay.map({ displays.contains($0) }) ?? true else { throw invalid }
            for node in nodes {
                let recognizedChildren = node.childTasks + node.histories
                if let size = node.size {
                    // sz counts direct children, not activities in descendants:
                    // a split root with two empty child tasks is legitimately sz=2.
                    guard recognizedChildren == size else { throw invalid }
                } else {
                    guard recognizedChildren > 0 else { throw invalid }
                }
            }
        }
        return tasks.values.sorted { $0.id < $1.id }
    }
}
