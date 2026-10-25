import AppKit
import CoreVideo
import Foundation
import ImageIO
import Vision
import UniformTypeIdentifiers

// Synthetic-only end-to-end test. Nothing from the phone or desktop is saved.
private enum Barcode {
    static let width = 368, height = 800, count = 120
    // 8-bit guard, sequence, its complement, and a 2-bit stop: 26 cells.
    static func bits(_ sequence: Int) -> [Bool] {
        let guardBits = [true, false, true, true, false, true, false, false]
        let payload = (0..<8).reversed().map { sequence & (1 << $0) != 0 }
        return guardBits + payload + payload.map(!) + [false, true]
    }
    static func jpeg(_ sequence: Int) throws -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 255, count: bytesPerRow * height)
        var outputData: Data?
        let made = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                          space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setFillColor(NSColor.black.cgColor)
            let left = CGFloat(width) * 0.2, total = CGFloat(width) * 0.6
            let cell = total / CGFloat(bits(sequence).count)
            for (index, black) in bits(sequence).enumerated() where black {
                let first = Int((left + CGFloat(index) * cell).rounded())
                let last = Int((left + CGFloat(index + 1) * cell).rounded())
                context.fill(CGRect(x: CGFloat(first), y: CGFloat(height) * 0.6,
                                    width: CGFloat(max(1, last - first)), height: CGFloat(height) * 0.15))
            }
            guard let image = context.makeImage() else { return false }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
            CGImageDestinationAddImage(destination, image,
                                      [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return false }
            outputData = output as Data
            return true
        }
        guard made, let outputData else { throw ScanError("Synthetic barcode JPEG creation failed") }
        return outputData
    }

    struct Geometry {
        let width: Int, height: Int, x: Int, cell: Double, rows: (Int, Int)
    }
    enum Match { case id(Int), none, ambiguous }
    private static let guardBits = [true, false, true, true, false, true, false, false]
    // Exact 26-bit verification includes the 8-bit complement. Middle-gray
    // pixels are rejected instead of being guessed as black or white.
    private static func read(_ gray: [UInt8], width: Int, x: Int, y: Int, cell: Double) -> Int? {
        var bits = [Bool]()
        bits.reserveCapacity(26)
        for index in 0..<26 {
            let xx = x + Int((Double(index) + 0.5) * cell)
            guard xx >= 0, xx < width else { return nil }
            let value = gray[y * width + xx]
            guard value <= 100 || value >= 160 else { return nil }
            bits.append(value <= 100)
        }
        guard Array(bits.prefix(8)) == guardBits,
              bits[24] == false, bits[25] == true else { return nil }
        var id = 0
        for index in 0..<8 {
            guard bits[8 + index] != bits[16 + index] else { return nil }
            id = (id << 1) | (bits[8 + index] ? 1 : 0)
        }
        return id
    }
    // First match calibrates x/cell/rows. Subsequent frames use only that
    // geometry, so a costly wide search cannot manufacture late matches.
    static func decode(_ image: CVPixelBuffer, eligible: Set<Int>, geometry: inout Geometry?) -> Match {
        guard !eligible.isEmpty else { return .none }
        guard CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_32BGRA else { return .none }
        let sourceWidth = CVPixelBufferGetWidth(image), sourceHeight = CVPixelBufferGetHeight(image)
        let scale = min(1.0, 600.0 / Double(sourceWidth))
        let w = Int(Double(sourceWidth) * scale), h = Int(Double(sourceHeight) * scale)
        guard w > 120, h > 200 else { return .none }
        var gray = [UInt8](repeating: 255, count: w * h)
        guard CVPixelBufferLockBaseAddress(image, .readOnly) == kCVReturnSuccess else { return .none }
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(image)?.assumingMemoryBound(to: UInt8.self) else { return .none }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(image)
        for y in 0..<h {
            let sourceY = min(sourceHeight-1, Int((Double(y)+0.5)/scale))
            let row = base.advanced(by: sourceY*bytesPerRow)
            for x in 0..<w {
                let sourceX = min(sourceWidth-1, Int((Double(x)+0.5)/scale))
                let pixel = row.advanced(by: sourceX*4)
                gray[y*w+x] = UInt8((29*Int(pixel[0]) + 150*Int(pixel[1]) + 77*Int(pixel[2])) >> 8)
            }
        }
        if let fixed = geometry {
            guard fixed.width == w, fixed.height == h else { geometry = nil; return .none }
            var matches = Set<Int>()
            for dx in -2...2 {
                for dc in -1...1 {
                    let cell = fixed.cell + Double(dc) * 0.25
                    for dy in -2...2 {
                        let firstY = fixed.rows.0 + dy, secondY = fixed.rows.1 + dy
                        guard firstY >= 0, secondY < h else { continue }
                        let first = read(gray, width: w, x: fixed.x + dx, y: firstY, cell: cell)
                        let second = read(gray, width: w, x: fixed.x + dx, y: secondY, cell: cell)
                        if let first, first == second, eligible.contains(first) { matches.insert(first) }
                    }
                }
            }
            guard matches.count <= 1 else { return .ambiguous }
            guard let id = matches.first else { return .none }
            return .id(id)
        }
        let lowY = Int(Double(h) * 0.16), highY = Int(Double(h) * 0.76)
        let rowStep = max(5, h / 90)
        let minCell = max(3.0, Double(w) * 0.20 / 26)
        let maxCell = min(24.0, Double(w) * 0.72 / 26)
        var previousRows: [Int: [(x: Int, cell: Double, y: Int)]] = [:]
        var matches: [(Int, Geometry)] = []
        for y in stride(from: lowY, through: highY, by: rowStep) {
            var thisRow: [Int: [(x: Int, cell: Double, y: Int)]] = [:]
            for quarter in Int((minCell * 4).rounded(.up))...Int((maxCell * 4).rounded(.down)) {
                let cell = Double(quarter) / 4
                let minX = Int(Double(w) * 0.08)
                let maxX = min(Int(Double(w) * 0.5), Int(Double(w) * 0.94 - 26 * cell))
                guard maxX >= minX else { continue }
                for x in stride(from: minX, through: maxX, by: 2) {
                    guard let id = read(gray, width: w, x: x, y: y, cell: cell),
                          eligible.contains(id) else { continue }
                    if let previous = previousRows[id]?.first(where: {
                        y - $0.y <= rowStep * 2 && abs($0.x - x) <= 2 && abs($0.cell - cell) <= 0.25
                    }) {
                        matches.append((id, Geometry(width: w, height: h, x: x,
                                                     cell: cell, rows: (previous.y, y))))
                    }
                    thisRow[id, default: []].append((x, cell, y))
                }
            }
            previousRows = thisRow
        }
        let ids = Set(matches.map { $0.0 })
        guard ids.count <= 1 else { return .ambiguous }
        guard let match = matches.first else { return .none }
        geometry = match.1
        return .id(match.0)
    }
}

