import Foundation

/// One encoded camera ROI. selectedAt uses ProcessInfo.systemUptime, matching
/// DesktopCaptureTarget and PhoneSession's existing 500 ms freshness contract.
struct CameraEncodedFrame: Sendable {
    let data: Data
    let selectedAt: TimeInterval
    let captureMilliseconds: Double
}

/// Exactly one producer and one consumer; bufferingNewest(1) keeps only the
/// newest encoded frame while the consumer awaits the previous phone ACK.
final class CameraFramePipeline: @unchecked Sendable {
    struct Metrics: Sendable {
        var produced = 0
        var consumed = 0
        var queueOverwrites = 0
        var staleDropped = 0
    }

    enum PipelineError: Error { case alreadyRunning }

    private let lock = NSLock()
    private var running = false
    private var metrics = Metrics()

    var snapshot: Metrics {
        lock.lock(); defer { lock.unlock() }
        return metrics
    }

    private func begin() throws {
        lock.lock(); defer { lock.unlock() }
        guard !running else { throw PipelineError.alreadyRunning }
        running = true
        metrics = Metrics()
    }

    private func end() {
        lock.lock(); running = false; lock.unlock()
    }

    /// Publish and update counts under one lock: a resumed consumer cannot
    /// observe the new frame before its overwrite has been counted.
    private func publish(_ frame: CameraEncodedFrame,
                         to continuation: AsyncThrowingStream<CameraEncodedFrame, Error>.Continuation) -> Bool {
        lock.lock(); defer { lock.unlock() }
        switch continuation.yield(frame) {
        case .enqueued:
            metrics.produced += 1
            return true
        case .dropped:
            metrics.produced += 1
            metrics.queueOverwrites += 1
            return true
        case .terminated:
            return false
        @unknown default:
            return false
        }
    }

    private func recordStale() {
        lock.lock(); metrics.staleDropped += 1; lock.unlock()
    }

    private func recordConsumed() {
        lock.lock(); metrics.consumed += 1; lock.unlock()
    }

    /// Returns when produce returns nil. Cancellation and either callback's
    /// error cancel/join the producer before this method returns or throws.
    func run(
        produce: @escaping @Sendable () async throws -> CameraEncodedFrame?,
        consume: @escaping @Sendable (CameraEncodedFrame, Int) async throws -> Void
    ) async throws -> Metrics {
        try begin()
        defer { end() }

        let (stream, continuation) = AsyncThrowingStream<CameraEncodedFrame, Error>
            .makeStream(bufferingPolicy: .bufferingNewest(1))
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    do {
                        while !Task.isCancelled {
                            let started = ProcessInfo.processInfo.systemUptime
                            guard let frame = try await produce() else { break }
                            try Task.checkCancellation()
                            guard self.publish(frame, to: continuation) else { return }
                            let elapsed = ProcessInfo.processInfo.systemUptime - started
                            let remaining = 1.0 / 30.0 - elapsed
                            if remaining > 0 {
                                try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                            }
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                        throw error
                    }
                }

                do {
                    var accountedOverwrites = 0
                    for try await frame in stream {
                        try Task.checkCancellation()
                        let age = ProcessInfo.processInfo.systemUptime - frame.selectedAt
                        guard frame.selectedAt.isFinite, age.isFinite, age >= 0, age <= 0.5 else {
                            recordStale()
                            continue
                        }
                        let totalOverwrites = snapshot.queueOverwrites
                        let sinceLastConsume = totalOverwrites - accountedOverwrites
                        try await consume(frame, sinceLastConsume)
                        recordConsumed()
                        accountedOverwrites = totalOverwrites
                    }
                    try Task.checkCancellation()
                    try await group.waitForAll()
                    return snapshot
                } catch {
                    group.cancelAll()
                    continuation.finish()
                    throw error
                }
            }
        } onCancel: {
            continuation.finish()
        }
    }
}
