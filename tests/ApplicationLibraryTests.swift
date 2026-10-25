import AppKit

// This standalone test intentionally links no phone/session implementation.
struct ScanError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

@MainActor private final class PresentationProbeWindow: NSWindow {
    var presentationRequested = false
    // Observe presentation without ordering any window into the shared UI.
    override func makeKeyAndOrderFront(_ sender: Any?) { presentationRequested = true }
    override func deminiaturize(_ sender: Any?) {}
}

/// Default: pure intent/geometry only. --own-window creates one never-ordered,
/// noninteractive window and intercepts presentation; no phone/TCC/drag events.
@main enum ApplicationLibraryTests {
    static func require(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
    @MainActor static func main() {
        let app = AndroidApplication(packageName: "org.example.fixture", component: "org.example.fixture/.Main", name: "示例应用")
        let library = NSRect(x: 100, y: 200, width: 390, height: 510)
        let outside = NSPoint(x: 800, y: 500)
        var drag = ApplicationDragIntent()
        drag.begin(app, at: 50)
        require(drag.beganAt == 50, "Drag start timestamp missing")
        require(drag.finish(at: outside, libraryFrame: library) == app, "Outside release did not request open")
        require(drag.finish(at: outside, libraryFrame: library) == nil, "One drag opened twice")
        drag.begin(app, at: 51); drag.cancel()
        require(drag.finish(at: outside, libraryFrame: library) == nil, "Escape cancellation opened an app")
        drag.begin(app, at: 52)
        require(drag.finish(at: outside, libraryFrame: library, cancelledByEscape: true) == nil, "Explicit current-drag escape was ignored")
        drag.begin(app, at: 53)
        require(drag.finish(at: outside, libraryFrame: library) == app, "Previous cancellation poisoned next drag")
        drag.begin(app, at: 54)
        require(drag.finish(at: NSPoint(x: 120, y: 220), libraryFrame: library) == nil, "Inside release opened a new window")
        require(drag.finish(at: outside, libraryFrame: library) == nil, "Inside release left stale application intent")
        drag.begin(nil, at: 55)
        require(drag.finish(at: outside, libraryFrame: library) == nil, "Missing row created an app")
        drag.begin(app, at: 56)
        require(drag.finish(at: outside, libraryFrame: nil) == nil, "Closed library allowed stale drag completion")
        drag.begin(app, at: 57)
        require(drag.finish(at: NSPoint(x: CGFloat.nan, y: 1), libraryFrame: library) == nil, "Invalid drop point accepted")

        let primary = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let left = NSRect(x: -1600, y: 40, width: 1600, height: 1000)
        let above = NSRect(x: 0, y: 1000, width: 1400, height: 900)
        let frame = NSRect(x: 50, y: 80, width: 360, height: 700)
        for (point, screen) in [(NSPoint(x: 800, y: 500), primary), (NSPoint(x: -1200, y: 700), left), (NSPoint(x: 700, y: 1500), above)] {
            let destination = AppWindowMotion.destination(for: frame, at: point, screens: [primary, left, above], fallback: primary)
            require(screen.contains(destination), "Drop destination ended outside its screen")
            require(destination.size == frame.size, "Drop changed phone aspect/size")
        }
        let clamped = AppWindowMotion.destination(for: frame, at: NSPoint(x: 9000, y: -9000), screens: [primary], fallback: primary)
        require(primary.contains(clamped), "Offscreen drop did not clamp to a usable screen")
        let invalidPoint = AppWindowMotion.destination(for: frame, at: NSPoint(x: CGFloat.nan, y: CGFloat.infinity), screens: [primary], fallback: primary)
        require(invalidPoint == frame, "Invalid point corrupted the existing valid frame")
        if CommandLine.arguments.contains("--own-window") {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.prohibited)
            let window = PresentationProbeWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 600),
                                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.ignoresMouseEvents = true; window.alphaValue = 0
            defer { window.orderOut(nil); window.close() }
            AppWindowMotion.reveal(window, from: outside)
            require(window.presentationRequested, "Reveal never requested window presentation")
            require(window.alphaValue == 1, "Reveal left its loading/error window transparent")
            require(!window.isVisible && window.ignoresMouseEvents, "Probe exposed an interactive/shared window")
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            require(window.alphaValue == 1 && !window.isVisible, "Animation depended on delayed alpha restoration")
            print("PASS own-window intercepted presentation and immediate opacity; no window ordered, no phone/TCC/shared UI")
        }
        print("PASS native-drag intent, escape/new-session reset, duplicate completion, drop geometry and screen clamping")
    }
}
