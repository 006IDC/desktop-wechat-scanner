import CoreGraphics
import CoreVideo
import Vision

/// In-memory navigation recognition; callers decide which fixed labels to use.
/// No image or recognized text is retained, persisted or logged here.
enum ScannerNavigationOCR {
    enum Region: String, Sendable {
        /// Whole image, including the home screen's title and bottom tab bar.
        case full
        /// Vision coordinates use a bottom-left origin.
        case menu
        case scanner

        var regionOfInterest: CGRect {
            switch self {
            case .full: return CGRect(x: 0, y: 0, width: 1, height: 1)
            case .menu: return CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
            case .scanner: return CGRect(x: 0, y: 0, width: 1, height: 0.24)
            }
        }
    }
    struct Text: Sendable {
        let value: String
        /// Full-image coordinates, top-left origin, normalized to 720 × 1280.
        let rect: CGRect
    }

    static func recognize(_ pixels: CVPixelBuffer, region: Region = .full) throws -> [Text] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.regionOfInterest = region.regionOfInterest
        try VNImageRequestHandler(cvPixelBuffer: pixels).perform([request])
        return (request.results ?? []).compactMap { item in
            guard let text = item.topCandidates(1).first?.string else { return nil }
            // Text observations are normalized to the requested ROI. Compose
            // that box back into the full image before flipping the Y axis.
            // Actual synthetic Vision tests cover the offset menu and bottom strip.
            let box = item.boundingBox
            let roi = request.regionOfInterest
            let full = CGRect(x: roi.minX + box.minX * roi.width,
                              y: roi.minY + box.minY * roi.height,
                              width: box.width * roi.width, height: box.height * roi.height)
            return Text(value: text, rect: CGRect(x: full.minX * 720, y: (1 - full.maxY) * 1280,
                                                  width: full.width * 720, height: full.height * 1280))
        }
    }

    /// Locate the actual circled plus beside an OCR-confirmed WeChat title.
    /// Its ring is circular in source pixels (not in 720×1280 coordinates).
    /// A missing/ambiguous icon returns nil; callers must not guess a toolbar row.
    static func plusButton(in pixels: CVPixelBuffer, homeWords: [Text]) throws -> CGPoint? {
        guard CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(pixels, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        guard width >= 320, height >= 480 else { return nil }
        let probe = PlusPixelProbe(bytes: base, width: width, height: height,
                                   stride: CVPixelBufferGetBytesPerRow(pixels))
        // The OCR may return duplicate boxes for one toolbar row. Merge close
        // Y values, but inspect both distinct rows before choosing the upper one.
        let titles = homeWords.filter {
            $0.value.replacingOccurrences(of: " ", with: "") == "微信" &&
            $0.rect.midY < 170 && (300...420).contains($0.rect.midX)
        }.sorted { $0.rect.midY < $1.rect.midY }
        var rows = [CGFloat]()
        for title in titles where rows.allSatisfy({ abs($0 - title.rect.midY) > 12 }) {
            rows.append(title.rect.midY)
        }
        var matches = [CGPoint]()
        for row in rows {
            var best: (CGPoint, Int)?
            for x in stride(from: CGFloat(657), through: 673, by: 2) {
                for y in stride(from: row - 6, through: row + 6, by: 2) {
                    let cx = x * CGFloat(width) / 720
                    let cy = y * CGFloat(height) / 1280
                    if let score = probe.plusScore(x: cx, y: cy), best == nil || score > best!.1 {
                        best = (CGPoint(x: x, y: y), score)
                    }
                }
            }
            if let best { matches.append(best.0) }
        }
        // Rows were sorted top-first. Two genuine buttons intentionally use
        // the upper row; one genuine button uses its own measured center.
        return matches.first
    }

    private struct PlusPixelProbe {
        let bytes: UnsafePointer<UInt8>
        let width: Int, height: Int, stride: Int

        private func luminance(_ x: CGFloat, _ y: CGFloat) -> Double? {
            let px = Int(x.rounded()), py = Int(y.rounded())
            guard px >= 0, px < width, py >= 0, py < height else { return nil }
            let p = bytes.advanced(by: py * stride + px * 4)
            return 0.114 * Double(p[0]) + 0.587 * Double(p[1]) + 0.299 * Double(p[2])
        }
        private func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }

        /// Score uses a near-complete ring, a center cross, and clear diagonal
        /// gaps. A hollow circle, magnifier handle, dots and empty background fail.
        func plusScore(x: CGFloat, y: CGFloat) -> Int? {
            let r = CGFloat(width) * 0.0235
            let outerOffsets: [(CGFloat, CGFloat)] = [(-1.5, 0), (1.5, 0), (0, -1.5), (0, 1.5),
                                                       (-1.2, -1.2), (1.2, -1.2), (-1.2, 1.2), (1.2, 1.2)]
            let outer = outerOffsets.compactMap { luminance(x + $0.0 * r, y + $0.1 * r) }
            guard outer.count == outerOffsets.count else { return nil }
            let background = median(outer)
            guard outer.allSatisfy({ abs($0 - background) < 32 }) else { return nil }
            // Search a thin radial band to tolerate anti-aliasing and slightly
            // different icon sizes while requiring ink around most of the ring.
            var ring = [Double]()
            for step in 0..<16 {
                let angle = Double(step) * .pi / 8
                let dx = CGFloat(cos(angle)), dy = CGFloat(sin(angle))
                let values = [0.88, 1.0, 1.12].compactMap { scale in
                    luminance(x + dx * r * scale, y + dy * r * scale)
                }
                guard !values.isEmpty else { return nil }
                ring.append(values.max(by: { abs($0 - background) < abs($1 - background) })!)
            }
            let ringMedian = median(ring)
            let polarity = ringMedian < background ? -1.0 : 1.0
            func contrast(_ value: Double) -> Double { (value - background) * polarity }
            guard abs(ringMedian - background) >= 65 else { return nil }
            let ringHits = ring.filter { contrast($0) >= 55 }.count
            guard ringHits >= 13 else { return nil }
            let crossOffsets: [(CGFloat, CGFloat)] = [(0, 0), (-0.18, 0), (0.18, 0),
                                                       (-0.36, 0), (0.36, 0), (0, -0.18),
                                                       (0, 0.18), (0, -0.36), (0, 0.36)]
            let cross = crossOffsets.compactMap { luminance(x + $0.0 * r, y + $0.1 * r) }
            guard cross.count == crossOffsets.count,
                  cross.filter({ contrast($0) >= 55 }).count >= 8 else { return nil }
            let gaps: [(CGFloat, CGFloat)] = [(-0.34, -0.34), (0.34, -0.34),
                                               (-0.34, 0.34), (0.34, 0.34)]
            let clear = gaps.compactMap { luminance(x + $0.0 * r, y + $0.1 * r) }
            guard clear.count == gaps.count,
                  clear.filter({ contrast($0) < 30 }).count >= 3 else { return nil }
            return ringHits * 2 + cross.filter({ contrast($0) >= 55 }).count
        }
    }
}