private final class LatencySink: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.idc006.latency.decode", qos: .userInitiated)
    private var pending = false, frames = 0, skippedBusy = 0, unmatched = 0, ambiguous = 0, calibrations = 0, failure: String?
    private var latest: CVPixelBuffer?
    private var starts: [Int: TimeInterval] = [:]
    private var arrivals: [Int: Double] = [:]
    private var parseDurations: [Double] = []
    private var geometry: Barcode.Geometry?
    func sent(_ id: Int, at time: TimeInterval) { lock.withLock { starts[id] = time } }
    func frame(_ image: CVPixelBuffer) {
        let received = ProcessInfo.processInfo.systemUptime
        let eligible: Set<Int>? = lock.withLock {
            frames += 1; latest = image
            guard !pending else { skippedBusy += 1; return nil }
            pending = true
            return Set(starts.keys.filter { arrivals[$0] == nil })
        }
        guard let eligible else { return }
        guard !eligible.isEmpty else { lock.withLock { pending = false }; return }
        queue.async {
            let began = ProcessInfo.processInfo.systemUptime
            let wasCalibrated = self.geometry != nil
            let result = Barcode.decode(image, eligible: eligible, geometry: &self.geometry)
            let milliseconds = (ProcessInfo.processInfo.systemUptime - began) * 1000
            self.lock.withLock {
                self.parseDurations.append(milliseconds)
                if !wasCalibrated && self.geometry != nil { self.calibrations += 1 }
                switch result {
                case .id(let id):
                    if let start = self.starts[id], received >= start,
                       self.arrivals[id] == nil { self.arrivals[id] = (received - start) * 1000 }
                case .none: self.unmatched += 1
                case .ambiguous: self.ambiguous += 1
                }
                self.pending = false
            }
        }
    }
    func failed(_ value: String) { lock.withLock { failure = value } }
    func finishParsing() { queue.sync {} }
    func snapshot() -> (frames: Int, failure: String?, latest: CVPixelBuffer?, arrivals: [Int: Double], parse: [Double], skippedBusy: Int, unmatched: Int, ambiguous: Int, calibrations: Int) {
        lock.withLock { (frames, failure, latest, arrivals, parseDurations, skippedBusy, unmatched, ambiguous, calibrations) }
    }
}

