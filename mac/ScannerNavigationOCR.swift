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
}
