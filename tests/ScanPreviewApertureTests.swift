import AppKit

@main enum ScanPreviewApertureTests {
    private static func require(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }
    }

    static func main() {
        let normalized = ScanPreviewAperture.standard
        require(ScanPreviewAperture.valid(normalized), "Default scan aperture is invalid")
        require(normalized.minY == 0.16 && normalized.maxY == 0.75,
                "Default scan aperture obscures WeChat's top or bottom controls")

        let fullImage = CGRect(x: 0, y: 0, width: 300, height: 600)
        let fullOpening = ScanPreviewAperture.opening(in: fullImage, normalized: normalized)
        require(fullOpening == CGRect(x: 0, y: 96, width: 300, height: 354),
                "Portrait aperture does not follow the phone image")
        require(!fullOpening.contains(CGPoint(x: 150, y: 40)) &&
                !fullOpening.contains(CGPoint(x: 150, y: 550)),
                "Top or bottom phone controls fell inside the aperture")

        // An aspect-fitted image must position the same normalized opening
        // inside the image, leaving both letterbox bars untouched.
        let insetImage = CGRect(x: 30, y: 12, width: 240, height: 480)
        require(ScanPreviewAperture.opening(in: insetImage, normalized: normalized) ==
                CGRect(x: 30, y: 88.8, width: 240, height: 283.2),
                "Aspect-fitted image aperture moved into letterboxing")
        require(ScanPreviewAperture.opening(in: fullImage, normalized: .zero) == .zero,
                "Zero aperture was accepted")
        require(!ScanPreviewAperture.valid(CGRect(x: 0, y: 0.5, width: 1, height: 0.6)),
                "Aperture overlapping bottom controls was accepted")
        require(ScanPreviewAperture.visibleOpening(in: fullImage, normalized: normalized, enabled: true) == fullOpening,
                "Enabling camera preview did not expose the aperture")
        require(ScanPreviewAperture.visibleOpening(in: fullImage, normalized: normalized, enabled: false) == nil,
                "Leaving camera preview did not restore the full phone image")
        print("PASS normalized scan aperture geometry; retained top/bottom controls; aspect-fitted image; invalid aperture rejection")
    }
}
