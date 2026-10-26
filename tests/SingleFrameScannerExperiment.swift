import Foundation
import AppKit
import CoreImage
import Vision
import Darwin

/// Explicit device experiment: can a native scanner recognise one retained
/// camera image without a continuous desktop-video upload? Synthetic pixels
/// only; no desktop capture, screen permission request, screenshots or logs.
/// This proves recognition feasibility, not transparent-window UX or latency.
private struct FrameExperimentError: Error { let tag: String }
private final class ExperimentFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var pixels: CVPixelBuffer?
    private var failed = false
    func receive(_ value: CVPixelBuffer) { lock.withLock { count += 1; pixels = value } }
    func fail() { lock.withLock { failed = true } }
    func latest() -> (Int, CVPixelBuffer?, Bool) { lock.withLock { (count, pixels, failed) } }
}

@main enum SingleFrameScannerExperiment {
    static let payload = "006IDC20261026PERF"
    static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    static func wait(_ milliseconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: milliseconds * 1_000_000)
    }
    static func words(_ pixels: CVPixelBuffer) throws -> [ScannerNavigationOCR.Text] {
        try ScannerNavigationOCR.recognize(pixels)
    }
    static func ownResult(_ words: [ScannerNavigationOCR.Text]) -> Bool {
        words.contains { $0.value.replacingOccurrences(of: " ", with: "").contains(payload) }
    }
    static func image(qr: Bool) throws -> Data {
        let extent = CGRect(x: 0, y: 0, width: 720, height: 1280)
        var output = CIImage(color: CIColor.white).cropped(to: extent)
        if qr {
            guard let filter = CIFilter(name: "CIQRCodeGenerator", parameters: [
                "inputMessage": Data(payload.utf8), "inputCorrectionLevel": "M"
            ]), let code = filter.outputImage else { throw FrameExperimentError(tag: "qr_generate") }
            let scaled = code.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
            output = scaled.transformed(by: CGAffineTransform(
                translationX: (720 - scaled.extent.width) / 2,
                y: (1280 - scaled.extent.height) / 2)).composited(over: output)
        }
        guard let cg = CIContext().createCGImage(output, from: extent),
              let encoded = NSBitmapImageRep(cgImage: cg).representation(
                using: .jpeg, properties: [.compressionFactor: 0.95]) else {
            throw FrameExperimentError(tag: "image_encode")
        }
        if qr {
            let request = VNDetectBarcodesRequest(); request.symbologies = [.qr]
            try VNImageRequestHandler(data: encoded).perform([request])
            guard request.results?.contains(where: { $0.payloadStringValue == payload }) == true else {
                throw FrameExperimentError(tag: "qr_verify")
            }
        }
        return encoded
    }

    @MainActor private static func enterScanner(package: String, display: Int, phone: PhoneSession,
                                        mirror: MirrorSession, frames: ExperimentFrames,
                                        evidence: inout [String: Any]) async throws {
        var plusTapped = false, scanTapped = false, returned = false
        var knownLabels = Set<String>(), sampled = 0
        defer {
            evidence["plusTapped"] = plusTapped; evidence["scanTapped"] = scanTapped
            evidence["mirrorSamples"] = sampled; evidence["knownLabels"] = knownLabels.sorted()
        }
        let deadline = now + 12
        try await wait(600)
        while now < deadline {
            let state = try await phone.cameraState()
            if state.scannerActivity()?.package == package, state.activeStreams > 0,
               state.ownerKnown, state.cameraOwner == package { return }
            guard state.activities.contains(where: { $0.displayId == display && $0.package == package }) else {
                try await wait(120); continue
            }
            let snapshot = frames.latest()
            guard !snapshot.2 else { throw FrameExperimentError(tag: "mirror_failed") }
            if let pixels = snapshot.1, !scanTapped {
                sampled += 1
                let recognised = try await Task.detached { try words(pixels) }.value
                knownLabels.formUnion(recognised.filter {
                    ["微信", "通讯录", "发现", "我", "首页", "消息", "理财", "生活", "我的", "扫一扫", "发起群聊", "添加朋友", "收付款", "收付钱"].contains($0.value)
                }.map(\.value))
                if ownResult(recognised), !returned {
                    mirror.key(4); returned = true; try await wait(400); continue
                }
                let isWechat = package == "com.tencent.mm"
                let tabs = Set(recognised.filter {
                    $0.rect.midY > 1000 && ["消息", "理财", "生活"].contains($0.value)
                }.map(\.value))
                let alipayHome = !isWechat &&
                    (recognised.contains { $0.value == "首页" && $0.rect.midY > 1000 } || tabs.count >= 2) &&
                    recognised.contains { $0.value == "我的" && $0.rect.midY > 1000 } &&
                    recognised.contains { ["收付款", "收付钱"].contains($0.value) && $0.rect.midY < 400 }
                let wechatMenu = isWechat && plusTapped && recognised.contains {
                    ["发起群聊", "添加朋友"].contains($0.value)
                }
                if (alipayHome || wechatMenu), let scan = recognised.first(where: {
                    $0.value.replacingOccurrences(of: " ", with: "") == "扫一扫" &&
                        $0.rect.midY < (isWechat ? 800 : 400)
                }) {
                    let current = try await phone.cameraState()
                    guard current.activities.contains(where: { $0.displayId == display && $0.package == package }) else {
                        throw FrameExperimentError(tag: "navigation_changed")
                    }
                    mirror.tap(x: scan.rect.midX / 720, y: scan.rect.midY / 1280)
                    scanTapped = true; try await wait(400)
                } else if isWechat, !plusTapped,
                          let plus = try ScannerNavigationOCR.plusButton(in: pixels, homeWords: recognised) {
                    let current = try await phone.foreground(onVirtualDisplay: true)
                    guard current == "com.tencent.mm/.ui.LauncherUI" || current == "com.tencent.mm/com.tencent.mm.ui.LauncherUI" else {
                        throw FrameExperimentError(tag: "wechat_home_changed")
                    }
                    mirror.tap(x: plus.x / 720, y: plus.y / 1280)
                    plusTapped = true; try await wait(400)
                }
            }
            try await wait(120)
        }
        throw FrameExperimentError(tag: "scanner_not_confirmed")
    }

    @MainActor static func run() async -> Int32 {
        var report: [String: Any] = ["test": "single-retained-camera-frame", "passed": false]
        if CommandLine.arguments.contains("--selftest") {
            do {
                let blank = try image(qr: false), qr = try image(qr: true)
                report["passed"] = !blank.isEmpty && !qr.isEmpty
                report["syntheticOnly"] = true
            } catch { report["failure"] = (error as? FrameExperimentError)?.tag ?? "synthetic_vision_failed" }
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
               let value = String(data: data, encoding: .utf8) { print(value) }
            return report["passed"] as? Bool == true ? 0 : 1
        }
        let mirror = MirrorSession(), frames = ExperimentFrames()
        var phone: PhoneSession?, server: ADBManagedServer?, lease: WirelessConnectionLease?
        var stage = "arguments"
        do {
            guard CommandLine.arguments.contains("--run-device-test"),
                  let i = CommandLine.arguments.firstIndex(of: "--resources"),
                  CommandLine.arguments.indices.contains(i + 1) else { throw FrameExperimentError(tag: "arguments") }
            let resources = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("006IDC/DesktopWeChatScanner")
            guard !FileManager.default.fileExists(atPath: support.appendingPathComponent("session.json").path) else {
                throw FrameExperimentError(tag: "existing_session")
            }
            if let data = try? Data(contentsOf: support.appendingPathComponent("diagnostic-state.json")),
               let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               state["connected"] as? Bool == true { throw FrameExperimentError(tag: "app_connected") }
            let defaults = UserDefaults(suiteName: "com.idc006.DesktopWeChatScanner")!
            guard defaults.bool(forKey: "allowsLockedApplications.v1"),
                  let saved = WirelessReconnectStore(defaults: defaults).load() else {
                throw FrameExperimentError(tag: "saved_connection_required")
            }
            let blank = try image(qr: false), code = try image(qr: true)
            stage = "wireless"
            let adb = try await ADBConfiguration.validateAsync(resources.appendingPathComponent("adb/bin/adb"))
            let owned = try await ADBManagedServer.start(adbURL: adb); server = owned
            let manager = ADBConnectionManager(adbURL: adb, serverSocket: owned.socket, timeout: 8)
            let connection = WirelessConnectionLease(manager: manager); lease = connection
            let services = (try? await BonjourADBDiscovery().discover(seconds: 4)) ?? []
            let endpoint = saved.preferredEndpoint(in: services)
            try await connection.connect(endpoint: endpoint)
            stage = "phone_connect"
            let device = PhoneSession(resources: resources, adbURL: adb, serverSocket: owned.socket); phone = device
            _ = try await device.connect(openWechatOnConnect: false, selectedSerial: endpoint,
                                         allowLockedApplications: true, desktopHome: true, progress: { _ in })
            report["primaryLockedBefore"] = try await !device.primaryUserUnlocked()
            let route = try await device.mirrorEndpoint()
            let direct = try await device.directMirror(display: route.display)
            try await mirror.startVideo(adbURL: adb, serverURL: resources.appendingPathComponent("scrcpy-server"),
                serial: route.serial, displayID: route.display, serverSocket: owned.socket, direct: direct,
                onFrame: { frames.receive($0) }, onFailure: { _ in frames.fail() })
            let apps = try await device.applications()
            var results = [[String: Any]](), epoch = 0
            for package in ["com.tencent.mm", "com.eg.android.AlipayGphone"] {
                stage = package == "com.tencent.mm" ? "wechat" : "alipay"
                guard let app = apps.first(where: { $0.packageName == package }) else {
                    throw FrameExperimentError(tag: "test_app_unavailable")
                }
                try await device.launchApplication(app, on: route.display)
                var navigation: [String: Any] = [:]
                do {
                    try await enterScanner(package: package, display: route.display, phone: device, mirror: mirror, frames: frames, evidence: &navigation)
                } catch { report["navigation"] = navigation; throw error }
                epoch += 2; try await device.clear(epoch: epoch)
                _ = try await device.frame(blank, epoch: epoch)
                try await wait(400)
                if let before = frames.latest().1, ownResult(try words(before)) {
                    throw FrameExperimentError(tag: "old_result_visible")
                }
                let initialFrame = frames.latest().0, began = now
                let receipt = try await device.frame(code, epoch: epoch)
                var recognised = false
                while now - began < 8 {
                    let sample = frames.latest()
                    guard !sample.2 else { throw FrameExperimentError(tag: "mirror_failed") }
                    if sample.0 > initialFrame, let pixels = sample.1,
                       ownResult(try await Task.detached { try words(pixels) }.value) {
                        recognised = true; break
                    }
                    try await wait(100)
                }
                results.append(["package": package, "qrFramesUploaded": 1, "blankFramesUploaded": 1,
                    "resultRecognized": recognised, "observationMilliseconds": (now - began) * 1000,
                    "ackMilliseconds": receipt.requestMilliseconds])
                report["applications"] = results
                guard recognised else { throw FrameExperimentError(tag: "single_frame_not_recognized") }
                try await device.clear(epoch: epoch + 1)
                mirror.key(4) // Only the just-confirmed exact synthetic result.
                try await wait(500); mirror.key(3); try await wait(500)
            }
            report["primaryLockedAfter"] = try await !device.primaryUserUnlocked()
            report["passed"] = true
        } catch {
            report["stage"] = stage
            report["failure"] = (error as? FrameExperimentError)?.tag ?? "operation_failed"
        }
        await mirror.stop()
        let cleanup = await phone?.disconnect() ?? ""
        report["phoneCleanupOK"] = cleanup.isEmpty
        let wirelessClean = await lease?.close() ?? true
        report["wirelessCleanupOK"] = wirelessClean
        await server?.stop()
        if !cleanup.isEmpty || !wirelessClean { report["passed"] = false }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
           let value = String(data: data, encoding: .utf8) { print(value) }
        return report["passed"] as? Bool == true ? 0 : 1
    }
    static func main() {
        Task { @MainActor in let code = await run(); Darwin.exit(code) }
        CFRunLoopRun()
    }
}
