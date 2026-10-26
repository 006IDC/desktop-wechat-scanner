import Foundation

/// Coalesces diagnostic snapshots while one serial disk write is in progress.
/// Callers hand over a new value and never wait for JSON encoding or file I/O.
final class DiagnosticStateWriter: @unchecked Sendable {
    typealias Persist = @Sendable ([String: Any], URL) -> Void

    private let fileURL: URL
    private let persist: Persist
    private let queue = DispatchQueue(label: "com.idc006.desktop-wechat-scanner.diagnostics", qos: .utility)
    private let lock = NSLock()
    private var pending: [String: Any]?
    private var draining = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    init(fileURL: URL, persist: @escaping Persist = { snapshot, url in
        DiagnosticStateWriter.writeJSON(snapshot, to: url)
    }) {
        self.fileURL = fileURL
        self.persist = persist
    }

    func submit(_ snapshot: [String: Any]) {
        let schedule = lock.withLock { () -> Bool in
            pending = snapshot
            guard !draining else { return false }
            draining = true
            return true
        }
        if schedule { queue.async { [self] in drain() } }
    }

    /// Suspend without blocking the caller's thread until all submitted states are written.
    func flush() async {
        await withCheckedContinuation { continuation in
            let alreadyIdle = lock.withLock { () -> Bool in
                if !draining && pending == nil { return true }
                idleWaiters.append(continuation)
                return false
            }
            if alreadyIdle { continuation.resume() }
        }
    }

    private func drain() {
        while true {
            let (snapshot, waiters) = lock.withLock { () -> ([String: Any]?, [CheckedContinuation<Void, Never>]) in
                if let pending {
                    self.pending = nil
                    return (pending, [])
                }
                draining = false
                let waiters = idleWaiters
                idleWaiters.removeAll()
                return (nil, waiters)
            }
            guard let snapshot else {
                for waiter in waiters { waiter.resume() }
                return
            }
            persist(snapshot, fileURL)
        }
    }

    static func writeJSON(_ snapshot: [String: Any], to fileURL: URL) {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: snapshot, options: .sortedKeys)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Diagnostic output must never interrupt phone control or presentation.
        }
    }
}
