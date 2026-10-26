import Foundation

/// Numeric, memory-only diagnostics. Phone PTS and Mac uptime have unrelated
/// origins: the minimum observed receive-minus-PTS offset is a baseline, so
/// relativeBacklog measures extra queueing/clock drift, NOT absolute latency.
final class MirrorTiming: @unchecked Sendable {
    struct Ticket: Equatable {
        fileprivate let epoch: Int
        fileprivate let incarnation: UInt64
    }
    /// Counts cover the current stream incarnation. Durations, percentiles and
    /// maxima cover at most the latest 240 samples (the default capacity).
    struct Snapshot: Sendable {
        let active: Bool
        let streamIncarnation: UInt64
        let packetCount: UInt64
        let configPacketCount: UInt64
        let videoPacketCount: UInt64
        let decodedFrameCount: UInt64
        let decodeFailureCount: UInt64
        /// Media packets without a usable decode duration, not transport loss.
        let decodeSampleLossCount: UInt64
        let ptsResetCount: UInt64
        let invalidTimestampCount: UInt64
        let decodeSampleCount: Int
        let decodeLatestMilliseconds: Double?
        let decodeP95Milliseconds: Double?
        let decodeMaxMilliseconds: Double?
        let relativeBacklogSampleCount: Int
        let relativeBacklogLatestMilliseconds: Double?
        let relativeBacklogP95Milliseconds: Double?
        let relativeBacklogMaxMilliseconds: Double?
    }
    private struct Samples {
        let capacity: Int
        var values: [Double] = []
        var next = 0
        var latest: Double?
        mutating func append(_ value: Double) {
            latest = value
            if values.count < capacity { values.append(value) }
            else { values[next] = value; next = (next + 1) % capacity }
        }
        func summary(subtracting baseline: Double = 0) -> (Double?, Double?, Double?) {
            guard !values.isEmpty else { return (nil, nil, nil) }
            let sorted = values.map { max(0, $0 - baseline) }.sorted()
            let index = max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)
            return (latest.map { max(0, $0 - baseline) }, sorted[index], sorted.last)
        }
    }
    private let lock = NSLock()
    private let capacity: Int
    private var epoch = 0, active = false
    private var incarnation: UInt64 = 0
    private var packets: UInt64 = 0, configs: UInt64 = 0, videos: UInt64 = 0
    private var decoded: UInt64 = 0, failures: UInt64 = 0, losses: UInt64 = 0
    private var ptsResets: UInt64 = 0, invalidTimestamps: UInt64 = 0
    private var previousPTS: UInt64?, previousReceive: Double?, minimumOffset: Double?
    private var decodeSamples: Samples, receiveOffsets: Samples

    init(sampleCapacity: Int = 240) {
        capacity = min(2048, max(1, sampleCapacity))
        decodeSamples = Samples(capacity: capacity)
        receiveOffsets = Samples(capacity: capacity)
    }
    func begin(epoch: Int) {
        lock.withLock {
            self.epoch = epoch; active = true; incarnation = 0
            clearStream()
        }
    }
    /// Session headers denote a new encoder/size incarnation. Late measurements
    /// from the previous incarnation must not enter this stream's statistics.
    func startStream(epoch: Int) {
        lock.withLock {
            guard active, self.epoch == epoch else { return }
            incarnation += 1; clearStream()
        }
    }
    func invalidate(epoch: Int) {
        lock.withLock { if self.epoch == epoch { active = false } }
    }
    private func clearStream() {
        packets = 0; configs = 0; videos = 0; decoded = 0; failures = 0; losses = 0
        ptsResets = 0; invalidTimestamps = 0
        previousPTS = nil; previousReceive = nil; minimumOffset = nil
        decodeSamples = Samples(capacity: capacity); receiveOffsets = Samples(capacity: capacity)
    }
    func recordPacket(epoch: Int, ptsMicroseconds: UInt64, config: Bool, receivedAt: Double) -> Ticket? {
        lock.withLock {
            guard active, self.epoch == epoch else { return nil }
            packets += 1
            if config { configs += 1; return nil }
            videos += 1
            let ticket = Ticket(epoch: epoch, incarnation: incarnation)
            guard receivedAt.isFinite, receivedAt >= 0 else {
                invalidTimestamps += 1; return ticket
            }
            let pts = Double(ptsMicroseconds) / 1_000_000
            if let previousPTS, let previousReceive,
               ptsMicroseconds < previousPTS || receivedAt < previousReceive ||
               pts - Double(previousPTS) / 1_000_000 > receivedAt - previousReceive + 30 {
                // Clock/PTS discontinuity: do not mix old and new offset origins.
                ptsResets += 1; minimumOffset = nil
                receiveOffsets = Samples(capacity: capacity)
            }
            let offset = receivedAt - pts
            minimumOffset = min(minimumOffset ?? offset, offset)
            receiveOffsets.append(offset)
            previousPTS = ptsMicroseconds; previousReceive = receivedAt
            return ticket
        }
    }
    /// Called at decoder callback entry, before rendering or consumer work.
    func recordDecode(_ ticket: Ticket, startedAt: Double, completedAt: Double, succeeded: Bool) {
        lock.withLock {
            guard accepts(ticket) else { return }
            guard succeeded else { failures += 1; losses += 1; return }
            decoded += 1
            guard startedAt.isFinite, completedAt.isFinite, completedAt >= startedAt else {
                losses += 1; return
            }
            decodeSamples.append((completedAt - startedAt) * 1000)
        }
    }
    func recordMissingDecode(_ ticket: Ticket, failed: Bool = false) {
        lock.withLock {
            guard accepts(ticket) else { return }
            losses += 1
            if failed { failures += 1 }
        }
    }
    private func accepts(_ ticket: Ticket) -> Bool {
        active && ticket.epoch == epoch && ticket.incarnation == incarnation
    }
    var snapshot: Snapshot {
        lock.withLock {
            let decode = decodeSamples.summary()
            let backlog = receiveOffsets.summary(subtracting: minimumOffset ?? 0)
            return Snapshot(active: active, streamIncarnation: incarnation,
                packetCount: packets, configPacketCount: configs, videoPacketCount: videos,
                decodedFrameCount: decoded, decodeFailureCount: failures, decodeSampleLossCount: losses,
                ptsResetCount: ptsResets, invalidTimestampCount: invalidTimestamps,
                decodeSampleCount: decodeSamples.values.count,
                decodeLatestMilliseconds: decode.0, decodeP95Milliseconds: decode.1, decodeMaxMilliseconds: decode.2,
                relativeBacklogSampleCount: receiveOffsets.values.count,
                relativeBacklogLatestMilliseconds: backlog.0.map { $0 * 1000 },
                relativeBacklogP95Milliseconds: backlog.1.map { $0 * 1000 },
                relativeBacklogMaxMilliseconds: backlog.2.map { $0 * 1000 })
        }
    }
}
