import AppKit

final class NativeMatteImageMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var image: CGImage?, revision = 0, stopped = false
    func publish(_ image: CGImage) { lock.withLock { self.image = image; revision += 1 } }
    func latest() -> (CGImage?, Int, Bool) { lock.withLock { (image,revision,stopped) } }
    func stop() { lock.withLock { stopped = true } }
}

/// Explicit research UI. Only presents original phone pixels with recovered
/// alpha; no Android buttons, labels or sweep animation are recreated here.
@MainActor final class NativeMattePreview: NSObject, NSWindowDelegate, NSApplicationDelegate {
    let mailbox = NativeMatteImageMailbox()
    private let window: NSWindow
    private let imageView = NSView()
    private var timer: Timer?, revision = -1
    private(set) var presentations = 0
    init(size: CGSize) {
        window = NSWindow(contentRect: CGRect(x: 500,y: 140,width: 336,height: 336 * size.height / size.width),
                          styleMask: [.titled,.closable,.miniaturizable],backing: .buffered,defer: false)
        super.init()
        window.title = "原生扫码透明合成实验"
        window.isReleasedWhenClosed = false
        window.isOpaque = false; window.backgroundColor = .clear
        window.titlebarAppearsTransparent = false
        window.level = .floating
        window.delegate = self
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.clear.cgColor
        imageView.layer?.contentsGravity = .resizeAspect
        imageView.layer?.isOpaque = false
        window.contentView = imageView
    }
    func show() {
        NSApp.delegate = self
        window.makeKeyAndOrderFront(nil)
        let timer = Timer(timeInterval: 1.0/60,target: self,selector: #selector(present),userInfo: nil,repeats: true)
        self.timer = timer; RunLoop.main.add(timer,forMode: .common)
    }
    @objc private func present() {
        let sample = mailbox.latest()
        guard sample.1 != revision, let image = sample.0 else { return }
        revision = sample.1; presentations += 1
        CATransaction.begin(); CATransaction.setDisableActions(true)
        imageView.layer?.contents = image
        CATransaction.commit()
    }
    func close() { timer?.invalidate(); timer = nil; mailbox.stop(); window.orderOut(nil); window.close() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        mailbox.stop(); return .terminateCancel // Let the experiment restore phone tasks first.
    }
    func windowWillClose(_ notification: Notification) { mailbox.stop() }
}
