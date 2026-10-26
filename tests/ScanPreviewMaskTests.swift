import AppKit
import AVFoundation

// Use AppKit's actual view-to-layer conversion, not a second copy of our
// coordinate formula. No window is ordered, no phone or capture API is linked.
@main enum ScanPreviewMaskTests {
    static func require(_ condition: Bool, _ message: String) {
        if !condition { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    @MainActor static func preview(in view: NSView) -> NSView? {
        if view.layer?.sublayers?.contains(where: { $0 is AVSampleBufferDisplayLayer }) == true { return view }
        return view.subviews.lazy.compactMap { preview(in: $0) }.first
    }
    @MainActor static func main() {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let control = ControlWindowController(title: "Synthetic", standalone: true, scanner: true)
        guard let window = control.window, let root = window.contentView else { fatalError("No own window") }
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let originalLevel = window.level, originalBehavior = window.collectionBehavior
        for size in [NSSize(width: 1080, height: 2400), NSSize(width: 720, height: 1280)] {
            control.setPhoneImage(NSImage(size: size, flipped: false) { rect in
                NSColor.red.setFill(); rect.fill(); return true
            })
            root.layoutSubtreeIfNeeded()
            control.setLocalScanPreview(true); root.layoutSubtreeIfNeeded()
            guard let view = preview(in: root), let layers = view.layer?.sublayers else { fatalError("No preview layers") }
            let masks = layers.compactMap { $0.mask as? CAShapeLayer }
            require(masks.count == 2, "Both still and video layers need a mask")
            for fraction: CGFloat in [0.10, 0.20, 0.50, 0.70, 0.80, 0.90] {
                let point = view.convertToLayer(CGPoint(x: view.bounds.midX, y: view.bounds.height * fraction))
                let keepsPhonePixels = fraction < 0.16 || fraction >= 0.75
                for mask in masks {
                    require(mask.path?.contains(point, using: .evenOdd) == keepsPhonePixels,
                            "Native view/layer mask mismatch at \(fraction); likely a second Y flip")
                }
            }
            require(window.level == .floating && window.collectionBehavior == [.canJoinAllApplications],
                    "Scanner is not eligible to float over another app")
            control.setLocalScanPreview(false)
            require(layers.allSatisfy { $0.mask == nil }, "Leaving scanner kept a video hole")
            require(window.level == originalLevel && window.collectionBehavior == originalBehavior,
                    "Leaving scanner did not restore original window behavior")
        }
        require(!window.isVisible && !NSApp.isActive, "Fixture displayed or activated a window")
        print("PASS native mask alignment for both layers/aspects, retained controls and window behavior restoration; no displayed window")
    }
}
