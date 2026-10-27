import Foundation
import Darwin

/// Only a previously selected connection address and optional Bonjour service
/// identity are retained. ADB itself owns pairing trust; no code is saved here.
struct RememberedWirelessDevice: Codable, Equatable {
    let endpoint: String
    let serviceName: String?

    init?(endpoint: String, serviceName: String?) {
        guard let validated = try? ADBEndpoint(endpoint) else { return nil }
        self.endpoint = validated.value
        let name = serviceName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.serviceName = (name?.isEmpty == false && (name?.utf8.count ?? 0) <= 255) ? name : nil
    }

    func preferredEndpoint(in services: [ADBDiscoveredService]) -> String {
        if let serviceName {
            let named = services.filter { $0.kind == .connection && $0.name == serviceName }
            return named.count == 1 ? named[0].endpoint : endpoint
        }
        // An earlier manual connection may have preceded local-network
        // permission. Match the same host only if discovery is unambiguous.
        guard let oldHost = try? ADBEndpoint(endpoint).host else { return endpoint }
        let sameHost = services.filter {
            $0.kind == .connection && (try? ADBEndpoint($0.endpoint).host) == oldHost
        }
        return sameHost.count == 1 ? sameHost[0].endpoint : endpoint
    }
}

final class WirelessReconnectStore {
    private let defaults: UserDefaults
    private let key = "lastSelectedWirelessDevice.v1"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> RememberedWirelessDevice? {
        guard let data = defaults.data(forKey: key),
              let saved = try? JSONDecoder().decode(RememberedWirelessDevice.self, from: data)
        else { return nil }
        return RememberedWirelessDevice(endpoint: saved.endpoint, serviceName: saved.serviceName)
    }

    func save(selectedSerial: String, services: [ADBDiscoveredService]) {
        guard let endpoint = try? ADBEndpoint(selectedSerial).value else { return }
        let service = services.first { $0.kind == .connection && $0.endpoint == endpoint }
        guard let remembered = RememberedWirelessDevice(endpoint: endpoint, serviceName: service?.name),
              let data = try? JSONEncoder().encode(remembered) else { return }
        defaults.set(data, forKey: key)
    }
}

/// Native Bonjour is independent of the bundled ADB's disabled mDNS client.
/// One short-lived instance belongs to one chooser operation and stops on exit.
@MainActor
final class BonjourADBDiscovery: NSObject, @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    private var browser: NetServiceBrowser?
    private var resolving = [String: NetService]()
    private var found = [String: ADBDiscoveredService]()
    private var discoveredServiceCount = 0
    private var searchFailed = false
    private(set) var searchFailureCode: Int?

    func discover(seconds: TimeInterval = 2) async throws -> [ADBDiscoveredService] {
        let browser = NetServiceBrowser()
        self.browser = browser
        browser.delegate = self
        browser.searchForServices(ofType: "_adb-tls-connect._tcp.", inDomain: "local.")
        defer { stop() }
        try await Task.sleep(nanoseconds: UInt64(max(0.1, min(seconds, 8)) * 1_000_000_000))
        try Task.checkCancellation()
        if searchFailed { throw ADBConnectionError("局域网发现未能启动。请检查此 App 的本地网络权限。") }
        if discoveredServiceCount > 0 && found.isEmpty {
            throw ADBConnectionError("发现了无线调试服务，但未能及时取得其地址。可填写手机无线调试主页的连接地址。")
        }
        return found.values.sorted { $0.name < $1.name }
    }

    func stop() {
        browser?.stop(); browser?.delegate = nil; browser = nil
        for service in resolving.values { service.stop(); service.delegate = nil }
        resolving.removeAll()
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        let identity = service.name + "." + service.domain
        guard resolving[identity] == nil else { return }
        discoveredServiceCount += 1
        resolving[identity] = service
        service.delegate = self
        service.resolve(withTimeout: 7)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        searchFailed = true
        searchFailureCode = errorDict["NSNetServicesErrorCode"]?.intValue
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        let identity = service.name + "." + service.domain
        resolving.removeValue(forKey: identity)?.stop()
        found.removeValue(forKey: identity)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard sender.port > 0 && sender.port <= 65535 else { return }
        let identity = sender.name + "." + sender.domain
        for address in sender.addresses ?? [] {
            guard address.count >= MemoryLayout<sockaddr>.size,
                  address.count <= MemoryLayout<sockaddr_storage>.size else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            var storage = sockaddr_storage()
            withUnsafeMutableBytes(of: &storage) { destination in
                destination.copyBytes(from: address)
            }
            let status = withUnsafePointer(to: &storage) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getnameinfo($0, socklen_t(address.count), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                }
            }
            guard status == 0 else { continue }
            let hostBytes = host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            guard let addressText = String(bytes: hostBytes, encoding: .utf8) else { continue }
            let endpointText = addressText.contains(":") ? "[\(addressText)]:\(sender.port)" : "\(addressText):\(sender.port)"
            guard let endpoint = try? ADBEndpoint(endpointText) else { continue }
            // Prefer IPv4 when both are published; link-local IPv6 needs a
            // scope ID that ADBEndpoint intentionally does not accept.
            if found[identity] == nil || !addressText.contains(":") {
                found[identity] = ADBDiscoveredService(name: sender.name, endpoint: endpoint.value, kind: .connection)
            }
        }
    }

}
