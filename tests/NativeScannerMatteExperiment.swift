import Foundation
import AppKit
import CoreImage
import Vision
import Darwin

/// Research-only native UI matting experiment. All camera inputs are synthetic.
/// No screen capture, permission request, phone image export or product activation.
/// Completion is distinct from matte-model/visual equivalence validation.
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

@main enum NativeScannerMatteExperiment {
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
        let beganNavigation = now
        defer {
            evidence["plusTapped"] = plusTapped; evidence["scanTapped"] = scanTapped
            evidence["mirrorSamples"] = sampled; evidence["knownLabels"] = knownLabels.sorted()
            evidence["navigationMilliseconds"] = (now - beganNavigation) * 1000
            evidence["mirrorFrameCount"] = frames.latest().0
        }
        let deadline = now + 25
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
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: "Explicit native scanner experiment")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        var report: [String: Any] = ["test": CommandLine.arguments.contains("--show-native-chroma") ? "native-chroma-preview" : CommandLine.arguments.contains("--native-matte-probe") ? "native-scanner-matte" : CommandLine.arguments.contains("--recover-only") ? "session-recovery" : "single-retained-camera-frame", "passed": false]
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
        var heartbeat: Task<Void, Never>?
        var stage = "arguments"
        do {
            guard CommandLine.arguments.contains("--run-device-test"),
                  let i = CommandLine.arguments.firstIndex(of: "--resources"),
                  CommandLine.arguments.indices.contains(i + 1) else { throw FrameExperimentError(tag: "arguments") }
            let resources = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("006IDC/DesktopWeChatScanner")
            guard !FileManager.default.fileExists(atPath: support.appendingPathComponent("session.json").path) || CommandLine.arguments.contains("--recover-only") else {
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
            var services = [ADBDiscoveredService]()
            do { services = try await BonjourADBDiscovery().discover(seconds: 8) }
            catch { report["discoveryFailed"] = true }
            report["discoveredConnections"] = services.filter { $0.kind == .connection }.count
            report["exactSavedNameMatches"] = services.filter { $0.name == saved.serviceName }.count
            report["savedHasServiceName"] = saved.serviceName != nil
            let endpoint = saved.preferredEndpoint(in: services)
            report["usingSavedEndpoint"] = endpoint == saved.endpoint
            try await connection.connect(endpoint: endpoint)
            stage = "phone_connect"
            let device = PhoneSession(resources: resources, adbURL: adb, serverSocket: owned.socket); phone = device
            _ = try await device.connect(openWechatOnConnect: false, selectedSerial: endpoint,
                                         allowLockedApplications: true, desktopHome: true,
                balancedDisplay: CommandLine.arguments.contains("--balanced-display"),
                displayBeforeCamera: CommandLine.arguments.contains("--display-before-camera"), progress: { _ in })
            heartbeat = Task.detached {
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 2_000_000_000); try Task.checkCancellation(); try await device.heartbeat() }
                    catch { return }
                }
            }
            if !CommandLine.arguments.contains("--recover-only") {
            report["primaryLockedBefore"] = try await !device.primaryUserUnlocked()
            let route = try await device.mirrorEndpoint()
            let direct = try await device.directMirror(display: route.display)
            try await mirror.startVideo(adbURL: adb, serverURL: resources.appendingPathComponent("scrcpy-server"),
                serial: route.serial, displayID: route.display, serverSocket: owned.socket, direct: direct,
                onFrame: { frames.receive($0) }, onFailure: { _ in frames.fail() })
            let apps = try await device.applications()
            var results = [[String: Any]](), epoch = 0
            let matteProbe = CommandLine.arguments.contains("--native-matte-probe") || CommandLine.arguments.contains("--show-native-chroma")
            let packages = CommandLine.arguments.contains("--show-native-chroma") ? ["com.tencent.mm"] : ["com.tencent.mm", "com.eg.android.AlipayGphone"]
            for package in packages {
                stage = package == "com.tencent.mm" ? "wechat" : "alipay"
                guard let app = apps.first(where: { $0.packageName == package }) else {
                    throw FrameExperimentError(tag: "test_app_unavailable")
                }
                stage = package == "com.tencent.mm" ? "wechat_launch" : "alipay_launch"
                try await device.launchApplication(app, on: route.display)
                stage = package == "com.tencent.mm" ? "wechat_navigation" : "alipay_navigation"
                var navigation: [String: Any] = [:]
                do {
                    try await enterScanner(package: package, display: route.display, phone: device, mirror: mirror, frames: frames, evidence: &navigation)
                } catch { report["navigation"] = navigation; throw error }
                if let pixels = frames.latest().1 {
                    report["mirrorDimensions"] = [CVPixelBufferGetWidth(pixels), CVPixelBufferGetHeight(pixels)]
                }
                epoch += 2; try await device.clear(epoch: epoch)
                _ = try await device.frame(blank, epoch: epoch)
                try await wait(400)
                if let before = frames.latest().1, ownResult(try words(before)) {
                    throw FrameExperimentError(tag: "old_result_visible")
                }
                if matteProbe {
                    var samples = [[UInt8]]()
                    var calibrationPixels = [CVPixelBuffer]()
                    var counts = [Int]()
                    for brightness in [0.0, 1.0, 0.5] {
                        stage = "matte_" + (brightness == 0 ? "black" : brightness == 1 ? "white" : "gray")
                        let testImage = try NativeScannerMatteProbe.solid(brightness)
                        _ = try await device.frame(testImage, epoch: epoch)
                        try await wait(600)
                        var phaseFrames = [[UInt8]](), previous = frames.latest().0
                        var selectedPixels: CVPixelBuffer?
                        for _ in 0..<3 {
                            let until = now + 2
                            while frames.latest().0 <= previous && now < until { try await wait(20) }
                            let snapshot = frames.latest()
                            guard !snapshot.2, snapshot.0 > previous, let pixels = snapshot.1 else {
                                throw FrameExperimentError(tag: "matte_fresh_frame_missing")
                            }
                            let state = try await device.cameraState()
                            guard state.scannerActivity()?.package == package, state.ownerKnown,
                                  state.cameraOwner == package, state.activeStreams > 0 else {
                                throw FrameExperimentError(tag: "matte_scanner_changed")
                            }
                            phaseFrames.append(try NativeScannerMatteProbe.sample(pixels))
                            selectedPixels = pixels
                            previous = snapshot.0
                        }
                        if let pixels = selectedPixels { calibrationPixels.append(pixels) }
                        guard let selected = phaseFrames.last else { throw FrameExperimentError(tag: "matte_samples_missing") }
                        samples.append(selected)
                        counts.append(previous)
                    }
                    var metrics = try NativeScannerMatteProbe.analyse(black: samples[0], white: samples[1], gray: samples[2])
                    guard calibrationPixels.count == 3 else { throw FrameExperimentError(tag: "matte_samples_missing") }
                    report["calibrationDimensions"] = [CVPixelBufferGetWidth(calibrationPixels[0]), CVPixelBufferGetHeight(calibrationPixels[0])]
                    stage = "matte_gpu_setup"
                    let chroma = CommandLine.arguments.contains("--show-native-chroma")
                    let setupBegan = now
                    let renderer = try await Task.detached {
                        try NativeScannerMatte(black: CIImage(cvPixelBuffer: calibrationPixels[0]),
                            white: CIImage(cvPixelBuffer: calibrationPixels[1]),
                            algorithm: chroma ? .blueWithNativeColorBias : .blackWhite)
                    }.value
                    metrics["gpuSetupMilliseconds"] = (now - setupBegan) * 1000
                    stage = "matte_live_render"
                    _ = try await device.frame(chroma ? NativeScannerMatteProbe.blue() : NativeScannerMatteProbe.solid(0), epoch: epoch)
                    try await wait(500)
                    let preview = chroma ? NativeMattePreview(size: CIImage(cvPixelBuffer: calibrationPixels[0]).extent.size) : nil
                    preview?.show()
                    defer { preview?.close() }
                    let mailbox = preview?.mailbox
                    let renderedDurations = try await Task.detached { () throws -> [Double] in
                        var durations = [Double](), lastFrame = frames.latest().0
                        var nextOwnerCheck = now
                        let renderUntil = now + (chroma ? 60 : 3)
                        while now < renderUntil && mailbox?.latest().2 != true {
                            if now >= nextOwnerCheck {
                                let owner = try await device.cameraState()
                                guard owner.scannerActivity()?.package == package, owner.ownerKnown,
                                      owner.cameraOwner == package, owner.activeStreams > 0 else {
                                    throw FrameExperimentError(tag: "chroma_scanner_changed")
                                }
                                nextOwnerCheck = now + 0.25
                            }
                            let sample = frames.latest()
                            guard !sample.2 else { throw FrameExperimentError(tag: "mirror_failed") }
                            if sample.0 > lastFrame, let pixels = sample.1 {
                                let began = now
                                let image = try renderer.render(black: CIImage(cvPixelBuffer: pixels))
                                durations.append((now - began) * 1000)
                                mailbox?.publish(image)
                                lastFrame = sample.0
                            }
                            try await wait(5)
                        }
                        return durations
                    }.value
                    metrics["presentations"] = preview?.presentations ?? 0
                    metrics["algorithm"] = chroma ? "blue_with_static_native_color_bias" : "black_white_calibration"
                    metrics["visualEquivalenceValidated"] = false
                    preview?.close()
                    var durations = renderedDurations
                    durations.sort()
                    metrics["renderedFrames"] = durations.count
                    metrics["renderMillisecondsP95"] = durations.isEmpty ? -1 : durations[Int(Double(durations.count - 1) * 0.95)]
                    metrics["renderMillisecondsMax"] = durations.last ?? -1
                    let timing = mirror.timingSnapshot
                    metrics["decodeMillisecondsP95"] = timing.decodeP95Milliseconds ?? -1
                    metrics["relativeBacklogMillisecondsP95"] = timing.relativeBacklogP95Milliseconds ?? -1
                    metrics["decodeFailures"] = timing.decodeFailureCount
                    metrics["navigation"] = navigation
                    results.append(["package": package, "matte": metrics, "freshFrames": counts.count == 3])
                    report["applications"] = results
                    try await device.clear(epoch: epoch + 1, requireConnection: true)
                    let closingState = try await device.cameraState()
                    if closingState.scannerActivity()?.package == package {
                        mirror.key(4) // Close only this exact confirmed native scanner.
                        try await wait(500)
                    }
                    continue
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
            }
            report["experimentCompleted"] = true
            if CommandLine.arguments.contains("--show-native-chroma") {
                report["passed"] = false // A preview alone never certifies visual equivalence.
            } else if CommandLine.arguments.contains("--native-matte-probe"),
               let results = report["applications"] as? [[String: Any]] {
                report["passed"] = results.count == 2 && results.allSatisfy {
                    guard let m = $0["matte"] as? [String: Any] else { return false }
                    return m["modelSupported"] as? Bool == true &&
                        (m["renderedFrames"] as? Int ?? 0) >= 75 &&
                        (m["renderMillisecondsP95"] as? Double ?? 100) < 16.7
                }
            } else { report["passed"] = true }
        } catch {
            report["stage"] = stage
            report["connectionStage"] = await phone?.connectionStage ?? "not_created"
            for tag in ["virtual_device", "camera_policy", "virtual_camera", "camera_register", "camera_identifier", "camera_owner_watch", "owned_display", "session_channel"] {
                if let description = ServerLog.setupDescription(tag), error.localizedDescription.contains(description) { report["serverSetupPhase"] = tag }
            }
            report["failure"] = (error as? FrameExperimentError)?.tag ?? (error as? NativeScannerMatte.Unavailable)?.stage ?? failureCategory(error.localizedDescription)
            report["errorClass"] = String(reflecting: type(of: error))
        }
        heartbeat?.cancel(); await heartbeat?.value
        await mirror.stop()
        let cleanup = await phone?.disconnect() ?? ""
        report["phoneCleanupOK"] = cleanup.isEmpty
        if !cleanup.isEmpty { report["phoneCleanupFailure"] = failureCategory(cleanup) }
        let wirelessClean = await lease?.close() ?? true
        report["wirelessCleanupOK"] = wirelessClean
        await server?.stop()
        if !cleanup.isEmpty || !wirelessClean { report["passed"] = false }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
           let value = String(data: data, encoding: .utf8) { print(value) }
        return report["passed"] as? Bool == true ? 0 : 1
    }
    static func failureCategory(_ message: String) -> String {
        let lower = message.lowercased()
        if lower.contains("其他手机用户") { return "mixed_users" }
        if lower.contains("应用任务在恢复前发生变化") { return "task_changed_before_restore" }
        if lower.contains("应用任务尚未恢复") { return "tasks_not_restored" }
        if lower.contains("原屏幕记录不一致") { return "conflicting_restore_destinations" }
        if lower.contains("任务容器跨越") { return "root_spans_displays" }
        if lower.contains("超时") || lower.contains("timeout") { return "timeout" }
        if lower.contains("中断") || lower.contains("断开") { return "transport" }
        if lower.contains("锁屏") || lower.contains("解锁") { return "locked_or_unconfirmed" }
        if lower.contains("恢复") || lower.contains("清理") { return "recovery" }
        if lower.contains("state changed") || lower.contains("scanner owner") { return "scanner_changed" }
        return "operation_failed"
    }
    static func main() {
        Task { @MainActor in let code = await run(); Darwin.exit(code) }
        if CommandLine.arguments.contains("--show-native-chroma") {
            let app = NSApplication.shared; app.setActivationPolicy(.regular); app.run()
        } else { CFRunLoopRun() }
    }
}
