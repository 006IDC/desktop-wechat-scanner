import Foundation

/// Tracks only explicit connect attempts made by one chooser. A cancelled adb
/// client may already have asked the daemon to connect, so pending attempts are
/// owned before launch, then settled before exact-endpoint cleanup starts.
actor WirelessConnectionLease {
    typealias ListDevices = @Sendable () async throws -> [ADBDevice]
    typealias EndpointOperation = @Sendable (String) async throws -> Void
    private let listDevices: ListDevices
    private let connectEndpoint: EndpointOperation
    private let disconnectEndpoint: EndpointOperation
    private var candidates = Set<String>()
    private var pending = [UUID: Task<Void, Error>]()
    private var closed = false
    private var cleanup: Task<Bool, Never>?

    init(manager: ADBConnectionManager) {
        listDevices = { try await manager.devices() }
        connectEndpoint = { try await manager.connect(endpoint: $0) }
        disconnectEndpoint = { try await manager.disconnect(endpoint: $0) }
    }

    /// Injection is for synthetic tests; production always uses the manager.
    init(listDevices: @escaping ListDevices, connect: @escaping EndpointOperation, disconnect: @escaping EndpointOperation) {
        self.listDevices = listDevices
        connectEndpoint = connect
        disconnectEndpoint = disconnect
    }

    func connect(endpoint input: String) async throws {
        let endpoint = try ADBEndpoint(input).value
        guard !closed else { throw CancellationError() }
        // If this cannot be established safely, do not issue connect at all.
        let before = try await listDevices()
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        let existed = before.contains { (try? ADBEndpoint($0.serial).value) == endpoint }
        if !existed { candidates.insert(endpoint) }
        let id = UUID(), operation = connectEndpoint
        let command = Task { try await operation(endpoint) }
        pending[id] = command
        do {
            // Keep the bounded connect command owned until its server reply
            // (or its own timeout). Killing only its client on chooser close
            // could race a daemon-side connect with the subsequent disconnect.
            // The cancelled caller still cannot select or publish its result.
            try await command.value
            try Task.checkCancellation()
            pending.removeValue(forKey: id)
        } catch {
            pending.removeValue(forKey: id)
            // Keep a new endpoint as a cleanup candidate even on failure:
            // command cancellation is not evidence the daemon did nothing.
            throw error
        }
    }

    /// Idempotent and deliberately independent of caller cancellation. Only an
    /// exact selected endpoint is transferred to App; all other new endpoints
    /// are disconnected. Existing connections and pairing trust are untouched.
    func close(keeping selectedSerial: String? = nil) async -> Bool {
        if let cleanup { return await cleanup.value }
        closed = true
        let keep = selectedSerial.flatMap { try? ADBEndpoint($0).value }
        let commands = Array(pending.values)
        let endpoints = candidates.filter { $0 != keep }.sorted()
        let disconnect = disconnectEndpoint, list = listDevices
        let work = Task.detached(priority: .userInitiated) {
            for command in commands { _ = try? await command.value }
            var succeeded = true
            for endpoint in endpoints {
                do { try await disconnect(endpoint) }
                catch {
                    // A cancelled attempt may never have registered a
                    // transport; adb then reports "no such device". Confirm
                    // absence rather than claiming a remaining connection.
                    if let remaining = try? await list(),
                       !remaining.contains(where: { (try? ADBEndpoint($0.serial).value) == endpoint }) { continue }
                    succeeded = false
                }
            }
            return succeeded
        }
        cleanup = work
        return await work.value
    }
}
