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
    @MainActor static func visibleButtons(in view: NSView) -> [String] {
        let own = (view as? NSButton).flatMap { $0.isHidden ? nil : $0.accessibilityLabel() }.map { [$0] } ?? []
        return own + view.subviews.flatMap { visibleButtons(in: $0) }
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
            control.setCameraActive(true); root.layoutSubtreeIfNeeded()
            guard let nativePreview=preview(in:root) else {fatalError("No native preview")}
            require(nativePreview.layer?.sublayers?.allSatisfy{$0.mask == nil} == true,
                    "Activating desktop camera must retain the complete native Android frame")
            control.setLocalScanPreview(true); root.layoutSubtreeIfNeeded()
            guard let view = preview(in: root), let layers = view.layer?.sublayers else { fatalError("No preview layers") }
            require(layers.allSatisfy { $0.mask == nil },
                    "Legacy local aperture request must not cut holes in Android pixels")
            require(window.isOpaque && !window.titlebarAppearsTransparent,
                    "Native title bar must remain opaque and use AppKit traffic lights")
            require(window.level == .floating && window.collectionBehavior == [.canJoinAllApplications],
                    "Scanner is not eligible to float over another app")
            require(visibleButtons(in: root).contains("暂停桌面相机"),
                    "Active camera must expose a pause action")
            control.setCameraActive(true, paused: true)
            require(window.level == originalLevel && window.collectionBehavior == originalBehavior,
                    "Paused camera must restore ordinary window level")
            require(visibleButtons(in: root).contains("继续桌面相机"),
                    "Paused camera must keep a visible continue action")
            control.setCameraActive(true, paused: false)
            require(window.level == .floating && visibleButtons(in: root).contains("暂停桌面相机"),
                    "Continuing camera must restore floating level and pause action")
            control.setLocalScanPreview(false); control.setCameraActive(false)
            require(layers.allSatisfy { $0.mask == nil }, "Leaving scanner kept a video hole")
            require(window.level == originalLevel && window.collectionBehavior == originalBehavior,
                    "Leaving scanner did not restore original window behavior")
        }
        let mainWindow = ControlWindowController()
        if let window = mainWindow.window {
            require(window.title == "手机镜像", "Main mirror title must describe the general device")
            let buttons = visibleButtons(in: window.contentView!)
            require(buttons.contains("连接手机") && buttons.contains("返回") && buttons.contains("主屏幕") &&
                    buttons.contains("应用列表"), "Main mirror is missing general navigation")
            require(!buttons.contains("微信") && !buttons.contains("桌面扫码"),
                    "Main mirror still exposes a single-app scan shortcut")
            let originalLevel = window.level, originalBehavior = window.collectionBehavior
            mainWindow.setCameraActive(true)
            require(window.level == .floating && window.collectionBehavior == [.canJoinAllApplications],
                    "Main mirror must float while its app uses the desktop camera")
            mainWindow.setCameraActive(true, paused: true)
            require(window.level == originalLevel && visibleButtons(in: window.contentView!).contains("继续桌面相机"),
                    "Paused main mirror must remain resumable at ordinary level")
            mainWindow.setCameraActive(false)
            require(window.level == originalLevel && window.collectionBehavior == originalBehavior,
                    "Main mirror did not restore its normal window behavior")
            window.close()
        } else { fatalError("No main window") }
        require(!window.isVisible && !NSApp.isActive, "Fixture displayed or activated a window")
        print("PASS complete native frame, opaque title bar and window behavior restoration; no displayed window")
    }
}
