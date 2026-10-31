import AppKit

/// Keep AppKit's title, buttons and drag handling over an opaque titlebar,
/// independently of the transparent phone aperture. Never replace the buttons.
@MainActor enum NativeWindowChrome {
    static let identifier=NSUserInterfaceItemIdentifier("miradroid.native-titlebar-background")
    private final class Backdrop:NSView {
        override var isOpaque:Bool {true}
        override func draw(_ dirtyRect:NSRect) {NSColor.windowBackgroundColor.setFill();bounds.fill()}
        override func hitTest(_ point:NSPoint)->NSView? {nil}
        override func viewDidChangeEffectiveAppearance() {super.viewDidChangeEffectiveAppearance();needsDisplay=true}
    }
    static func install(in window:NSWindow)->NSView? {
        guard window.styleMask.contains(.titled),!window.styleMask.contains(.fullSizeContentView),
              let close=window.standardWindowButton(.closeButton),
              let minimize=window.standardWindowButton(.miniaturizeButton),
              let zoom=window.standardWindowButton(.zoomButton) else{return nil}
        let titleHeight=window.frame.height-window.contentLayoutRect.height
        guard titleHeight>=16,titleHeight<=64 else{return nil}
        var ancestor=close.superview
        while let host=ancestor,host.window === window {
            let rect=host.convert(host.bounds,to:nil)
            if abs(host.bounds.width-window.frame.width)<=2,abs(host.bounds.height-titleHeight)<=2,
               rect.minY>=window.contentLayoutRect.maxY-2,
               minimize.isDescendant(of:host),zoom.isDescendant(of:host) {
                // Native containers are discovered by public geometry/button
                // relationships; do not depend on private AppKit class names.
                let view=Backdrop(frame:host.bounds);view.identifier=identifier
                view.autoresizingMask=[.width,.height];view.setAccessibilityElement(false)
                host.addSubview(view,positioned:.below,relativeTo:nil)
                return view
            }
            ancestor=host.superview
        }
        return nil
    }
}
