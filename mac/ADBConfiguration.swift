import Foundation

/// External Platform-Tools only. Never executes a path until its name and file
/// permissions pass inspection; the version response must also identify ADB.
enum ADBConfiguration {
    static let defaultsKey = "externalADBPath"
    static let downloadURL = URL(string: "https://developer.android.com/tools/releases/platform-tools")!

    static func candidates(savedPath: String?, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        var paths = [String]()
        if let savedPath, !savedPath.isEmpty { paths.append(savedPath) }
        paths += ["/opt/homebrew/bin/adb", "/usr/local/bin/adb", home.appendingPathComponent("Library/Android/sdk/platform-tools/adb").path]
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }.map { URL(fileURLWithPath: $0) }
    }

    static func isADBVersion(_ output: String) -> Bool {
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let first = lines.first,
              first.range(of: #"^Android Debug Bridge version [0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil else { return false }
        return lines.dropFirst().contains { $0.range(of: #"^Version [0-9]+\.[0-9]+\.[0-9]+(?:[-.][A-Za-z0-9._-]+)?$"#, options: .regularExpression) != nil }
    }

    static func validate(_ url: URL, version: (URL) throws -> String = {
        try ShellCommand.run($0, ["version"], timeout: 5)
    }) throws -> URL {
        let candidate = url.standardizedFileURL
        var directory: ObjCBool = false
        guard candidate.isFileURL, candidate.lastPathComponent == "adb",
              FileManager.default.fileExists(atPath: candidate.path, isDirectory: &directory), !directory.boolValue,
              FileManager.default.isExecutableFile(atPath: candidate.path) else {
            throw ScanError("请选择解压后的 Platform-Tools 文件夹内可执行的 adb 文件。")
        }
        guard isADBVersion(try version(candidate)) else {
            throw ScanError("所选文件没有返回有效的 Android Debug Bridge 版本，请选择 Google Platform-Tools 中的 adb。")
        }
        return candidate
    }

    static func validateAsync(_ url: URL) async throws -> URL {
        let task = Task.detached(priority: .userInitiated) { try validate(url) }
        return try await withTaskCancellationHandler(operation: {
            let value = try await task.value
            try Task.checkCancellation()
            return value
        }, onCancel: { task.cancel() })
    }

    static func discover(savedPath: String?) async throws -> URL? {
        for url in candidates(savedPath: savedPath) {
            try Task.checkCancellation()
            do { return try await validateAsync(url) }
            catch is CancellationError { throw CancellationError() }
            catch { continue }
        }
        return nil
    }
}
