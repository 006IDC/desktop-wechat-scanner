import Foundation
import Darwin
import AppKit
import CoreImage
import CoreText
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Tags originate only in this test. External error text never reaches the report.
private struct BenchmarkError: Error {
    let tag: String
    init(_ tag: String) { self.tag = tag }
}

private struct NavigationStats {
    var mirrorFramesObserved = 0
    var ocrAttempts = 0
    var homeTabsSeen = false
    var topTitleSeen = false
    var homeConfirmed = false
    var menuConfirmed = false
    var scannerConfirmed = false
    var ownResultSeen = false
    var ownResultBacked = false
    var plusAttempts = 0
    var scannerTapAttempts = 0
    var shellFallbackAttempts = 0
    var steps = [[String: Any]]()
    var knownNavigationBacks = 0

    var report: [String: Any] {
        ["mirrorFramesObserved": mirrorFramesObserved, "ocrAttempts": ocrAttempts,
         "homeTabsSeen": homeTabsSeen, "topTitleSeen": topTitleSeen,
         "homeConfirmed": homeConfirmed, "menuConfirmed": menuConfirmed,
         "scannerConfirmed": scannerConfirmed, "ownResultSeen": ownResultSeen,
         "ownResultBacked": ownResultBacked, "plusAttempts": plusAttempts,
         "scannerTapAttempts": scannerTapAttempts,
         "shellFallbackAttempts": shellFallbackAttempts, "knownNavigationBacks":knownNavigationBacks, "steps": steps]
    }
}

/// Explicit, headless device benchmark. Every camera image is synthetic and stays in memory.
/// Build with all mac/*.swift except mac/main.swift (this file owns @main), then
/// invoke from the repository root with --run-device-test --resources <built app Resources>.
private final class PerformanceMirrorSink: @unchecked Sendable {
    private let lock = NSLock()
    private var frameNumber = 0
    private var latest: CVPixelBuffer?
    private var failed = false

    func receive(_ frame: CVPixelBuffer) {
        lock.withLock { frameNumber += 1; latest = frame }
    }
    func fail() { lock.withLock { failed = true } }
    func snapshot() -> (Int, CVPixelBuffer?, Bool) {
        lock.withLock { (frameNumber, latest, failed) }
    }
}

private enum SyntheticCameraImage {
    static let width = 720, height = 1280
    static let payload = "006IDC20261026PERF"

    static func render(index: Int, png: Bool, qr: Bool = false) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw BenchmarkError("synthetic_context")
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cell = 32
        for y in stride(from: 0, to: height, by: cell) {
            for x in stride(from: 0, to: width, by: cell) where ((x + y) / cell) % 2 == 0 {
                context.setFillColor(CGColor(red: 0.78, green: 0.87, blue: 0.96, alpha: 1))
                context.fill(CGRect(x: x, y: y, width: cell, height: cell))
            }
        }
        let barX = (index * 29) % (width - 24)
        context.setFillColor(CGColor(red: 0.02, green: 0.34, blue: 0.95, alpha: 1))
        context.fill(CGRect(x: barX, y: 0, width: 24, height: height))
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: "006IDC PERFORMANCE \(index % 1000)", attributes: [
                .font: CTFontCreateWithName("Helvetica-Bold" as CFString, 34, nil),
                .foregroundColor: CGColor(gray: 0, alpha: 1)
            ]))
        context.textPosition = CGPoint(x: 36, y: 44)
        CTLineDraw(line, context)
        if qr {
            let filter = CIFilter.qrCodeGenerator()
            filter.message = Data(payload.utf8)
            filter.correctionLevel = "M"
            guard let output = filter.outputImage else { throw BenchmarkError("synthetic_qr_output") }
            guard let code = CIContext().createCGImage(output, from: output.extent) else {
                throw BenchmarkError("synthetic_qr_image")
            }
            let side: CGFloat = 300
            let frame = CGRect(x: (CGFloat(width) - side) / 2,
                               y: (CGFloat(height) - side) / 2, width: side, height: side)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(frame.insetBy(dx: -24, dy: -24))
            context.interpolationQuality = .none
            context.draw(code, in: frame)
        }
        guard let image = context.makeImage() else { throw BenchmarkError("synthetic_image") }
        let output = NSMutableData()
        let kind = png ? UTType.png : UTType.jpeg
        guard let destination = CGImageDestinationCreateWithData(output, kind.identifier as CFString, 1, nil) else {
            throw BenchmarkError("synthetic_encoder")
        }
        let properties: CFDictionary = png ? [:] as CFDictionary :
            [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { throw BenchmarkError("synthetic_encode") }
        return output as Data
    }

    static func verifyQR(_ data: Data) throws {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(data: data).perform([request])
        guard request.results?.contains(where: { $0.payloadStringValue == payload }) == true else {
            throw BenchmarkError("synthetic_qr_unreadable")
        }
    }
}

