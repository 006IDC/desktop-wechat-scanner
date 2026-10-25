import Foundation

@main enum WirelessReconnectTests {
    static func require(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }
    }

    static func main() {
        let suite = "wireless-reconnect-tests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { fatalError("No test defaults") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WirelessReconnectStore(defaults: defaults)
        require(store.load() == nil, "Empty store returned an endpoint")

        let first = ADBDiscoveredService(name: "adb-phone-alpha", endpoint: "192.0.2.10:30001", kind: .connection)
        let changed = ADBDiscoveredService(name: "adb-phone-alpha", endpoint: "192.0.2.10:42001", kind: .connection)
        let other = ADBDiscoveredService(name: "adb-phone-beta", endpoint: "192.0.2.20:41001", kind: .connection)
        store.save(selectedSerial: first.endpoint, services: [first, other])
        guard let remembered = store.load() else { fatalError("Selected endpoint was not saved") }
        require(remembered.serviceName == first.name, "Selected service identity was not saved")
        require(remembered.preferredEndpoint(in: [other, changed]) == changed.endpoint, "Changed port was not resolved by selected identity")
        let conflicting = ADBDiscoveredService(name: first.name, endpoint: "192.0.2.99:45001", kind: .connection)
        require(remembered.preferredEndpoint(in: [changed, conflicting]) == first.endpoint,
                "Duplicate service identity was auto-selected")
        require(remembered.preferredEndpoint(in: [other]) == first.endpoint, "Unrelated service replaced selected phone")
        require(remembered.preferredEndpoint(in: []) == first.endpoint, "Old endpoint fallback was lost")

        store.save(selectedSerial: other.endpoint, services: [])
        require(store.load()?.serviceName == nil, "Service identity was guessed without a match")
        require(store.load()?.endpoint == other.endpoint, "Manual endpoint was not remembered")
        let movedOther = ADBDiscoveredService(name: other.name, endpoint: "192.0.2.20:43001", kind: .connection)
        require(store.load()?.preferredEndpoint(in: [movedOther]) == movedOther.endpoint,
                "Unique same-host service did not recover a manual connection")
        let ambiguous = ADBDiscoveredService(name: "another-service", endpoint: "192.0.2.20:44001", kind: .connection)
        require(store.load()?.preferredEndpoint(in: [movedOther, ambiguous]) == other.endpoint,
                "Ambiguous same-host services were auto-selected")
        store.save(selectedSerial: "usb:1-2", services: [first])
        require(store.load()?.endpoint == other.endpoint, "Invalid/USB serial overwrote wireless selection")

        defaults.set(Data("{\"endpoint\":\"192.0.2.10:0\",\"serviceName\":\"adb-phone-alpha\"}".utf8),
                     forKey: "lastSelectedWirelessDevice.v1")
        require(store.load() == nil, "Invalid saved endpoint accepted")
        print("PASS selected-only endpoint memory, stable Bonjour identity, changed port, unrelated service rejection, fallback and invalid record")
    }
}
