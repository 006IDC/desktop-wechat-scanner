import Foundation

/// Small, authenticated status snapshot; never persisted or sent to telemetry.
struct PhoneCameraState: Decodable, Sendable {
    struct Activity: Decodable, Sendable {
        let displayId: Int
        let component: String
        var package: String { String(component.split(separator: "/").first ?? "") }
        var valid: Bool {
            displayId > 0 && AndroidApplication(packageName: package, component: component, name: "").isValid
        }
    }
    let version: Int
    let generation: Int
    let activeStreams: Int
    let activities: [Activity]
    let desktopHome: Bool
    let cameraOwner: String?
    let ownerStatus: String?
    let ownerKnown: Bool
    let ownerGeneration: Int

    private enum CodingKeys: String, CodingKey {
        case version, generation, activeStreams, activities, desktopHome
        case cameraOwner, ownerKnown, ownerGeneration, ownerStatus
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        generation = try values.decode(Int.self, forKey: .generation)
        activeStreams = try values.decode(Int.self, forKey: .activeStreams)
        activities = try values.decode([Activity].self, forKey: .activities)
        desktopHome = try values.decode(Bool.self, forKey: .desktopHome)
        cameraOwner = try values.decodeIfPresent(String.self, forKey: .cameraOwner)
        // Older servers omitted ownership evidence. Treat absence as unknown.
        ownerKnown = try values.decodeIfPresent(Bool.self, forKey: .ownerKnown) ?? false
        ownerStatus = try values.decodeIfPresent(String.self, forKey: .ownerStatus)
        ownerGeneration = try values.decodeIfPresent(Int.self, forKey: .ownerGeneration) ?? 0
    }

    func scannerActivity() -> Activity? {
        guard ownerKnown, (1...16).contains(activeStreams), let cameraOwner,
              Self.validOwner(cameraOwner), ownerGeneration >= 0,
              activities.count <= 8, activities.allSatisfy(\.valid),
              Set(activities.map(\.displayId)).count == activities.count else { return nil }
        let candidates = activities.filter { DesktopScannerRoute.isScanner($0.component) }
        guard candidates.count == 1, candidates[0].package == cameraOwner,
              activities.filter({ $0.package == cameraOwner }).count == 1 else { return nil }
        return candidates[0]
    }

    private static func validOwner(_ owner: String) -> Bool {
        owner.utf8.count <= 255 &&
            owner.range(of: "^[A-Za-z_][A-Za-z0-9_]*(\\.[A-Za-z_][A-Za-z0-9_]*)+$",
                        options: .regularExpression) != nil
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 16_384 else { throw ScanError("手机相机状态过大。") }
        let state = try JSONDecoder().decode(Self.self, from: data)
        guard state.version == 1, state.generation >= 0, (0...16).contains(state.activeStreams),
              state.ownerGeneration >= 0,
              state.ownerStatus.map({$0.utf8.count <= 64}) ?? true,
              state.cameraOwner.map(validOwner) ?? true,
              state.activities.count <= 8, state.activities.allSatisfy(\.valid),
              Set(state.activities.map(\.displayId)).count == state.activities.count else {
            throw ScanError("手机相机状态无效。")
        }
        return state
    }
}

/// Camera use alone is not scanner intent. Keep the verified scanner routes
/// explicit; unknown apps continue as normal phone apps without desktop capture.
enum DesktopScannerRoute {
    static func isScanner(_ component: String) -> Bool {
        component == "com.tencent.mm/.plugin.scanner.ui.BaseScanUI" ||
            component == "com.tencent.mm/com.tencent.mm.plugin.scanner.ui.BaseScanUI" ||
            component == "com.eg.android.AlipayGphone/com.alipay.mobile.scan.as.main.MainCaptureActivity"
    }
}