@main enum WirelessCameraPerformanceTests {
    private static let clock = ProcessInfo.processInfo
    /// Numeric samples shared by the pipeline's one producer and one consumer.
    /// No encoded image survives its normal send/queue lifetime in this box.
    private final class PipelineSegmentSamples: @unchecked Sendable {
        struct Snapshot {
            var requests = [Double](), processing = [Double](), bytes = [Double]()
            var captureEncoding = [Double](), selectedToACK = [Double](), preSendAge = [Double]()
            var ackFailures = 0, staleDropped = 0
        }
        private let lock = NSLock()
        private var index = 0
        private var samples = Snapshot()

        func nextIndex() -> Int {
            lock.withLock { defer { index += 1 }; return index }
        }
        func produced(captureMilliseconds: Double) {
            lock.withLock { samples.captureEncoding.append(captureMilliseconds) }
        }
        func acknowledged(_ frame: CameraEncodedFrame, receipt: CameraFrameReceipt,
                          sendingAt: Double, completedAt: Double) {
            lock.withLock {
                samples.requests.append(receipt.requestMilliseconds)
                if let value = receipt.processingMilliseconds { samples.processing.append(value) }
                samples.bytes.append(Double(frame.data.count))
                samples.selectedToACK.append((completedAt - frame.selectedAt) * 1000)
                samples.preSendAge.append((sendingAt - frame.selectedAt) * 1000)
            }
        }
        func droppedStale() { lock.withLock { samples.staleDropped += 1 } }
        func failedACK() -> Bool {
            lock.withLock { samples.ackFailures += 1; return samples.ackFailures >= 3 }
        }
        var snapshot: Snapshot { lock.withLock { samples } }
    }
    private static func now() -> Double { clock.systemUptime }
    private static func p95(_ samples: [Double]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let ordered = samples.sorted()
        return ordered[max(0, Int(ceil(Double(ordered.count) * 0.95)) - 1)]
    }
    private static func p50(_ samples: [Double]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let ordered = samples.sorted()
        return ordered[max(0, Int(ceil(Double(ordered.count) * 0.50)) - 1)]
    }
    private static func pause(_ seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
    private static func requireFresh(_ sink: PerformanceMirrorSink, after old: Int,
                                     seconds: Double = 8) async throws -> CVPixelBuffer {
        let deadline = now() + seconds
        while now() < deadline {
            let state = sink.snapshot()
            guard !state.2 else { throw BenchmarkError("mirror_failed") }
            if state.0 > old, let image = state.1 { return image }
            try await pause(0.08)
        }
        throw BenchmarkError("mirror_timeout")
    }
    private static func words(_ image: CVPixelBuffer,
                              region: ScannerNavigationOCR.Region) throws -> [ScannerNavigationOCR.Text] {
        try ScannerNavigationOCR.recognize(image, region: region)
    }
    private static func clean(_ value: String) -> String {
        value.replacingOccurrences(of: " ", with: "")
    }
    private static func hasOwnResult(_ words: [ScannerNavigationOCR.Text]) -> Bool {
        words.contains { clean($0.value).contains(SyntheticCameraImage.payload) }
    }

    /// The only navigation coordinates come from confirmed WeChat home/menu labels.
    /// Never tap a result, a conversation, an authorization dialog, or an unknown page.
    private static func openScanner(phone: PhoneSession, mirror: MirrorSession,
                                    sink: PerformanceMirrorSink,
                                    stats: inout NavigationStats) async throws -> Bool {
        // Return only from known, non-transactional WeChat navigation pages.
        // No conversation content is read or clicked to do this.
        let backPages:Set<String>=["com.tencent.mm/.chatroom.ui.ChatroomInfoUI",
                                   "com.tencent.mm/.ui.chatting.ChattingUI"]
        for _ in 0..<2 {
            guard let activity=try await phone.foreground(onVirtualDisplay:true),backPages.contains(activity) else{break}
            mirror.key(4);stats.knownNavigationBacks+=1
            try await pause(0.4)
        }
        if let activity = try await phone.foreground(onVirtualDisplay: true),
           activity.hasPrefix("com.tencent.mm/"), activity.lowercased().contains("scanner") {
            stats.scannerConfirmed = true
            return true
        }
        let deadline = now() + 12
        var lastFrame = -1, menuAttempts = 0, lastMenuTap = 0.0, scannerTapped = false
        var ownResultBacked = false, toolbarSaved = false
        while now() < deadline {
            let state = sink.snapshot()
            guard !state.2 else { throw BenchmarkError("mirror_failed") }
            stats.mirrorFramesObserved = state.0
            let retry = menuAttempts > 0 && !scannerTapped && menuAttempts < 3 && now() - lastMenuTap > 0.7
            if state.0 == lastFrame && !retry { try await pause(0.10); continue }
            guard let image = state.1 else { try await pause(0.10); continue }
            lastFrame = state.0
            let region: ScannerNavigationOCR.Region = scannerTapped ? .scanner :
                (menuAttempts > 0 && !retry ? .menu : .full)
            let recognized = try words(image, region: region)
            stats.ocrAttempts += 1
            if !ownResultBacked && hasOwnResult(recognized) {
                stats.ownResultSeen = true
                mirror.key(4)
                ownResultBacked = true
                stats.ownResultBacked = true
                try await pause(0.35)
                continue
            }
            let labels = recognized.map { (clean($0.value), $0.rect) }
            let allowlist:Set<String>=["微信","通讯录","发现","我","扫一扫","发起群聊","添加朋友"]
            if stats.steps.count<20 {
                stats.steps.append(["frame":state.0,"region":region.rawValue,
                    "labels":recognized.filter{allowlist.contains(clean($0.value))}.map{
                        ["label":clean($0.value),"x":Int($0.rect.midX),"y":Int($0.rect.midY)] as [String:Any]
                    }])
            }
            if labels.contains(where: { $0.0.contains("扫一扫") && $0.1.midY > 950 }) {
                stats.scannerConfirmed = true
                return true
            }
            if !scannerTapped,
               let scan = labels.first(where: { $0.0.contains("扫一扫") && $0.1.midY < 950 }),
               labels.contains(where: { $0.0.contains("发起群聊") || $0.0.contains("添加朋友") }) {
                guard try await phone.foreground(onVirtualDisplay:true)=="com.tencent.mm/.ui.LauncherUI" else {
                    throw BenchmarkError("navigation_page_changed")
                }
                stats.menuConfirmed = true
                mirror.tap(x: Double(scan.1.midX / 720), y: Double(scan.1.midY / 1280))
                scannerTapped = true
                stats.scannerTapAttempts += 1
                continue
            }
            let home = labels.contains(where: { $0.0.contains("通讯录") && $0.1.midY > 1000 }) &&
                labels.contains(where: { $0.0.contains("发现") && $0.1.midY > 1000 })
            stats.homeTabsSeen = stats.homeTabsSeen || home
            let title = labels.filter({ $0.0 == "微信" && $0.1.midY < 170 &&
                (300...420).contains($0.1.midX) }).min(by: { $0.1.minY < $1.1.minY })
            stats.topTitleSeen = stats.topTitleSeen || title != nil
            stats.homeConfirmed = stats.homeConfirmed || (home && title != nil)
            if !scannerTapped && (menuAttempts == 0 || retry) && home,title != nil,
               let plus=try ScannerNavigationOCR.plusButton(in:image,homeWords:recognized) {
                guard try await phone.foreground(onVirtualDisplay:true)=="com.tencent.mm/.ui.LauncherUI" else {
                    throw BenchmarkError("navigation_page_changed")
                }
                if !toolbarSaved,CommandLine.arguments.contains("--diagnostic-toolbar") {
                    toolbarSaved=true
                    let source=CIImage(cvPixelBuffer:image)
                    let crop=CGRect(x:0,y:source.extent.height*0.89,width:source.extent.width,height:source.extent.height*0.11)
                    if let cg=CIContext().createCGImage(source,from:crop),
                       let data=NSBitmapImageRep(cgImage:cg).representation(using:.png,properties:[:]) {
                        try data.write(to:URL(fileURLWithPath:".local/headless-toolbar.png"),options:.atomic)
                    }
                }
                if menuAttempts == 2 {
                    try await phone.tap(x: Int(plus.x), y: Int(plus.y))
                    stats.shellFallbackAttempts += 1
                } else {
                    mirror.tap(x: Double(plus.x / 720), y: Double(plus.y / 1280))
                }
                menuAttempts += 1
                stats.plusAttempts += 1
                lastMenuTap = now()
            }
            try await pause(0.10)
        }
        return false
    }

    private static func measure(images: [Data], phone: PhoneSession,
                                mirror: MirrorSession) async throws -> [String: Double] {
        let initial = mirror.timingSnapshot
        let began = now()
        var requests = [Double](), processing = [Double](), bytes = [Double]()
        var failures = 0
        var frameIndex = 0
        while now() - began < 6 {
            let tick = now()
            let image = images[frameIndex % images.count]
            frameIndex += 1
            do {
                // The server's camera generation starts at zero and changes only on clear().
                let receipt = try await phone.frame(image, epoch: 0)
                requests.append(receipt.requestMilliseconds)
                if let duration = receipt.processingMilliseconds { processing.append(duration) }
                bytes.append(Double(image.count))
            } catch {
                failures += 1
                if failures >= 3 { throw BenchmarkError("camera_ack_failed") }
            }
            let rest = 1.0 / 30.0 - (now() - tick)
            if rest > 0 { try await pause(rest) }
        }
        let duration = now() - began
        guard !requests.isEmpty, !processing.isEmpty else { throw BenchmarkError("camera_no_processing") }
        let final = mirror.timingSnapshot
        let mirrorBytes = final.receivedBytes >= initial.receivedBytes ?
            final.receivedBytes - initial.receivedBytes : 0
        return ["fps": Double(requests.count) / duration,
                "frames": Double(requests.count), "ackFailures": Double(failures),
                "ackP95Milliseconds": p95(requests), "ackMaxMilliseconds": requests.max() ?? 0,
                "phoneProcessingP95Milliseconds": p95(processing),
                "phoneProcessingSamples": Double(processing.count),
                "imageBytesP95": p95(bytes),
                "mirrorPackets": Double(final.videoPacketCount >= initial.videoPacketCount ?
                    final.videoPacketCount - initial.videoPacketCount : 0),
                "mirrorFrames": Double(final.decodedFrameCount >= initial.decodedFrameCount ?
                    final.decodedFrameCount - initial.decodedFrameCount : 0),
                "mirrorBytes": Double(mirrorBytes),
                "mirrorBytesPerSecond": Double(mirrorBytes) / duration,
                "mirrorDecodeRollingWindowP95Milliseconds": final.decodeP95Milliseconds ?? 0,
                "mirrorRelativeBacklogRollingWindowP95Milliseconds": final.relativeBacklogP95Milliseconds ?? 0,
                "mirrorTimingWindowSamples": Double(final.relativeBacklogSampleCount)]
    }

    /// Unlike the format-only benchmark, generate and JPEG-encode each frame
    /// after selectedAt. Both modes use the same fixture and 30 Hz producer budget.
    private static func measurePipeline(usePipeline: Bool, phone: PhoneSession,
                                        mirror: MirrorSession) async throws -> [String: Double] {
        let initial = mirror.timingSnapshot
        let samples = PipelineSegmentSamples()
        let began = now(), deadline = began + 6
        let pipeline = CameraFramePipeline()

        let produce: @Sendable () async throws -> CameraEncodedFrame? = {
            try Task.checkCancellation()
            let selectedAt = now()
            guard selectedAt < deadline else { return nil }
            let image = try SyntheticCameraImage.render(index: samples.nextIndex(), png: false)
            let captureMilliseconds = (now() - selectedAt) * 1000
            samples.produced(captureMilliseconds: captureMilliseconds)
            return CameraEncodedFrame(data: image, selectedAt: selectedAt,
                                      captureMilliseconds: captureMilliseconds)
        }
        let consume: @Sendable (CameraEncodedFrame, Int) async throws -> Void = { frame, _ in
            try Task.checkCancellation()
            let sendingAt = now()
            // No new request starts after the common six-second segment window.
            // An already active request may finish after it, in either mode.
            guard sendingAt < deadline else { return }
            guard sendingAt - frame.selectedAt <= 0.5 else {
                samples.droppedStale(); return
            }
            do {
                let receipt = try await phone.frame(frame.data, epoch: 0, selectedAt: frame.selectedAt)
                samples.acknowledged(frame, receipt: receipt, sendingAt: sendingAt, completedAt: now())
            } catch is CameraFrameExpiredError {
                // PhoneSession checks freshness again when its actor owns the socket.
                samples.droppedStale()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if samples.failedACK() { throw BenchmarkError("camera_ack_failed") }
            }
        }

        var pipelineMetrics = CameraFramePipeline.Metrics()
        if usePipeline {
            // run() owns one 30 Hz producer, newest-only buffering and one sender;
            // it joins the producer before returning, including errors/cancellation.
            pipelineMetrics = try await pipeline.run(produce: produce, consume: consume)
        } else {
            while now() < deadline {
                let tick = now()
                guard let frame = try await produce() else { break }
                try await consume(frame, 0)
                let remaining = 1.0 / 30.0 - (now() - tick)
                if remaining > 0 { try await pause(remaining) }
            }
        }
        let duration = now() - began
        let values = samples.snapshot
        guard !values.requests.isEmpty, !values.processing.isEmpty else {
            throw BenchmarkError("camera_no_processing")
        }
        let final = mirror.timingSnapshot
        let mirrorBytes = final.receivedBytes >= initial.receivedBytes ?
            final.receivedBytes - initial.receivedBytes : 0
        return ["pipelineEnabled": usePipeline ? 1 : 0,
                "measurementWindowSeconds": 6, "durationSeconds": duration,
                "fps": Double(values.requests.count) / duration,
                "frames": Double(values.requests.count), "ackFailures": Double(values.ackFailures),
                "ackP95Milliseconds": p95(values.requests),
                "ackMaxMilliseconds": values.requests.max() ?? 0,
                "captureEncodingP95Milliseconds": p95(values.captureEncoding),
                "captureEncodingSamples": Double(values.captureEncoding.count),
                "selectedAtToACKP95Milliseconds": p95(values.selectedToACK),
                "preSendAgeP95Milliseconds": p95(values.preSendAge),
                "queueOverwrites": Double(pipelineMetrics.queueOverwrites),
                "staleDropped": Double(pipelineMetrics.staleDropped + values.staleDropped),
                "phoneProcessingP95Milliseconds": p95(values.processing),
                "phoneProcessingSamples": Double(values.processing.count),
                "imageBytesP95": p95(values.bytes),
                "mirrorPackets": Double(final.videoPacketCount >= initial.videoPacketCount ?
                    final.videoPacketCount - initial.videoPacketCount : 0),
                "mirrorFrames": Double(final.decodedFrameCount >= initial.decodedFrameCount ?
                    final.decodedFrameCount - initial.decodedFrameCount : 0),
                "mirrorBytes": Double(mirrorBytes),
                "mirrorBytesPerSecond": Double(mirrorBytes) / duration,
                "mirrorDecodeRollingWindowP95Milliseconds": final.decodeP95Milliseconds ?? 0,
                "mirrorRelativeBacklogRollingWindowP95Milliseconds": final.relativeBacklogP95Milliseconds ?? 0,
                "mirrorTimingWindowSamples": Double(final.relativeBacklogSampleCount)]
    }

    private static func verifyPhoneResult(phone: PhoneSession, mirror: MirrorSession,
                                          sink: PerformanceMirrorSink) async throws -> Bool {
        let qr = try SyntheticCameraImage.render(index: 0, png: false, qr: true)
        try SyntheticCameraImage.verifyQR(qr)
        let deadline = now() + 12
        var lastSeen = -1
        while now() < deadline {
            _ = try await phone.frame(qr, epoch: 0)
            let state = sink.snapshot()
            if state.0 != lastSeen, let frame = state.1 {
                lastSeen = state.0
                if hasOwnResult(try words(frame, region: .full)) {
                    mirror.key(4) // Dismiss only the exact result of this test.
                    return true
                }
            }
            try await pause(0.12)
        }
        return false
    }

    private static func selftest() throws -> [String: Any] {
        var result: [String: Any] = ["selftest": true, "width": SyntheticCameraImage.width,
                                     "height": SyntheticCameraImage.height]
        for png in [false, true] {
            let data = try SyntheticCameraImage.render(index: 23, png: png, qr: true)
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  image.width == 720, image.height == 1280,
                  let type = CGImageSourceGetType(source),
                  (type as String) == (png ? UTType.png.identifier : UTType.jpeg.identifier) else {
                throw BenchmarkError("selftest_format")
            }
            try SyntheticCameraImage.verifyQR(data)
            result[png ? "pngValid" : "jpegValid"] = true
            result[png ? "pngBytes" : "jpegBytes"] = data.count
        }
        result["qrValid"] = true
        return result
    }

    static func main() async {
        if CommandLine.arguments.contains("--selftest") {
            let report: [String: Any]
            do { report = try selftest() }
            catch { report = ["selftest": false,
                              "failureTag": (error as? BenchmarkError)?.tag ?? "selftest_external_error"] }
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
               let output = String(data: data, encoding: .utf8) { print(output) }
            if report["selftest"] as? Bool != true { Darwin.exit(1) }
            return
        }
        var result: [String: Any] = ["ok": false, "failureCode": 0, "qrMatched": false]
        let mirror = MirrorSession(), sink = PerformanceMirrorSink()
        var phone: PhoneSession?, server: ADBManagedServer?, manager: ADBConnectionManager?
        var endpoint: String?, display: Int?
        var jpegImages = [Data](), pngImages = [Data]()
        let comparePipeline = CommandLine.arguments.contains("--compare-pipeline")
        var navigation = NavigationStats()
        var phase = 0
        do {
            guard CommandLine.arguments.contains("--run-device-test"),
                  let index = CommandLine.arguments.firstIndex(of: "--resources"),
                  CommandLine.arguments.indices.contains(index + 1) else { throw BenchmarkError("arguments") }
            let resources = URL(fileURLWithPath: CommandLine.arguments[index + 1]).standardizedFileURL
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("006IDC/DesktopWeChatScanner")
            guard !FileManager.default.fileExists(atPath: support.appendingPathComponent("session.json").path) else {
                throw BenchmarkError("existing_session")
            }
            if let status = try? Data(contentsOf: support.appendingPathComponent("diagnostic-state.json")),
               let object = try? JSONSerialization.jsonObject(with: status) as? [String: Any],
               object["connected"] as? Bool == true { throw BenchmarkError("app_connected") }
            let defaults = UserDefaults(suiteName: "com.idc006.DesktopWeChatScanner") ?? .standard
            guard defaults.bool(forKey: "allowsLockedApplications.v1"),
                  let saved = WirelessReconnectStore(defaults: defaults).load() else {
                throw BenchmarkError("wireless_preference")
            }
            let adb = try await ADBConfiguration.validateAsync(resources.appendingPathComponent("adb/bin/adb"))
            guard FileManager.default.fileExists(atPath: resources.appendingPathComponent("camera-probe.jar").path) else {
                throw BenchmarkError("missing_resources")
            }
            if !comparePipeline {
                // Default format-only mode retains its identical preencoded sequences.
                jpegImages = try (0..<60).map { try SyntheticCameraImage.render(index: $0, png: false) }
                pngImages = try (0..<60).map { try SyntheticCameraImage.render(index: $0, png: true) }
            }
            result["comparison"] = comparePipeline ? "serial_pipeline_pipeline_serial" : "jpeg_png_png_jpeg"
            if comparePipeline {
                result["encoding"] = "JPEG .88; 720x1280; rendered and encoded per produced frame"
                result["preSendAgeDefinition"] = "selectedAt before render to immediately before awaiting PhoneSession.frame; actor enforces 500ms again"
            }
            phase = 1
            server = try await ADBManagedServer.start(adbURL: adb)
            guard let server else { throw BenchmarkError("server") }
            manager = ADBConnectionManager(adbURL: adb, serverSocket: server.socket)
            endpoint = saved.endpoint
            try await manager?.connect(endpoint: saved.endpoint)
            let devices = try await manager?.devices() ?? []
            guard devices.contains(where: { $0.serial == saved.endpoint && $0.authorization == .authorized &&
                $0.transport == .wireless }) else { throw BenchmarkError("wireless_unavailable") }
            // Refuse a session that appeared during transport setup; PhoneSession.connect
            // would otherwise treat it as a recovery journal and clean it.
            guard !FileManager.default.fileExists(atPath: support.appendingPathComponent("session.json").path) else {
                throw BenchmarkError("session_race")
            }
            phase = 2
            let session = PhoneSession(resources: resources, adbURL: adb, serverSocket: server.socket)
            phone = session
            _ = try await session.connect(openWechatOnConnect: false, selectedSerial: saved.endpoint,
                                          allowLockedApplications: true, progress: { _ in })
            guard await session.independentApplicationsWhenLocked,
                  let scanner = await session.scannerDisplay(), scanner.independentLock == true else {
                throw BenchmarkError("independent_display")
            }
            display = scanner.id
            let apps = try await session.applications()
            guard let wechat = apps.first(where: { $0.packageName == "com.tencent.mm" }) else {
                throw BenchmarkError("wechat_unavailable")
            }
            try await session.launchApplication(wechat, on: scanner.id)
            let route = try await session.mirrorEndpoint(display: scanner.id)
            guard let direct = try await session.directMirror(display: scanner.id) else {
                throw BenchmarkError("direct_unavailable")
            }
            try await mirror.startVideo(adbURL: adb,
                                        serverURL: resources.appendingPathComponent("scrcpy-server"),
                                        serial: route.serial, displayID: scanner.id,
                                        serverSocket: server.socket, direct: direct,
                                        onFrame: { sink.receive($0) }, onFailure: { _ in sink.fail() })
            _ = try await requireFresh(sink, after: 0)
            phase = 3
            guard try await openScanner(phone: session, mirror: mirror, sink: sink, stats: &navigation) else {
                if let component=try? await session.foreground(onVirtualDisplay:true),component.hasPrefix("com.tencent.mm/") {
                    result["navigationActivity"]=component
                }
                throw BenchmarkError("scanner_navigation")
            }
            phase = 4
            var heartbeats = [Double]()
            for _ in 0..<10 {
                let started = now()
                try await session.heartbeat()
                heartbeats.append((now() - started) * 1000)
                try await pause(0.03)
            }
            result["heartbeatP50Milliseconds"] = p50(heartbeats)
            result["heartbeatP95Milliseconds"] = p95(heartbeats)
            var segments = [[String: Double]]()
            for (index, secondMode) in [false, true, true, false].enumerated() {
                phase = 5 + index
                if comparePipeline {
                    segments.append(try await measurePipeline(usePipeline: secondMode,
                                                               phone: session, mirror: mirror))
                } else {
                    segments.append(try await measure(images: secondMode ? pngImages : jpegImages,
                                                      phone: session, mirror: mirror))
                }
                result["segments"] = segments
                guard !sink.snapshot().2 else { throw BenchmarkError("mirror_failed") }
            }
            phase = 9
            let matched = try await verifyPhoneResult(phone: session, mirror: mirror,
                                                      sink: sink)
            result["qrMatched"] = matched
            result["ok"] = matched
            if !matched { result["failureCode"] = 10; result["failureTag"] = "qr_not_matched" }
        } catch {
            result["failureCode"] = phase + 1
            result["failureTag"] = (error as? BenchmarkError)?.tag ?? "external_error"
        }
        result["phaseCode"] = phase
        result["navigation"] = navigation.report
        result["mirrorFramesTotal"] = sink.snapshot().0
        // Close in ownership order, even after a partial startup failure.
        await mirror.stop()
        if let phone, let display { try? await phone.stopDirectMirror(display: display) }
        let phoneCleanup = await phone?.disconnect() ?? ""
        var wirelessDisconnectAttempted = false, wirelessDisconnectOK = false
        if let endpoint, let manager {
            wirelessDisconnectAttempted = true
            do { try await manager.disconnect(endpoint: endpoint); wirelessDisconnectOK = true }
            catch { wirelessDisconnectOK = false }
        }
        await server?.stop()
        result["phoneCleanupAttempted"] = phone != nil
        result["phoneCleanupOK"] = phoneCleanup.isEmpty
        result["wirelessDisconnectAttempted"] = wirelessDisconnectAttempted
        result["wirelessDisconnectOK"] = wirelessDisconnectOK
        if !phoneCleanup.isEmpty {
            result["ok"] = false; result["failureCode"] = 11; result["failureTag"] = "phone_cleanup_failed"
        } else if wirelessDisconnectAttempted && !wirelessDisconnectOK {
            result["ok"] = false; result["failureCode"] = 12; result["failureTag"] = "wireless_disconnect_failed"
        }
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) { print(text) }
        if result["ok"] as? Bool != true { Darwin.exit(1) }
    }
}
