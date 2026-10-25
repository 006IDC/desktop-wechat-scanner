import Foundation

private actor FakeWirelessConnection {
    var visible: Set<String>
    var connected = [String](), disconnected = [String]()
    var blockConnect = false, blockList = false, failConnect = false, failBeforeRegistration = false, failList = false, failDisconnect = false
    var connectStarted = false, listStarted = false, connectSettled = false, disconnectedTooEarly = false
    private var connectGate: CheckedContinuation<Void, Never>?
    private var listGate: CheckedContinuation<Void, Never>?
    init(existing: [String] = []) { visible = Set(existing) }
    func configure(blockConnect: Bool = false, blockList: Bool = false, failConnect: Bool = false,
                   failBeforeRegistration: Bool = false, failList: Bool = false, failDisconnect: Bool = false) {
        self.blockConnect = blockConnect; self.blockList = blockList; self.failConnect = failConnect
        self.failBeforeRegistration = failBeforeRegistration
        self.failList = failList; self.failDisconnect = failDisconnect
    }
    func devices() async throws -> [ADBDevice] {
        listStarted = true
        if blockList { await withCheckedContinuation { listGate = $0 } }
        if failList { throw ADBConnectionError("synthetic enumeration failure") }
        return visible.sorted().map { ADBDevice(serial: $0, model: "Synthetic", transport: .wireless, authorization: .authorized) }
    }
    func connect(_ endpoint: String) async throws {
        connected.append(endpoint); connectStarted = true
        if blockConnect { await withCheckedContinuation { connectGate = $0 } }
        if failBeforeRegistration { connectSettled = true; throw ADBConnectionError("synthetic connect never registered") }
        // Model the daemon accepting connect even though its client was
        // cancelled. Cleanup must wait for this late side effect.
        visible.insert(endpoint); connectSettled = true
        if failConnect { throw ADBConnectionError("synthetic client failure") }
        try Task.checkCancellation()
    }
    func disconnect(_ endpoint: String) throws {
        if !connectSettled { disconnectedTooEarly = true }
        disconnected.append(endpoint)
        if failDisconnect { throw ADBConnectionError("synthetic disconnect failure") }
        visible.remove(endpoint)
    }
    func releaseConnect() { connectGate?.resume(); connectGate = nil }
    func releaseList() { listGate?.resume(); listGate = nil }
    func makeLease() -> WirelessConnectionLease {
        WirelessConnectionLease(listDevices: { try await self.devices() },
                                connect: { try await self.connect($0) }, disconnect: { try await self.disconnect($0) })
    }
}

@main enum WirelessConnectionLeaseTests {
    static func require(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
    static func waitUntil(_ condition: @escaping @Sendable () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !(await condition()) {
            guard Date() < deadline else { fatalError("Synthetic operation did not start") }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
    static func main() async throws {
        let first = "192.0.2.10:30001", second = "192.0.2.20:30002"
        let fresh = FakeWirelessConnection(), freshLease = await fresh.makeLease()
        try await freshLease.connect(endpoint: first)
        require(await freshLease.close(), "New connection cleanup failed")
        require(await fresh.disconnected == [first], "New endpoint not disconnected exactly")
        require(await freshLease.close(), "Idempotent cleanup changed result")
        require(await fresh.disconnected == [first], "Cleanup ran twice")

        let existing = FakeWirelessConnection(existing: [first]), existingLease = await existing.makeLease()
        try await existingLease.connect(endpoint: first)
        require(await existingLease.close(), "Existing endpoint cleanup failed")
        require(await existing.disconnected.isEmpty, "An existing connection was disconnected")

        let selection = FakeWirelessConnection(), selectionLease = await selection.makeLease()
        try await selectionLease.connect(endpoint: first)
        try await selectionLease.connect(endpoint: second)
        require(await selectionLease.close(keeping: second), "Selection handoff cleanup failed")
        require(await selection.disconnected == [first], "Cleanup touched selected endpoint or missed another")
        require(await selection.visible == [second], "Selected connection not handed off intact")

        let late = FakeWirelessConnection(), lateLease = await late.makeLease()
        await late.configure(blockConnect: true)
        let pending = Task { try await lateLease.connect(endpoint: first) }
        try await waitUntil { await late.connectStarted }
        pending.cancel()
        let closing = Task { await lateLease.close() }
        await late.releaseConnect()
        var cancelled = false
        do { try await pending.value } catch is CancellationError { cancelled = true }
        require(cancelled, "Pending cancellation not propagated")
        require(await closing.value, "Cancelled-but-established endpoint not cleaned")
        require(await late.disconnected == [first], "Cancelled connect endpoint not disconnected exactly")
        require(await late.visible.isEmpty, "Late daemon side effect survived cleanup")
        require(!(await late.disconnectedTooEarly), "Cleanup preceded late daemon side effect")

        let preflight = FakeWirelessConnection(), preflightLease = await preflight.makeLease()
        await preflight.configure(blockList: true)
        let listing = Task { try await preflightLease.connect(endpoint: first) }
        try await waitUntil { await preflight.listStarted }
        require(await preflightLease.close(), "Closing during preflight failed")
        await preflight.releaseList()
        do { try await listing.value; fatalError("Closed preflight launched connect") } catch is CancellationError {}
        require(await preflight.connected.isEmpty, "Closing preflight launched a connection")
        require(await preflight.disconnected.isEmpty, "Closing preflight disconnected an unowned endpoint")

        let failed = FakeWirelessConnection(), failedLease = await failed.makeLease()
        await failed.configure(failConnect: true)
        do { try await failedLease.connect(endpoint: first); fatalError("Synthetic failure accepted") } catch {}
        require(await failedLease.close(), "Failed command's possible daemon side effect not cleaned")
        require(await failed.visible.isEmpty, "Failed connect left its endpoint")

        let failedBaseline = FakeWirelessConnection(), failedBaselineLease = await failedBaseline.makeLease()
        await failedBaseline.configure(failList: true)
        do { try await failedBaselineLease.connect(endpoint: first); fatalError("Missing baseline accepted") } catch {}
        require(await failedBaselineLease.close(), "Empty failed baseline cleanup failed")
        require(await failedBaseline.connected.isEmpty, "Connect launched without safe baseline")

        let failedCleanup = FakeWirelessConnection(), failedCleanupLease = await failedCleanup.makeLease()
        await failedCleanup.configure(failDisconnect: true)
        try await failedCleanupLease.connect(endpoint: first)
        require(!(await failedCleanupLease.close()), "Cleanup failure was hidden")
        let absent = FakeWirelessConnection(), absentLease = await absent.makeLease()
        await absent.configure(failBeforeRegistration: true, failDisconnect: true)
        do { try await absentLease.connect(endpoint: first); fatalError("Unregistered failure accepted") } catch {}
        require(await absentLease.close(), "Confirmed absent endpoint reported as uncleared")
        require(await absent.disconnected == [first], "Potential cancelled endpoint was not explicitly disconnected")
        print("PASS new-only endpoint ownership, existing connection preservation, selected handoff, late cancelled connect cleanup, preflight close, failures and idempotence")
    }
}
