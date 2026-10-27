import AppKit
import CoreImage

final class NativeMatteImageMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var image: CGImage?, revision = 0, stopped = false
    func publish(_ image: CGImage) { lock.withLock { self.image = image; revision += 1 } }
    func latest() -> (CGImage?, Int, Bool) { lock.withLock { (image,revision,stopped) } }
    func stop() { lock.withLock { stopped = true } }
}

private final class NativeMatteInputView: NSView {
    let phoneLayer = CALayer()
    var metalLayer: CAMetalLayer?
    override init(frame: NSRect) {
        super.init(frame:frame);wantsLayer=true
        phoneLayer.contentsGravity = .resizeAspect
        layer?.addSublayer(phoneLayer)
    }
    required init?(coder: NSCoder) { fatalError("Research view is programmatic") }
    override func layout() {
        super.layout();CATransaction.begin();CATransaction.setDisableActions(true)
        phoneLayer.frame=bounds;CATransaction.commit()
        if let metalLayer {
            CATransaction.begin();CATransaction.setDisableActions(true)
            metalLayer.frame=bounds;metalLayer.contentsScale=window?.backingScaleFactor ?? 2
            metalLayer.drawableSize=CGSize(width:bounds.width*metalLayer.contentsScale,height:bounds.height*metalLayer.contentsScale)
            CATransaction.commit()
        }
    }
}

/// Explicit research UI. Only presents original phone pixels with recovered
/// alpha; no Android buttons, labels or sweep animation are recreated here.
@MainActor final class NativeMattePreview: NSObject, NSWindowDelegate, NSApplicationDelegate {
    let mailbox = NativeMatteImageMailbox()
    private let window: NSWindow
    private let imageView = NativeMatteInputView()
    private var timer: Timer?, revision = -1
    private(set) var presentations = 0
    var presentationLayer: CAMetalLayer? { imageView.metalLayer }
    init(size: CGSize, checkerUnderlay: Bool = false, metalDevice: MTLDevice? = nil) {
        window = NSWindow(contentRect: CGRect(x: 500,y: 140,width: 336,height: 28 + 336 * size.height / size.width),
                          styleMask: [.titled,.closable,.miniaturizable,.fullSizeContentView],backing: .buffered,defer: false)
        super.init()
        window.title = "原生扫码透明合成实验"
        window.isReleasedWhenClosed = false
        window.isOpaque = false; window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.appearance=NSAppearance(named:.darkAqua)
        window.level = .floating
        window.delegate = self
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.clear.cgColor
        imageView.layer?.contentsGravity = .resizeAspect
        imageView.layer?.isOpaque = false
        if checkerUnderlay, let generator=CIFilter(name:"CICheckerboardGenerator",parameters:[
            "inputColor0":CIColor(red:0.65,green:0.82,blue:1),"inputColor1":CIColor.white,"inputWidth":24,"inputSharpness":1]),
           let checker=generator.outputImage,
           let image=CIContext().createCGImage(checker,from:CGRect(origin:.zero,size:CGSize(width:336,height:336*size.height/size.width))) {
            imageView.layer?.contents=image // Test backing only, below original native pixels.
        }
        let root=NSView(),header=NSView()
        header.wantsLayer=true;header.layer?.backgroundColor=NSColor(white:0.14,alpha:1).cgColor
        imageView.translatesAutoresizingMaskIntoConstraints=false;header.translatesAutoresizingMaskIntoConstraints=false
        root.addSubview(imageView);root.addSubview(header);window.contentView=root
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo:root.topAnchor),header.heightAnchor.constraint(equalToConstant:28),
            header.leadingAnchor.constraint(equalTo:root.leadingAnchor),header.trailingAnchor.constraint(equalTo:root.trailingAnchor),
            imageView.topAnchor.constraint(equalTo:header.bottomAnchor),imageView.bottomAnchor.constraint(equalTo:root.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo:root.leadingAnchor),imageView.trailingAnchor.constraint(equalTo:root.trailingAnchor)])
        if let metalDevice {
            let layer=CAMetalLayer();layer.device=metalDevice;layer.pixelFormat = .bgra8Unorm
            layer.framebufferOnly=false;layer.isOpaque=false;layer.maximumDrawableCount=2
            layer.allowsNextDrawableTimeout=true;layer.displaySyncEnabled=true
            imageView.phoneLayer.removeFromSuperlayer();imageView.metalLayer=layer
            imageView.layer?.addSublayer(layer);imageView.needsLayout=true
        }
    }
    func show() {
        NSApp.delegate = self
        window.makeKeyAndOrderFront(nil)
        if presentationLayer == nil {
            let timer = Timer(timeInterval: 1.0/60,target: self,selector: #selector(present),userInfo: nil,repeats: true)
            self.timer = timer; RunLoop.main.add(timer,forMode: .common)
        }
    }
    @objc private func present() {
        let sample = mailbox.latest()
        guard sample.1 != revision, let image = sample.0 else { return }
        revision = sample.1; presentations += 1
        CATransaction.begin(); CATransaction.setDisableActions(true)
        imageView.phoneLayer.contents = image
        CATransaction.commit()
    }
    func close() { timer?.invalidate(); timer = nil; mailbox.stop(); window.orderOut(nil); window.close() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        mailbox.stop(); return .terminateCancel // Let the experiment restore phone tasks first.
    }
    func windowWillClose(_ notification: Notification) { mailbox.stop() }
}

/// Opening the research bundle never starts a phone experiment by itself.
@MainActor final class NativeResearchLauncher: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let window: NSWindow
    private let start: NSButton
    private let operation: () -> Void
    init(operation: @escaping () -> Void) {
        self.operation=operation
        window=NSWindow(contentRect:CGRect(x:500,y:300,width:420,height:190),
            styleMask:[.titled,.closable],backing:.buffered,defer:false)
        start=NSButton(title:"开始 USB 实验",target:nil,action:nil)
        super.init()
        window.title="原生扫码实验 · 未连接";window.isReleasedWhenClosed=false;window.delegate=self
        let label=NSTextField(wrappingLabelWithString:"仅连接唯一已授权的 USB 手机，打开微信扫一扫，使用合成校准帧和纯文本测试码。不会采集桌面或请求录屏权限。")
        label.frame=CGRect(x:24,y:80,width:372,height:80)
        start.frame=CGRect(x:24,y:26,width:160,height:34);start.target=self;start.action=#selector(begin)
        window.contentView?.addSubview(label);window.contentView?.addSubview(start)
    }
    func show() { NSApp.delegate=self;window.makeKeyAndOrderFront(nil) }
    @objc private func begin() {
        start.isEnabled=false;window.orderOut(nil);operation()
    }
    func windowWillClose(_ notification:Notification) { NSApp.terminate(nil) }
}
