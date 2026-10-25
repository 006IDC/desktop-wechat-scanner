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
    var isValid: Bool { id > 0 && (1...4096).contains(width) && (1...4096).contains(height) && (1...2000).contains(dpi) }
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
    static func parse(_ dump: String) -> [Self] {
        var display: Int?, tasks: [Int: Self] = [:]
        var roots: [(indent: Int, id: Int)] = []
        let taskPattern = try! NSRegularExpression(pattern: "^\\* Task\\{[^}]* #([0-9]+)")
        let activity = try! NSRegularExpression(pattern: "ActivityRecord\\{[^}]* u0 ([A-Za-z_][A-Za-z0-9_.]*)/[^ }]+ t([0-9]+)")
        for raw in dump.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Display #") {
                display = Int(line.dropFirst(9).prefix(while: \.isNumber)); roots.removeAll()
            }
            let indent = raw.prefix(while: { $0 == " " }).count
            let taskLine = line as NSString
            if let match = taskPattern.firstMatch(in: line, range: NSRange(location: 0, length: taskLine.length)),
               let id = Int(taskLine.substring(with: match.range(at: 1))) {
                while let last = roots.last, last.indent >= indent { roots.removeLast() }
                roots.append((indent, id))
            }
            guard let display else { continue }
            let ns = line as NSString
            for match in activity.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                guard let id = Int(ns.substring(with: match.range(at: 2))), id > 0 else { continue }
                if line.contains("ResumedActivity"), tasks[id] != nil { continue }
                tasks[id] = Self(id: id, display: display, packageName: ns.substring(with: match.range(at: 1)), rootID: roots.first?.id ?? id)
            }
        }
        return tasks.values.sorted { $0.id < $1.id }
    }
}
