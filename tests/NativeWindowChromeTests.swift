import AppKit
@main enum NativeWindowChromeTests {
    @MainActor static func main() {
        let app=NSApplication.shared;app.setActivationPolicy(.prohibited)
        let window=NSWindow(contentRect:NSRect(x:20,y:20,width:360,height:640),
                            styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false
        defer{window.close()}
        let content=window.contentLayoutRect,frame=window.frame
        let buttons:[NSButton]=[.closeButton,.miniaturizeButton,.zoomButton].compactMap{window.standardWindowButton($0)}
        let parents=buttons.map{$0.superview!},positions=buttons.map{$0.frame}
        for theme:NSAppearance.Name in [.aqua,.darkAqua] {
            window.appearance=NSAppearance(named:theme)
            guard let backdrop=NativeWindowChrome.install(in:window) else{fatalError("Own native titlebar not found")}
            precondition(backdrop.hitTest(.zero)==nil,"Titlebar backdrop intercepted native dragging/buttons")
            precondition(!backdrop.isAccessibilityElement(),"Decorative chrome entered accessibility navigation")
            precondition(window.frame==frame && window.contentLayoutRect==content,"Phone layout moved when attaching chrome")
            for i in buttons.indices {
                precondition(buttons[i].superview === parents[i] && buttons[i].frame==positions[i] && !buttons[i].isHidden,
                             "Native traffic light replaced, hidden or moved")
            }
            backdrop.removeFromSuperview()
        }
        let borderless=NSWindow(contentRect:.zero,styleMask:.borderless,backing:.buffered,defer:false)
        borderless.isReleasedWhenClosed=false;defer{borderless.close()}
        precondition(NativeWindowChrome.install(in:borderless)==nil)
        precondition(!window.isVisible && !borderless.isVisible && !NSApp.isActive)
        print("PASS native titlebar/backdrop isolation, layout, system buttons, hit-test/AX and incompatible-window rejection; no window displayed")
    }
}
