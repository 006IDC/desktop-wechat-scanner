import Foundation

@main enum MirrorTimingTests {
    static func require(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
    static func close(_ value: Double?, _ expected: Double, _ message: String) {
        require(value.map { abs($0 - expected) < 0.001 } == true, message)
    }
    static func main() {
        let timing = MirrorTiming(sampleCapacity: 20)
        timing.begin(epoch: 1); timing.startStream(epoch: 1)
        require(timing.recordPacket(epoch: 1, ptsMicroseconds: UInt64.max, config: true, receivedAt: 10) == nil,
                "Config packet must not become a PTS or decode sample")
        for i in 0..<20 {
            // Unrelated clock origins cancel. One ms/frame of extra delay is
            // observable backlog (and could also include unsynchronised drift).
            let ticket = timing.recordPacket(epoch: 1, ptsMicroseconds: UInt64(5_000_000 + i * 10_000),
                config: false, receivedAt: 1000 + Double(i) * 0.011)!
            timing.recordDecode(ticket, startedAt: 2000, completedAt: 2000 + Double(i + 1) / 1000, succeeded: true)
        }
        var snapshot = timing.snapshot
        require(snapshot.packetCount == 21 && snapshot.configPacketCount == 1 && snapshot.videoPacketCount == 20,
                "Config and media counts must be distinct")
        require(snapshot.decodedFrameCount == 20 && snapshot.decodeSampleCount == 20, "Decode count lost")
        close(snapshot.decodeP95Milliseconds, 19, "Nearest-rank decode p95 is incorrect")
        close(snapshot.decodeMaxMilliseconds, 20, "Decode max is incorrect")
        close(snapshot.relativeBacklogLatestMilliseconds, 19, "Clock origins did not cancel")
        close(snapshot.relativeBacklogP95Milliseconds, 18, "Backlog p95 is incorrect")
        close(snapshot.relativeBacklogMaxMilliseconds, 19, "Backlog max is incorrect")

        // Source frame gaps alone do not prove loss: static displays need not
        // encode frames at a fixed cadence. Equal receive/PTS gaps add no delay.
        _ = timing.recordPacket(epoch: 1, ptsMicroseconds: 15_190_000, config: false, receivedAt: 1010.209)
        close(timing.snapshot.relativeBacklogLatestMilliseconds, 19, "Idle gap became fabricated frame loss")
        require(timing.snapshot.decodeSampleLossCount == 0, "PTS gaps invented transport/decode loss")

        let resetTicket = timing.recordPacket(epoch: 1, ptsMicroseconds: 1000, config: false, receivedAt: 1011)!
        snapshot = timing.snapshot
        require(snapshot.ptsResetCount == 1 && snapshot.relativeBacklogSampleCount == 1, "Backwards PTS retained an old baseline/window")
        close(snapshot.relativeBacklogMaxMilliseconds, 0, "PTS reset created bogus backlog")
        timing.recordMissingDecode(resetTicket)
        let failed = timing.recordPacket(epoch: 1, ptsMicroseconds: 2000, config: false, receivedAt: 1011.001)!
        timing.recordDecode(failed, startedAt: 1, completedAt: 1.01, succeeded: false)
        let invalid = timing.recordPacket(epoch: 1, ptsMicroseconds: 3000, config: false, receivedAt: .nan)!
        timing.recordDecode(invalid, startedAt: 10, completedAt: 9, succeeded: true)
        snapshot = timing.snapshot
        require(snapshot.decodeSampleLossCount == 3 && snapshot.decodeFailureCount == 1 && snapshot.invalidTimestampCount == 1,
                "Missing/failed/invalid durations were not counted explicitly")
        require(snapshot.decodeSampleCount == 20, "Invalid decode entered the bounded sample window")

        // A large forward source-clock discontinuity must also rebase.
        _ = timing.recordPacket(epoch: 1, ptsMicroseconds: 120_000_000, config: false, receivedAt: 1011.002)
        require(timing.snapshot.ptsResetCount == 2 && timing.snapshot.relativeBacklogSampleCount == 1,
                "Forward PTS discontinuity mixed clock origins")

        timing.startStream(epoch: 1)
        timing.recordDecode(resetTicket, startedAt: 0, completedAt: 1, succeeded: true)
        snapshot = timing.snapshot
        require(snapshot.streamIncarnation == 2 && snapshot.packetCount == 0 && snapshot.decodedFrameCount == 0,
                "New encoder incarnation accepted stale decode work or retained old counts")
        let old = timing.recordPacket(epoch: 1, ptsMicroseconds: 0, config: false, receivedAt: 10)!
        timing.invalidate(epoch: 1)
        timing.recordMissingDecode(old)
        require(timing.recordPacket(epoch: 1, ptsMicroseconds: 1, config: false, receivedAt: 11) == nil,
                "Stopped session accepted new samples")
        require(!timing.snapshot.active && timing.snapshot.packetCount == 1 && timing.snapshot.decodeSampleLossCount == 0,
                "Stop must freeze existing diagnostics and reject late callbacks")
        timing.begin(epoch: 2); timing.startStream(epoch: 2)
        timing.invalidate(epoch: 1); timing.startStream(epoch: 1)
        timing.recordDecode(old, startedAt: 0, completedAt: 1, succeeded: true)
        require(timing.snapshot.active && timing.snapshot.packetCount == 0 && timing.snapshot.streamIncarnation == 1,
                "Old session invalidated/reset a new session")

        for i in 0..<1000 {
            let ticket = timing.recordPacket(epoch: 2, ptsMicroseconds: UInt64(i * 1000), config: false,
                                             receivedAt: 20 + Double(i) / 1000)!
            timing.recordDecode(ticket, startedAt: 0, completedAt: i == 0 ? 1 : 0.001, succeeded: true)
        }
        snapshot = timing.snapshot
        require(snapshot.decodeSampleCount == 20 && snapshot.relativeBacklogSampleCount == 20 && snapshot.packetCount == 1000,
                "Recent samples must stay bounded while lifetime counts continue")
        close(snapshot.decodeMaxMilliseconds, 1, "Old outlier survived bounded recent window")
        DispatchQueue.concurrentPerform(iterations: 10_000) { _ in
            let ticket = timing.recordPacket(epoch: 2, ptsMicroseconds: 1_000_000, config: false, receivedAt: 21)!
            timing.recordDecode(ticket, startedAt: 0, completedAt: 0.001, succeeded: true)
            _ = timing.snapshot
        }
        require(timing.snapshot.packetCount == 11_000 && timing.snapshot.decodedFrameCount == 11_000,
                "Concurrent snapshots/recording lost counts")
        print("PASS bounded mirror timing, relative backlog/drift, PTS resets, sample loss, incarnation/stop isolation and concurrent snapshots")
    }
}