@main struct RawCameraLatencyIntegration {
    private static func words(_ image: CVPixelBuffer) throws -> [(String, CGRect)] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        try VNImageRequestHandler(cvPixelBuffer: image).perform([request])
        return (request.results ?? []).compactMap { item in
            guard let value = item.topCandidates(1).first?.string else { return nil }
            let r = item.boundingBox
            return (value, CGRect(x: r.minX, y: 1-r.maxY, width: r.width, height: r.height))
        }
    }
    private static func words(_ jpeg: Data) throws -> [(String, CGRect)] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        try VNImageRequestHandler(data: jpeg).perform([request])
        return (request.results ?? []).compactMap { item in
            guard let value = item.topCandidates(1).first?.string else { return nil }
            let r = item.boundingBox
            return (value, CGRect(x: r.minX, y: 1-r.maxY, width: r.width, height: r.height))
        }
    }
    private static func verifySyntheticQR(_ data: Data) throws {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(data: data).perform([request])
        guard request.results?.contains(where: { $0.payloadStringValue == "006IDC20261025C3" }) == true else {
            throw ScanError("Synthetic C3 fixture is not the expected QR")
        }
    }
    private static func pixelBuffer(_ image: CGImage) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferCGImageCompatibilityKey: true,
                          kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, image.width, image.height,
                                  kCVPixelFormatType_32BGRA, attributes, &buffer) == kCVReturnSuccess,
              let buffer else { throw ScanError("Cannot allocate synthetic BGRA buffer") }
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else {
            throw ScanError("Cannot lock synthetic BGRA buffer")
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: image.width,
                                      height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue |
                                          CGImageAlphaInfo.premultipliedFirst.rawValue) else {
            throw ScanError("Cannot draw synthetic BGRA buffer")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return buffer
    }
    private static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        sorted[min(sorted.count-1, Int(ceil(p * Double(sorted.count)))-1)]
    }
    private static func stats(_ label: String, _ values: [Double]) {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { print(label, "samples=0"); return }
        print(String(format: "%@ samples=%d p50_ms=%.3f p95_ms=%.3f max_ms=%.3f",
                     label, sorted.count, percentile(sorted, 0.5), percentile(sorted, 0.95), sorted.last!))
    }
    static func main() async {
        if CommandLine.arguments.dropFirst().first == "--self-test" {
            do {
                for id in [1, 37, Barcode.count] {
                    let jpeg = try Barcode.jpeg(id)
                    var geometry: Barcode.Geometry?
                    guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
                          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                          case .id(id) = Barcode.decode(try pixelBuffer(image), eligible: [id], geometry: &geometry),
                          case .id(id) = Barcode.decode(try pixelBuffer(image), eligible: [id], geometry: &geometry) else {
                        throw ScanError("Synthetic barcode round trip failed for frame \(id)")
                    }
                    // Simulate a smaller preview embedded in a taller phone mirror.
                    let preview = CGContext(data: nil, width: 600, height: 1200,
                                            bitsPerComponent: 8, bytesPerRow: 600 * 4,
                                            space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                    preview?.setFillColor(NSColor.white.cgColor)
                    preview?.fill(CGRect(x: 0, y: 0, width: 600, height: 1200))
                    preview?.draw(image, in: CGRect(x: 90, y: 120, width: 420, height: 900))
                    var scaledGeometry: Barcode.Geometry?
                    guard let composed = preview?.makeImage(),
                          case .id(id) = Barcode.decode(try pixelBuffer(composed), eligible: [id], geometry: &scaledGeometry),
                          case .id(id) = Barcode.decode(try pixelBuffer(composed), eligible: [id], geometry: &scaledGeometry) else {
                        throw ScanError("Embedded preview barcode failed for frame \(id)")
                    }
                }
                print("PASS synthetic barcode JPEG/BGRA sampling")
            } catch { print("FAILED", error.localizedDescription); exit(1) }
            return
        }
        guard (2...4).contains(CommandLine.arguments.count) else {
            print("Usage: RawCameraLatencyIntegration RESOURCES [C3_JPEG_OR_PNG] [TARGET_FPS_1_TO_60]"); exit(2)
        }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        let source = CommandLine.arguments.count > 2 ? URL(fileURLWithPath: CommandLine.arguments[2]) : root.appendingPathComponent(".local/app-scan-test.png")
        let targetFPS = CommandLine.arguments.count > 3 ? Int(CommandLine.arguments[3]) : 30
        guard let targetFPS, (1...60).contains(targetFPS) else {
            print("TARGET_FPS must be 1...60"); exit(2)
        }
        let phone = PhoneSession(resources: resources), mirror = MirrorSession(), sink = LatencySink()
        var moved = false
        do {
            let qr = try Data(contentsOf: source)
            try verifySyntheticQR(qr)
            _ = try await phone.connect(openWechatOnConnect: false) { _ in }
            let endpoint = try await phone.mirrorEndpoint()
            let server = root.appendingPathComponent(".tools/scrcpy/scrcpy-server-v5.0.1")
            try await phone.openWechat(onVirtualDisplay: false)
            try await mirror.startVideo(adbURL: resources.appendingPathComponent("adb"), serverURL: server,
                                   serial: endpoint.serial, displayID: 0,
                                   onFrame: { sink.frame($0) }, onFailure: { sink.failed($0) })
            try await Task.sleep(nanoseconds: 900_000_000)
            guard let homeImage = sink.snapshot().latest else { throw ScanError("Physical WeChat mirror not ready") }
            let home = try words(homeImage)
            guard home.contains(where: { $0.0.contains("通讯录") && $0.1.midY > 0.75 }),
                  home.filter({ $0.0.hasPrefix("微信") && $0.1.midY < 0.2 }).count == 1 else {
                throw ScanError("Expected single physical WeChat header; no tap")
            }
            guard let title = home.first(where: { $0.0.hasPrefix("微信") && $0.1.midY < 0.2 }) else { throw ScanError("No WeChat header") }
            mirror.tap(x: 0.92, y: title.1.midY)
            try await Task.sleep(nanoseconds: 800_000_000)
            guard let menuImage = sink.snapshot().latest else { throw ScanError("WeChat menu not ready") }
            let menu = try words(menuImage)
            guard menu.contains(where: { $0.0.contains("添加朋友") }),
                  let scan = menu.first(where: { $0.0.contains("扫一扫") }) else {
                throw ScanError("Expected WeChat scan menu; no tap")
            }
            mirror.tap(x: scan.1.midX, y: scan.1.midY)
            try await Task.sleep(nanoseconds: 800_000_000)
            guard try await phone.foreground(onVirtualDisplay: false)?.lowercased().contains("scanner") == true else {
                throw ScanError("Scanner not foreground on physical display")
            }
            try await phone.moveWechat(toVirtualDisplay: true); moved = true
            await mirror.stop()
            try await mirror.startVideo(adbURL: resources.appendingPathComponent("adb"), serverURL: server,
                                   serial: endpoint.serial, displayID: endpoint.display,
                                   onFrame: { sink.frame($0) }, onFailure: { sink.failed($0) })
            try await Task.sleep(nanoseconds: 800_000_000)
            guard try await phone.foreground(onVirtualDisplay: true)?.lowercased().contains("scanner") == true else {
                throw ScanError("Scanner not foreground on virtual display")
            }
            try await phone.clear(epoch: 2)
            let mirrorStartFrames = sink.snapshot().frames
            let began = ProcessInfo.processInfo.systemUptime
            var ack: [Int: Double] = [:]
            for id in 1...Barcode.count {
                let frameBegan = ProcessInfo.processInfo.systemUptime
                let jpeg = try Barcode.jpeg(id)
                let sendBegan = ProcessInfo.processInfo.systemUptime
                sink.sent(id, at: sendBegan)
                try await phone.frame(jpeg, epoch: 2)
                ack[id] = (ProcessInfo.processInfo.systemUptime - sendBegan) * 1000
                let remaining = 1.0/Double(targetFPS) - (ProcessInfo.processInfo.systemUptime - frameBegan)
                if remaining > 0 { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - began
            try await Task.sleep(nanoseconds: 1_000_000_000)
            sink.finishParsing()
            let snapshot = sink.snapshot()
            print(String(format: "SENT frames=%d target_fps=%d elapsed_s=%.3f fps=%.3f mirror_frames=%d",
                         Barcode.count, targetFPS, elapsed, Double(Barcode.count)/elapsed, snapshot.frames - mirrorStartFrames))
            stats("ACK", Array(ack.values)); stats("ROUND_TRIP", Array(snapshot.arrivals.values))
            stats("PARSE", snapshot.parse)
            print("PARSE_COUNTS skipped_busy=\(snapshot.skippedBusy) unmatched=\(snapshot.unmatched) ambiguous=\(snapshot.ambiguous) calibrations=\(snapshot.calibrations)")
            for id in 1...Barcode.count {
                let ackText = ack[id].map { String(format: "%.3f", $0) } ?? "NA"
                let roundTripText = snapshot.arrivals[id].map { String(format: "%.3f", $0) } ?? "NA"
                print("FRAME id=\(id) ack_ms=\(ackText) round_trip_ms=\(roundTripText)")
            }
            if let failure = snapshot.failure { throw ScanError(failure) }
            guard snapshot.arrivals.count >= 30 else { throw ScanError("Insufficient matched barcode samples") }
            guard snapshot.ambiguous == 0 else { throw ScanError("Ambiguous barcode matches") }
            guard try await phone.foreground(onVirtualDisplay: true)?.lowercased().contains("scanner") == true else {
                throw ScanError("Scanner left foreground during latency measurement")
            }
            // C3 is the established synthetic QR; inspect only whether its own marker appears.
            try await phone.frame(qr, epoch: 2)
            var passed = false
            for _ in 0..<14 {
                try await Task.sleep(nanoseconds: 500_000_000)
                if try words(await phone.screenshot()).contains(where: { $0.0.contains("006IDC20261025C3") }) {
                    passed = true; break
                }
            }
            guard passed else { throw ScanError("C3 synthetic QR result missing") }
            try await phone.moveWechat(toVirtualDisplay: false); moved = false
            guard try await phone.foreground(onVirtualDisplay: false)?.hasPrefix("com.tencent.mm/") == true else {
                throw ScanError("WeChat result not returned to physical display")
            }
            await mirror.stop()
            try await phone.mainHome()
            let cleanup = await phone.disconnect()
            guard cleanup.isEmpty else { throw ScanError(cleanup) }
            print("PASS latency samples, synthetic C3 result, physical return, cleanup")
        } catch {
            if moved { try? await phone.moveWechat(toVirtualDisplay: false) }
            await mirror.stop()
            print("FAILED", error.localizedDescription)
            print("CLEANUP", await phone.disconnect())
            exit(1)
        }
    }
}
