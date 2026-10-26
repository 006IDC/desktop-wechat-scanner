import Foundation

@main enum DiagnosticStateWriterTests {
    private final class WriteCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func next() -> Int { lock.withLock { count += 1; return count } }
        var value: Int { lock.withLock { count } }
    }

    private static func require(_ condition: Bool, _ message: String) {
        if !condition { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    private static func received(_ semaphore: DispatchSemaphore, within seconds: Double) -> Bool {
        semaphore.wait(timeout: .now() + seconds) == .success
    }

    static func main() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("006idc-diagnostic-writer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("diagnostic-state.json")
        let firstStarted = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let writes = WriteCounter()
        let writer = DiagnosticStateWriter(fileURL: file) { snapshot, destination in
            if writes.next() == 1 {
                firstStarted.signal()
                _ = releaseFirst.wait(timeout: .now() + 5)
            }
            DiagnosticStateWriter.writeJSON(snapshot, to: destination)
        }

        writer.submit(["status": "connecting", "connected": true])
        require(received(firstStarted, within: 2), "Background writer did not start")

        let submitted = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            writer.submit(["status": "intermediate", "connected": true])
            submitted.signal()
        }
        require(received(submitted, within: 1),
                "Submitting a snapshot waited for the blocked disk writer")
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            writer.submit(["status": "update-\(index)", "connected": true])
        }
        writer.submit(["status": "disconnected", "connected": false])
        releaseFirst.signal()
        await writer.flush()

        require(writes.value == 2, "Pending states were not coalesced to the latest value")
        let data = try Data(contentsOf: file)
        guard let saved = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            fatalError("Missing persisted diagnostic dictionary")
        }
        require(saved["status"] as? String == "disconnected" && saved["connected"] as? Bool == false,
                "An older connected state overwrote the final disconnect state")
        print("PASS asynchronous coalescing, concurrent submit and final disconnect persistence")
    }
}
