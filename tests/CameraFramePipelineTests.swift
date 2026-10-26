import Foundation

private final class PipelineTestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var next = 0
    private var values = [Int]()
    func take() -> Int { lock.lock(); defer { lock.unlock() }; let value = next; next += 1; return value }
    func append(_ value: Int) { lock.lock(); values.append(value); lock.unlock() }
    var received: [Int] { lock.lock(); defer { lock.unlock() }; return values }
    var taken: Int { lock.lock(); defer { lock.unlock() }; return next }
}

@main enum CameraFramePipelineTests {
    private enum TestError: Error { case producer, consumer }
    private static func frame(_ value: Int, age: Double = 0) -> CameraEncodedFrame {
        CameraEncodedFrame(data: Data([UInt8(value % 256)]),
                           selectedAt: ProcessInfo.processInfo.systemUptime - age,
                           captureMilliseconds: 1)
    }

    private static func newestWins() async throws {
        let pipeline = CameraFramePipeline(), box = PipelineTestBox()
        let metrics = try await pipeline.run(produce: {
            let index = box.take()
            return index < 24 ? frame(index) : nil
        }, consume: { image, _ in
            box.append(Int(image.data[0]))
            try await Task.sleep(nanoseconds: 115_000_000)
        })
        precondition(metrics.produced == 24)
        precondition(metrics.queueOverwrites > 0)
        precondition(metrics.consumed < metrics.produced)
        precondition(box.received.last == 23)
    }

    private static func cancellationJoinsProducer() async throws {
        let pipeline = CameraFramePipeline(), box = PipelineTestBox()
        let task = Task {
            try await pipeline.run(produce: {
                frame(box.take())
            }, consume: { _, _ in
                try await Task.sleep(nanoseconds: 100_000_000)
            })
        }
        try await Task.sleep(nanoseconds: 130_000_000)
        task.cancel()
        do { _ = try await task.value; preconditionFailure("Cancellation succeeded") }
        catch is CancellationError { }
        let produced = pipeline.snapshot.produced
        try await Task.sleep(nanoseconds: 80_000_000)
        precondition(pipeline.snapshot.produced == produced)
    }

    private static func errorsJoinBothSides() async throws {
        let producer = CameraFramePipeline(), box = PipelineTestBox()
        do {
            _ = try await producer.run(produce: {
                if box.take() == 2 { throw TestError.producer }
                return frame(1)
            }, consume: { _, _ in })
            preconditionFailure("Producer error ignored")
        } catch TestError.producer { }

        let consumer = CameraFramePipeline()
        do {
            _ = try await consumer.run(produce: { frame(1) },
                                       consume: { _, _ in throw TestError.consumer })
            preconditionFailure("Consumer error ignored")
        } catch TestError.consumer { }
        let produced = consumer.snapshot.produced
        try await Task.sleep(nanoseconds: 80_000_000)
        precondition(consumer.snapshot.produced == produced)
    }

    private static func staleDrops() async throws {
        let pipeline = CameraFramePipeline(), box = PipelineTestBox()
        let metrics = try await pipeline.run(produce: {
            let index = box.take()
            switch index {
            case 0: return frame(1, age: 0.6)
            case 1: return CameraEncodedFrame(data: Data([2]), selectedAt: .nan, captureMilliseconds: 1)
            case 2: return CameraEncodedFrame(data: Data([3]), selectedAt: .infinity, captureMilliseconds: 1)
            case 3: return CameraEncodedFrame(data: Data([4]),
                                              selectedAt: ProcessInfo.processInfo.systemUptime + 5,
                                              captureMilliseconds: 1)
            case 4: return frame(5)
            default: return nil
            }
        }, consume: { image, _ in box.append(Int(image.data[0])) })
        precondition(metrics.staleDropped == 4)
        precondition(metrics.consumed == 1)
        precondition(box.received == [5])
    }

    private static func concurrentRunRejected() async throws {
        let pipeline = CameraFramePipeline(), box = PipelineTestBox()
        let first = Task {
            try await pipeline.run(produce: {
                let index = box.take()
                try await Task.sleep(nanoseconds: 80_000_000)
                return index < 3 ? frame(index) : nil
            }, consume: { _, _ in })
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while box.taken == 0, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        precondition(box.taken > 0)
        do {
            _ = try await pipeline.run(produce: { nil }, consume: { _, _ in })
            preconditionFailure("Concurrent run accepted")
        } catch CameraFramePipeline.PipelineError.alreadyRunning { }
        _ = try await first.value
    }

    static func main() async throws {
        try await newestWins()
        try await cancellationJoinsProducer()
        try await errorsJoinBothSides()
        try await staleDrops()
        try await concurrentRunRejected()
        print("CameraFramePipelineTests passed")
    }
}
