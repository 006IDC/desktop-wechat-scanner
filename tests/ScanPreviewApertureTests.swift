import AppKit

@main enum ScanPreviewApertureTests {
    private static func require(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }
    }
    private static func close(_ actual: CGRect, _ expected: CGRect) -> Bool {
        abs(actual.minX - expected.minX) < 0.001 && abs(actual.minY - expected.minY) < 0.001 &&
        abs(actual.width - expected.width) < 0.001 && abs(actual.height - expected.height) < 0.001
    }

    static func main() {
        let normalized = ScanPreviewAperture.standard
        require(ScanPreviewAperture.valid(normalized), "Default scan aperture is invalid")
        require(normalized.minY == 0 && normalized.maxY == 0.918,
                "Desktop preview does not reach the top or overlaps WeChat's bottom tabs")

        let fullImage = CGRect(x: 0, y: 0, width: 300, height: 600)
        let fullOpening = ScanPreviewAperture.opening(in: fullImage, normalized: normalized)
        require(close(fullOpening, CGRect(x: 0, y: 0, width: 300, height: 550.8)),
                "Portrait aperture does not follow the phone image")
        require(fullOpening.contains(CGPoint(x: 150, y: 40)) &&
                !fullOpening.contains(CGPoint(x: 150, y: 560)),
                "Desktop preview failed to cover the top or obscured bottom tabs")
        require(ScanPreviewAperture.retainedButtons(in: fullImage, opening: fullOpening).count == 4,
                "A real scanner control island fell outside the desktop preview")

        // An aspect-fitted image must position the same normalized opening
        // inside the image, leaving both letterbox bars untouched.
        let insetImage = CGRect(x: 30, y: 12, width: 240, height: 480)
        require(close(ScanPreviewAperture.opening(in: insetImage, normalized: normalized),
                      CGRect(x: 30, y: 12, width: 240, height: 440.64)),
                "Aspect-fitted image aperture moved into letterboxing")
        require(ScanPreviewAperture.opening(in: fullImage, normalized: .zero) == .zero,
                "Zero aperture was accepted")
        require(!ScanPreviewAperture.valid(CGRect(x: 0, y: 0.5, width: 1, height: 0.6)),
                "Aperture overlapping bottom controls was accepted")
        require(ScanPreviewAperture.visibleOpening(in: fullImage, normalized: normalized, enabled: true) == fullOpening,
                "Enabling camera preview did not expose the aperture")
        require(ScanPreviewAperture.visibleOpening(in: fullImage, normalized: normalized, enabled: false) == nil,
                "Leaving camera preview did not restore the full phone image")
        print("PASS continuous desktop preview and four retained controls; aspect-fitted image; invalid aperture rejection")
    }
}
