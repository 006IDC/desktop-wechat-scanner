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
            let samples: [(CGFloat, CGFloat, Bool)] = [
                (0.02, 0.087, false), (0.079, 0.087, true), (0.15, 0.087, false),
                (0.927, 0.087, true), (0.50, 0.50, false), (0.50, 0.82, false),
                (0.30, 0.862, true), (0.65, 0.862, false),
                (0.871, 0.862, true), (0.50, 0.905, false), (0.50, 0.95, true)
            ]
            for (x, y, keepsPhonePixels) in samples {
                let point = view.convertToLayer(CGPoint(x: view.bounds.width * x, y: view.bounds.height * y))
                for mask in masks {
                    require(mask.path?.contains(point, using: .evenOdd) == keepsPhonePixels,
                            "Native mask mismatch at (\(x), \(y)); likely a second Y flip or a lost control island")
                }
            }
            let outsidePillCorner = view.convertToLayer(CGPoint(x: view.bounds.width * 0.055,
                                                                 y: view.bounds.height * 0.835))
            require(masks.allSatisfy { $0.path?.contains(outsidePillCorner, using: .evenOdd) == false },
                    "Video island became a rectangular background patch")
            require(window.level == .floating && window.collectionBehavior == [.canJoinAllApplications],
                    "Scanner is not eligible to float over another app")
            control.setLocalScanPreview(false)
            require(layers.allSatisfy { $0.mask == nil }, "Leaving scanner kept a video hole")
            require(window.level == originalLevel && window.collectionBehavior == originalBehavior,
                    "Leaving scanner did not restore original window behavior")
        }
        require(!window.isVisible && !NSApp.isActive, "Fixture displayed or activated a window")
        print("PASS continuous desktop mask and four real video-control islands for both layers/aspects, with restoration; no displayed window")
    }
}
