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
    struct CameraBinding:Decodable,Sendable {
        let displayId:Int
        let packageName:String
        var valid:Bool {displayId>0 && PhoneCameraState.validOwner(packageName)}
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
    let solidCalibrationSupported: Bool
    let desktopCameraSupported:Bool
    let desktopCameraEnabled:Bool
    let desktopCameraGeneration:Int
    let desktopCameraBindings:[CameraBinding]

    private enum CodingKeys: String, CodingKey {
        case version, generation, activeStreams, activities, desktopHome
        case cameraOwner, ownerKnown, ownerGeneration, ownerStatus
        case solidCalibrationSupported,desktopCameraSupported,desktopCameraEnabled,desktopCameraGeneration,desktopCameraBindings
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
        solidCalibrationSupported = try values.decodeIfPresent(Bool.self, forKey: .solidCalibrationSupported) ?? false
        desktopCameraSupported=try values.decodeIfPresent(Bool.self,forKey:.desktopCameraSupported) ?? false
        desktopCameraEnabled=try values.decodeIfPresent(Bool.self,forKey:.desktopCameraEnabled) ?? false
        desktopCameraGeneration=try values.decodeIfPresent(Int.self,forKey:.desktopCameraGeneration) ?? 0
        desktopCameraBindings=try values.decodeIfPresent([CameraBinding].self,forKey:.desktopCameraBindings) ?? []
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

    /// Explicit connection source + selected owned window, without app/page allowlists.
    /// Camera use alone does not opt the connection into desktop input.
    func captureActivity()->Activity? {
        guard desktopCameraEnabled else{return scannerActivity()}
        guard desktopCameraSupported,ownerKnown,(1...16).contains(activeStreams),let owner=cameraOwner,Self.validOwner(owner),
              generation>=0,ownerGeneration>=0,desktopCameraGeneration>=0,activities.count<=8,activities.allSatisfy(\.valid),
              Set(activities.map(\.displayId)).count==activities.count,desktopCameraBindings.count<=8,
              desktopCameraBindings.allSatisfy(\.valid),Set(desktopCameraBindings.map(\.displayId)).count==desktopCameraBindings.count else{return nil}
        let foreground=activities.filter{$0.package==owner}
        guard foreground.count==1,let activity=foreground.first,
              desktopCameraBindings.contains(where:{$0.displayId==activity.displayId && $0.packageName==owner}) else{return nil}
        return activity
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
              state.desktopCameraGeneration>=0,state.desktopCameraBindings.count<=8,
              state.desktopCameraBindings.allSatisfy(\.valid),
              Set(state.desktopCameraBindings.map(\.displayId)).count==state.desktopCameraBindings.count,
              !state.desktopCameraEnabled || state.desktopCameraSupported,
              state.desktopCameraEnabled || state.desktopCameraBindings.isEmpty,
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
