import AppKit
import QuartzCore
import AVFoundation
import CoreMedia
import CoreVideo

private enum ViewStyle {
    static let green = NSColor.systemGreen
    static let inset: CGFloat = 12
    static let phoneRatio: CGFloat = 9.0 / 16.0
}

/// The live camera occupies this part of the mirrored phone image. Coordinates
/// are normalized from its top-left corner, independent of window letterboxing.
enum ScanPreviewAperture {
    static let standard = CGRect(x: 0, y: 0.16, width: 1, height: 0.59)

    static func valid(_ rect: CGRect) -> Bool {
        rect.minX.isFinite && rect.minY.isFinite && rect.width.isFinite && rect.height.isFinite &&
        rect.width > 0 && rect.height > 0 && rect.minX >= 0 && rect.minY >= 0 &&
        rect.maxX <= 1 && rect.maxY <= 1
    }

    static func opening(in image: CGRect, normalized rect: CGRect) -> CGRect {
        guard valid(rect), image.width > 0, image.height > 0 else { return .zero }
        return CGRect(x: image.minX + rect.minX * image.width,
                      y: image.minY + rect.minY * image.height,
                      width: rect.width * image.width, height: rect.height * image.height)
    }

    static func visibleOpening(in image: CGRect, normalized rect: CGRect, enabled: Bool) -> CGRect? {
        guard enabled else { return nil }
        let result = opening(in: image, normalized: rect)
        return result.isEmpty ? nil : result
    }
}

private func text(_ value: String, size: CGFloat, weight: NSFont.Weight = .regular,
                  color: NSColor = .labelColor) -> NSTextField {
    let field = NSTextField(labelWithString: value)
    field.font = .systemFont(ofSize: size, weight: weight)
    field.textColor = color
    field.lineBreakMode = .byWordWrapping
    field.maximumNumberOfLines = 0
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return field
}

private func button(_ title: String, tooltip: String) -> NSButton {
    let control = NSButton(title: title, target: nil, action: nil)
    control.bezelStyle = .rounded
    control.toolTip = tooltip
    control.setAccessibilityLabel(title)
    control.heightAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true
    return control
}

/// Paint the native window surface around an optional live desktop aperture.
/// The aperture is computed from the same preview bounds as desktopCaptureRect.
private final class PhoneWindowBackgroundView: NSView {
    weak var preview: PhonePreviewView?
    var localScanPreview = false { didSet { needsDisplay = true } }
    var aperture = ScanPreviewAperture.standard { didSet { needsDisplay = true } }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        // Explicitly erase the previous surface when entering or resizing the aperture.
        NSColor.clear.setFill()
        bounds.fill(using: .copy)
        let background = NSBezierPath(rect: bounds)
        if let preview, preview.window === window,
           let localOpening = ScanPreviewAperture.visibleOpening(in: preview.imageArea,
                                                                  normalized: aperture,
                                                                  enabled: localScanPreview) {
            let opening = convert(localOpening, from: preview)
            if opening.width > 0, opening.height > 0 {
                background.append(NSBezierPath(roundedRect: opening, xRadius: 12, yRadius: 12))
                background.windingRule = .evenOdd
            }
        }
        NSColor.windowBackgroundColor.setFill()
        background.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Emits 0…1 coordinates from the actual image area, with a top-left origin.
private final class PhonePreviewView: NSView {
    private let frameLayer = CALayer()
    private let videoLayer = AVSampleBufferDisplayLayer()
    private let frameMask = CAShapeLayer()
    private let videoMask = CAShapeLayer()
    private var videoFormat: CMVideoFormatDescription?
    private var mirrorPixels: CVPixelBuffer?
    private var mirrorFrame: CGImage?
    private var hasFrame: Bool { mirrorPixels != nil || mirrorFrame != nil }
    private var mirrorSize: NSSize = .zero
    var emptyMessage = "连接手机后显示真实手机画面" { didSet { if !hasFrame { needsDisplay = true } } }
    var aperture = ScanPreviewAperture.standard {
        didSet { updateLayerMasks(); needsDisplay = true }
    }
    var imageArea: CGRect { imageRect }
    var scanOpening: CGRect? {
        ScanPreviewAperture.visibleOpening(in: imageRect, normalized: aperture, enabled: localScanPreview)
    }
    var localScanPreview = false {
        didSet {
            touchStart = nil; touchStartLocation = nil
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            frameLayer.isHidden = mirrorFrame == nil
            videoLayer.isHidden = mirrorPixels == nil
            updateLayerMasks()
            CATransaction.commit()
            needsDisplay = true
        }
    }
    var onTap: ((Double, Double) -> Void)?
    var onTouch: ((UInt8, Double, Double) -> Void)?
    var onSwipe: ((Double, Double, Double, Double) -> Void)?
    private var touchStart: NSPoint?
    private var touchStartLocation: NSPoint?
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        frameLayer.contentsGravity = .resizeAspect
        frameLayer.minificationFilter = .linear
        frameLayer.magnificationFilter = .linear
        frameLayer.isHidden = true
        // Stream frames are already immutable CGImages. Let Core Animation
        // composite them directly instead of redrawing NSImage into a backing store.
        layer?.addSublayer(frameLayer)
        videoLayer.videoGravity = .resizeAspect
        videoLayer.isHidden = true
        layer?.addSublayer(videoLayer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func setImage(_ image: NSImage?) {
        var proposed = NSRect(origin: .zero, size: image?.size ?? .zero)
        let frame = image?.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
        setFrame(frame, size: image?.size)
    }

    func setFrame(_ frame: CGImage?, size: NSSize? = nil) {
        let hadFrame = hasFrame
        if mirrorPixels != nil || frame == nil {
            videoLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
            videoFormat = nil
        }
        mirrorPixels = nil
        mirrorFrame = frame
        mirrorSize = size ?? frame.map { NSSize(width: $0.width, height: $0.height) } ?? .zero
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frameLayer.contents = frame
        frameLayer.isHidden = frame == nil
        videoLayer.isHidden = true
        CATransaction.commit()
        // Only empty/filled state changes redraw the static black/placeholder
        // surface. Ordinary video frames update the independent contents layer.
        if hadFrame != (frame != nil) { needsDisplay = true }
    }

    func setPixelBuffer(_ pixels: CVPixelBuffer?) {
        guard let pixels else { setFrame(nil); return }
        let hadFrame = hasFrame
        mirrorFrame = nil
        mirrorPixels = pixels
        mirrorSize = NSSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frameLayer.contents = nil
        frameLayer.isHidden = true
        videoLayer.isHidden = false
        CATransaction.commit()
        enqueuePixels(pixels)
        if !hadFrame { needsDisplay = true }
    }

    private func enqueuePixels(_ pixels: CVPixelBuffer) {
        let renderer = videoLayer.sampleBufferRenderer
        // Follow AVFoundation's recovery contract before resuming enqueue.
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding { renderer.flush() }
        // The common-mode presentation tick already selects only the latest frame.
        // Drop this presentation when AVFoundation is full instead of building a queue.
        guard renderer.isReadyForMoreMediaData else { return }
        if videoFormat == nil || !CMVideoFormatDescriptionMatchesImageBuffer(videoFormat!, imageBuffer: pixels) {
            var format: CMVideoFormatDescription?
            guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                               imageBuffer: pixels,
                                                               formatDescriptionOut: &format) == noErr else { return }
            videoFormat = format
        }
        guard let videoFormat else { return }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels,
                                                       formatDescription: videoFormat, sampleTiming: &timing,
                                                       sampleBufferOut: &sample) == noErr, let sample,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
              CFArrayGetCount(attachments) > 0 else { return }
        let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(dictionary,
                             Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                             Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        renderer.enqueue(sample)
    }

    override func layout() {
        super.layout()
        updateLayerFrames()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateLayerFrames()
    }

    private func updateLayerFrames() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frameLayer.frame = bounds
        videoLayer.frame = bounds
        updateLayerMasks()
        CATransaction.commit()
    }

    private func updateLayerMasks() {
        for (content, mask) in [(frameLayer, frameMask), (videoLayer, videoMask)] {
            guard localScanPreview else { content.mask = nil; continue }
            guard let opening = scanOpening else { content.mask = nil; continue }
            // These sublayers inherit the flipped NSView's coordinate space.
            // A second Y flip shifts the video hole away from the backing hole.
            let path = CGMutablePath()
            path.addRect(bounds)
            path.addRect(opening)
            mask.frame = bounds
            mask.fillRule = .evenOdd
            mask.path = path
            mask.fillColor = NSColor.white.cgColor
            content.mask = mask
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateContentsScale()
        needsLayout = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateContentsScale()
    }

    private func updateContentsScale() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frameLayer.contentsScale = window?.backingScaleFactor ?? 1
        videoLayer.contentsScale = window?.backingScaleFactor ?? 1
        CATransaction.commit()
    }

    private var imageRect: NSRect {
        let bounds = self.bounds
        guard hasFrame, mirrorSize.width > 0, mirrorSize.height > 0 else { return bounds }
        let scale = min(bounds.width / mirrorSize.width, bounds.height / mirrorSize.height)
        let width = mirrorSize.width * scale
        let height = mirrorSize.height * scale
        return NSRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2,
                      width: width, height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        if localScanPreview {
            NSColor.black.setFill()
            bounds.fill(using: .copy)
            // Keep a tiny alpha so this window remains the pointer target.
            NSColor.black.withAlphaComponent(0.01).setFill()
            scanOpening?.fill(using: .copy)
            return
        }
        NSColor.black.setFill()
        bounds.fill()
        if !hasFrame {
            let symbol = NSImage(systemSymbolName: "iphone.gen3", accessibilityDescription: nil)
                ?? NSImage(systemSymbolName: "iphone", accessibilityDescription: nil)
            let icon = symbol?.withSymbolConfiguration(.init(hierarchicalColor: .white))
            let iconRect = NSRect(x: bounds.midX - 30, y: bounds.midY - 76,
                                  width: 60, height: 60)
            icon?.draw(in: iconRect, from: .zero, operation: .sourceOver,
                       fraction: 0.8, respectFlipped: true, hints: nil)
            let message = emptyMessage
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.white
            ]
            let size = (message as NSString).size(withAttributes: attrs)
            let origin = NSPoint(x: (bounds.width - size.width) / 2,
                                 y: bounds.midY + 12)
            (message as NSString).draw(at: origin, withAttributes: attrs)
        }
    }

    private func normalized(_ location: NSPoint) -> NSPoint {
        let rect = imageRect
        return NSPoint(x: min(1, max(0, (location.x - rect.minX) / rect.width)),
                       y: min(1, max(0, (location.y - rect.minY) / rect.height)))
    }

    override func mouseDown(with event: NSEvent) {
        guard hasFrame else { return }
        let location = convert(event.locationInWindow, from: nil)
        guard imageRect.contains(location) else { return }
        touchStart = normalized(location)
        touchStartLocation = location
        if let start=touchStart { onTouch?(0,Double(start.x),Double(start.y)) }
    }

    override func mouseDragged(with event:NSEvent) {
        guard touchStart != nil,onTouch != nil else{return}
        let point=normalized(convert(event.locationInWindow,from:nil))
        onTouch?(2,Double(point.x),Double(point.y))
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = touchStart, let location = touchStartLocation else { return }
        defer { touchStart = nil; touchStartLocation = nil }
        let finishLocation = convert(event.locationInWindow, from: nil)
        let end = normalized(finishLocation)
        if let onTouch { onTouch(1,Double(end.x),Double(end.y));return }
        if hypot(finishLocation.x - location.x, finishLocation.y - location.y) >= 12 {
            onSwipe?(Double(start.x), Double(start.y), Double(end.x), Double(end.y))
        } else if imageRect.contains(finishLocation) {
            onTap?(Double(end.x), Double(end.y))
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard hasFrame else { return }
        let amount = min(0.40, max(-0.40, event.scrollingDeltaY * 0.006))
        guard abs(amount) > 0.02 else { return }
        onSwipe?(0.5, 0.5 - Double(amount), 0.5, 0.5 + Double(amount))
    }

    override func accessibilityPerformPress() -> Bool {
        // Pointer location matters for a phone tap; do not invent a tap on a
        // potentially sensitive control when VoiceOver presses the preview.
        false
    }
}

private final class PhoneAspectHolder: NSView {
    let phone = PhonePreviewView()
    var applicationPicker: PhoneApplicationPicker? {
        didSet {
            oldValue?.removeFromSuperview()
            if let applicationPicker {
                applicationPicker.isHidden = true
                addSubview(applicationPicker)
            }
            needsLayout = true
        }
    }
    var onLayout: (() -> Void)?
    var aspectRatio = ViewStyle.phoneRatio { didSet { needsLayout = true } }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(phone)
        setContentHuggingPriority(.defaultLow, for: .vertical)
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func layout() {
        super.layout()
        let width = min(bounds.width, bounds.height * aspectRatio)
        let height = width / aspectRatio
        phone.frame = NSRect(x: (bounds.width - width) / 2,
                             y: (bounds.height - height) / 2,
                             width: width, height: height)
        applicationPicker?.frame = phone.frame
        onLayout?()
    }
}

private func toolbarButton(_ title: String, symbol: String, tooltip: String) -> NSButton {
    let control = NSButton(title:title,target:nil,action:nil)
    control.toolTip = tooltip
    control.setAccessibilityLabel(title)
    control.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
        .withSymbolConfiguration(.init(pointSize:17,weight:.medium))
    control.imagePosition = .imageOnly
    control.bezelStyle = .recessed
    control.showsBorderOnlyWhileMouseInside = true
    control.heightAnchor.constraint(equalToConstant:34).isActive = true
    control.widthAnchor.constraint(equalToConstant:44).isActive = true
    return control
}

/// A single, narrow phone-shaped window. AppController owns the phone session,
/// scanning state and all permissions; this class only renders their state.
final class ControlWindowController: NSWindowController {
    var onConnect: (() -> Void)?
    var onDisconnect: (() -> Void)?
    var onScan: (() -> Void)?
    var onPause: (() -> Void)?
    var onBack: (() -> Void)?
    var onHome: (() -> Void)?
    var onWechat: (() -> Void)?
    var onApplications: (() -> Void)?
    var onPermissionSettings: (() -> Void)?
    var onRelaunch: (() -> Void)?
    var onTap: ((Double, Double) -> Void)?
    var onTouch: ((UInt8, Double, Double) -> Void)? {
        didSet { holder.phone.onTouch = onTouch }
    }
    var onSwipe: ((Double, Double, Double, Double) -> Void)?

    private let connectButton = toolbarButton("连接", symbol: "cable.connector",
                                               tooltip: "连接或断开 USB / 无线手机")
    private let backButton = toolbarButton("返回", symbol: "chevron.left",
                                            tooltip: "返回手机上一页")
    private let homeButton = toolbarButton("主屏幕", symbol: "house",
                                            tooltip: "回到手机主屏幕")
    private let appsButton = toolbarButton("应用列表", symbol: "square.grid.2x2", tooltip: "浏览手机应用并拖出独立窗口")
    private let pauseButton = NSButton(title: "暂停", target: nil, action: nil)
    private let statusLabel = text("未连接", size: 12, weight: .semibold)
    private let modeLabel = text("手机桌面", size: 10, weight: .medium,
                                 color: .secondaryLabelColor)
    private let detailLabel = text("请连接已开启 USB 调试的手机。", size: 11,
                                   color: .secondaryLabelColor)
    private let detailButton = NSButton(title: "详情", target: nil, action: nil)
    private let holder = PhoneAspectHolder()
    private let applicationPicker = PhoneApplicationPicker()
    private let background = PhoneWindowBackgroundView()
    private let permissionRow = NSStackView()
    private var connected = false
    private var busy = false
    private var permissionHelp = false
    private var detailsExpanded = false
    private var cameraActive = false
    private var phoneDesktopMode = false
    private var desktopOverlayAllowed = true
    private var isStandalone = false
    private var desktopOverlayRestore: (NSWindow.Level, NSWindow.CollectionBehavior)?

    var desktopCaptureRect: CGRect {
        guard let window, holder.phone.window === window,
              applicationPicker.isHidden else { return .zero }
        let phone = holder.phone
        // WeChat center-crops its portrait camera across the full display.
        // Capture the full phone rectangle; Android letterboxes into the sensor
        // so that this crop restores the desktop at 1:1 window scale.
        guard phone.bounds.width >= 100 else { return .zero }
        let local = phone.bounds
        let cached = window.convertToScreen(phone.convert(local, to: nil))
        return WindowCaptureGeometry.correctedCaptureRect(for: window, cachedRect: cached)
    }

    init(title: String = "手机镜像", standalone: Bool = false, scanner: Bool = false) {
        let visibleHeight = NSScreen.main?.visibleFrame.height ?? 740
        let initialHeight = min(690, max(500, visibleHeight - 30))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360,
                                                   height: initialHeight),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = title
        // Keep the native title bar and traffic lights in AppKit's own surface.
        window.titlebarAppearsTransparent = false
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.ignoresMouseEvents = false
        background.frame = window.contentView?.bounds ?? .zero
        window.contentView = background
        window.minSize = NSSize(width: 320, height: 530)
        window.center()
        super.init(window: window)
        isStandalone = standalone
        desktopOverlayAllowed = true
        setPhoneDesktopMode(!standalone)
        buildContent(in: window)
        if standalone {
            connectButton.isHidden = true
            homeButton.isHidden = true
            appsButton.isHidden = true
        }
        update(status: "未连接", detail: "请连接已开启 USB 调试的手机。",
               connected: false, busy: false, paused: true)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    private func buildContent(in window: NSWindow) {
        guard let content = window.contentView else { return }
        let toolbar = NSStackView(views: [connectButton, backButton, homeButton, appsButton])
        toolbar.orientation = .horizontal
        toolbar.distribution = .fill
        toolbar.spacing = 6

        connectButton.target = self; connectButton.action = #selector(connectPressed)
        backButton.target = self; backButton.action = #selector(backPressed)
        homeButton.target = self; homeButton.action = #selector(homePressed)
        appsButton.target = self; appsButton.action = #selector(applicationsPressed)
        pauseButton.target = self; pauseButton.action = #selector(pausePressed)
        pauseButton.font = .systemFont(ofSize: 11, weight: .medium)
        pauseButton.bezelStyle = .rounded
        pauseButton.imagePosition = .imageLeading
        pauseButton.toolTip = "暂停或继续桌面画面"
        pauseButton.setAccessibilityLabel("暂停或继续桌面画面")
        pauseButton.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let phone = holder.phone
        holder.applicationPicker = applicationPicker
        background.preview = phone
        holder.onLayout = { [weak self] in self?.background.needsDisplay = true }
        phone.wantsLayer = true
        phone.layer?.isOpaque = false
        phone.layer?.backgroundColor = NSColor.clear.cgColor
        phone.layer?.cornerRadius = 12
        phone.layer?.masksToBounds = true
        phone.setAccessibilityRole(.image)
        phone.setAccessibilityLabel("真实手机画面；点击或拖动可操作手机")
        phone.toolTip = "真实手机画面；点击、拖动或滚动可操作手机"
        phone.onTap = { [weak self] x, y in self?.onTap?(x, y) }
        phone.onSwipe = { [weak self] x1, y1, x2, y2 in
            self?.onSwipe?(x1, y1, x2, y2)
        }
        holder.heightAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true

        detailButton.isBordered = false
        detailButton.font = .systemFont(ofSize: 11)
        detailButton.target = self
        detailButton.action = #selector(toggleDetails)
        detailButton.toolTip = "展开或收起连接详情"
        detailButton.setAccessibilityLabel("展开或收起连接详情")
        detailButton.setContentHuggingPriority(.required, for: .horizontal)
        statusLabel.maximumNumberOfLines = 2
        detailLabel.maximumNumberOfLines = 4
        detailLabel.isHidden = true
        modeLabel.setContentHuggingPriority(.required, for: .horizontal)
        let statusRow = NSStackView(views: [statusLabel, modeLabel,
                                           detailButton, pauseButton])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 5
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let settings = button("屏幕录制设置", tooltip: "打开 macOS 屏幕录制权限设置")
        settings.font = .systemFont(ofSize: 11)
        settings.target = self; settings.action = #selector(permissionSettingsPressed)
        let relaunch = button("授权后重启", tooltip: "清理手机连接并重启 App，让权限生效")
        relaunch.font = .systemFont(ofSize: 11)
        relaunch.target = self; relaunch.action = #selector(relaunchPressed)
        permissionRow.orientation = .horizontal
        permissionRow.distribution = .fillEqually
        permissionRow.spacing = 8
        permissionRow.addArrangedSubview(settings)
        permissionRow.addArrangedSubview(relaunch)
        permissionRow.isHidden = true

        let footer = NSStackView(views: [statusRow, detailLabel, permissionRow])
        footer.orientation = .vertical
        footer.alignment = .width
        footer.spacing = 5
        let root = NSStackView(views: [toolbar, holder, footer])
        root.orientation = .vertical
        root.alignment = .width
        root.spacing = 8
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        let layout = window.contentLayoutGuide as? NSLayoutGuide ?? content.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: layout.topAnchor, constant: ViewStyle.inset),
            root.leadingAnchor.constraint(equalTo: layout.leadingAnchor, constant: ViewStyle.inset),
            root.trailingAnchor.constraint(equalTo: layout.trailingAnchor, constant: -ViewStyle.inset),
            root.bottomAnchor.constraint(equalTo: layout.bottomAnchor, constant: -ViewStyle.inset),
            toolbar.widthAnchor.constraint(equalTo: root.widthAnchor),
            holder.widthAnchor.constraint(equalTo: root.widthAnchor),
            footer.widthAnchor.constraint(equalTo: root.widthAnchor),
            statusRow.widthAnchor.constraint(equalTo: footer.widthAnchor),
            detailLabel.widthAnchor.constraint(equalTo: footer.widthAnchor),
            permissionRow.widthAnchor.constraint(equalTo: footer.widthAnchor)
        ])
    }

    func update(status: String, detail: String, connected: Bool, busy: Bool, paused: Bool) {
        self.connected = connected
        self.busy = busy
        statusLabel.stringValue = status
        detailLabel.stringValue = detail
        detailLabel.toolTip = detail
        if ["失败", "未完成", "未开启", "未打开", "中断", "错误", "权限", "需要", "等待"].contains(where: status.contains) {
            detailsExpanded = true
        } else if !permissionHelp {
            detailsExpanded = false
        }
        detailLabel.isHidden = !detailsExpanded
        detailButton.title = detailsExpanded ? "收起" : "详情"
        connectButton.title = ""
        connectButton.image = NSImage(systemSymbolName:connected ? "link" : (busy ? "xmark" : "cable.connector"),accessibilityDescription:nil)?
            .withSymbolConfiguration(.init(pointSize:17,weight:.medium))
        connectButton.imagePosition = .imageOnly
        connectButton.contentTintColor = connected ? .systemGreen : .labelColor
        connectButton.setAccessibilityLabel(connected ? "断开手机" : (busy ? "取消连接" : "连接手机"))
        connectButton.toolTip = connected ? "断开手机" : (busy ? "取消连接" : "通过 USB 或无线连接手机")
        connectButton.isEnabled = true
        for control in [backButton, homeButton, appsButton] {
            control.isEnabled = connected && !busy
        }
        pauseButton.isEnabled = connected && !busy && cameraActive && !permissionHelp
        pauseButton.isHidden = !cameraActive
        pauseButton.title = paused ? "继续" : "暂停"
        pauseButton.image = NSImage(systemSymbolName: paused ? "play" : "pause",
                                   accessibilityDescription: pauseButton.title)
    }

    func showPermissionHelp(_ visible: Bool) {
        permissionHelp = visible
        permissionRow.isHidden = !visible
        if visible {
            detailsExpanded = true
            detailLabel.isHidden = false
            detailButton.title = "收起"
            pauseButton.isEnabled = false
        }
    }

    func setCameraActive(_ active: Bool, paused: Bool = false) {
        setScannerFloating(active && !paused)
        cameraActive = active
        setMode(active ? "桌面相机" : (phoneDesktopMode ? "手机桌面" : "手机镜像"))
        pauseButton.isHidden = !active
        pauseButton.isEnabled = active && connected && !busy && !permissionHelp
        pauseButton.title = paused ? "继续" : "暂停"
        pauseButton.image = NSImage(systemSymbolName: paused ? "play" : "pause",
                                   accessibilityDescription: pauseButton.title)
        let action = paused ? "继续桌面相机" : "暂停桌面相机"
        pauseButton.setAccessibilityLabel(action)
        pauseButton.toolTip = action
    }

    func setMode(_ mode: String) {
        guard ["手机镜像", "手机桌面", "手机应用", "微信", "桌面相机"].contains(mode) else { return }
        let displayingPicker = applicationPicker.superview != nil && !applicationPicker.isHidden
        let displayedMode = displayingPicker ? "手机应用" :
            (phoneDesktopMode && mode == "手机镜像" ? "手机桌面" : mode)
        modeLabel.stringValue = displayedMode
        modeLabel.isHidden = statusLabel.stringValue == displayedMode ||
            (displayedMode == "桌面相机" && statusLabel.stringValue.contains("桌面相机"))
    }

    func setLocalScanReview(_ reviewing:Bool) {
        guard reviewing else{return}
        pauseButton.title="重新框选"
        pauseButton.image=NSImage(systemSymbolName:"viewfinder",accessibilityDescription:"重新框选")
        pauseButton.setAccessibilityLabel("重新框选桌面二维码")
        pauseButton.toolTip="重新打开透明扫码框"
    }

    func setPhoneDesktopMode(_ enabled: Bool) {
        phoneDesktopMode = enabled
        holder.phone.emptyMessage = enabled ? "连接后显示手机桌面" : "连接手机后显示真实手机画面"
        if applicationPicker.superview == nil || applicationPicker.isHidden {
            setMode(cameraActive ? "桌面相机" : "手机镜像")
        }
    }

    func showApplicationPicker(_ apps: [AndroidApplication],
                               onOpen: @escaping (AndroidApplication) -> Void,
                               onDetach: @escaping (AndroidApplication, NSPoint) -> Void) {
        guard !isStandalone else { return }
        applicationPicker.setApplications(apps)
        applicationPicker.onOpenApplication = onOpen
        applicationPicker.onDetachApplication = onDetach
        holder.phone.isHidden = true
        applicationPicker.isHidden = false
        holder.needsLayout = true
        setMode("手机应用")
    }

    func hideApplicationPicker() {
        guard !applicationPicker.isHidden else { return }
        applicationPicker.isHidden = true
        holder.phone.isHidden = false
        applicationPicker.onOpenApplication = nil
        applicationPicker.onDetachApplication = nil
        setMode(cameraActive ? "桌面相机" : (phoneDesktopMode ? "手机桌面" : "手机镜像"))
    }

    /// Any phone window can float while its own app uses the desktop camera.
    private func setScannerFloating(_ enabled: Bool) {
        if desktopOverlayAllowed, let window {
            if enabled, desktopOverlayRestore == nil {
                desktopOverlayRestore = (window.level, window.collectionBehavior)
                // Stay above the webpage when Stage Manager switches groups.
                window.collectionBehavior = [.canJoinAllApplications]
                window.level = .floating
            } else if !enabled, let previous = desktopOverlayRestore {
                window.level = previous.0
                window.collectionBehavior = previous.1
                desktopOverlayRestore = nil
            }
        }
    }

    /// Retained for older callers. The product always displays the complete
    /// Android frame; desktop imagery reaches the app through its camera feed.
    func setLocalScanPreview(_ enabled: Bool) {
        guard !enabled else { return }
        holder.phone.localScanPreview = false
        background.localScanPreview = false
    }

    /// Retained for older callers; the local aperture is no longer shown.
    func setLocalScanAperture(_ normalizedRect: CGRect) {
        guard ScanPreviewAperture.valid(normalizedRect) else { return }
        holder.phone.aperture = normalizedRect
        background.aperture = normalizedRect
        background.needsDisplay = true
    }

    func setPhoneImage(_ image: NSImage?) {
        holder.phone.setImage(image)
        if let image { updatePhoneSize(image.size) }
    }

    /// Direct mirror path: callers with decoded CGImages avoid NSImage wrapping/conversion.
    func setPhoneFrame(_ frame: CGImage?) {
        holder.phone.setFrame(frame)
        if let frame { updatePhoneSize(NSSize(width: frame.width, height: frame.height)) }
    }

    /// Native video path: retain/render decoder pixel buffers without making a CGImage.
    func setPhonePixelBuffer(_ pixels: CVPixelBuffer?) {
        holder.phone.setPixelBuffer(pixels)
        if let pixels {
            updatePhoneSize(NSSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels)))
        }
    }

    private func updatePhoneSize(_ size: NSSize) {
        let ratio = size.width / size.height
        guard ratio.isFinite, ratio > 0.25, ratio < 3,
              abs(ratio - holder.aspectRatio) > 0.015 else { return }
        holder.aspectRatio = ratio
        resizeForPhoneRatio(ratio)
    }

    private func resizeForPhoneRatio(_ ratio: CGFloat) {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let usable = screen.visibleFrame
        let chrome = window.frame.height - window.contentLayoutRect.height
        let phoneWidth = window.contentView!.bounds.width - ViewStyle.inset * 2
        window.contentView?.layoutSubtreeIfNeeded()
        let controlsHeight = holder.bounds.height > 0
            ? window.contentView!.bounds.height - holder.bounds.height : 100
        let desired = phoneWidth / ratio + controlsHeight + chrome
        let height = min(usable.height, max(window.minSize.height, desired))
        var frame = window.frame
        let top = frame.maxY
        frame.size.height = height
        frame.origin.y = max(usable.minY, min(top - height, usable.maxY - height))
        window.setFrame(frame, display: true, animate: false)
    }

    @objc private func connectPressed() {
        if connected || busy { onDisconnect?() } else { onConnect?() }
    }
    @objc private func pausePressed() { onPause?() }
    @objc private func backPressed() { onBack?() }
    @objc private func homePressed() { onHome?() }
    @objc private func applicationsPressed() { onApplications?() }
    @objc private func permissionSettingsPressed() { onPermissionSettings?() }
    @objc private func relaunchPressed() { onRelaunch?() }
    @objc private func toggleDetails() {
        detailsExpanded.toggle()
        detailLabel.isHidden = !detailsExpanded
        detailButton.title = detailsExpanded ? "收起" : "详情"
    }
}

private final class ScanCornersView: NSView {
    // The center remains visually transparent but consumes clicks. A click on
    // the QR behind the panel must not activate the browser or another app.
    override func mouseDown(with event: NSEvent) {}
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let rect = NSRect(x: 16, y: 16, width: 320, height: 320)
        let length: CGFloat = 29
        let path = NSBezierPath()
        path.lineWidth = 5
        path.lineCapStyle = .round
        for x in [rect.minX, rect.maxX] {
            for y in [rect.minY, rect.maxY] {
                let horizontal = x == rect.minX ? length : -length
                let vertical = y == rect.minY ? length : -length
                path.move(to: NSPoint(x: x + horizontal, y: y))
                path.line(to: NSPoint(x: x, y: y))
                path.line(to: NSPoint(x: x, y: y + vertical))
            }
        }
        ViewStyle.green.setStroke()
        path.stroke()
    }
}

private final class DragBar: NSView {
    var onDragBegan:(()->Void)?
    override func hitTest(_ point: NSPoint) -> NSView? {
        let target = super.hitTest(point)
        // Route text and non-control stack space through the same drag path;
        // actual buttons keep their native click behavior and keyboard focus.
        if target is NSTextField || target is NSStackView { return self }
        return target
    }

    override func mouseDown(with event: NSEvent) {
        onDragBegan?()
        window?.performDrag(with: event)
    }
}

private final class ScanFramePanel:NSPanel {
    var onCancel:(()->Bool)?
    override var canBecomeKey:Bool {true}
    override func cancelOperation(_ sender:Any?){_ = onCancel?()}
    override func performClose(_ sender:Any?){if onCancel?() != true {super.performClose(sender)}}
    override func close(){if onCancel?() != true {super.close()}}
}

final class ScanFrameController: NSWindowController, NSWindowDelegate {
    var onPause: (() -> Void)?
    var onRescan: (() -> Void)?
    var onClose: (() -> Void)?
    var onMoved: ((CGRect) -> Void)?

    private let pauseButton = button("暂停", tooltip: "暂停或继续扫码画面")
    private let rescanButton = button("再扫", tooltip: "重新扫描当前框内的二维码")
    private let closeButton = button("返回", tooltip: "返回真实手机应用")
    private let titleLabel = text("停稳后自动识别", size: 13, weight: .semibold, color: .white)
    private var paused = false

    var captureRect: CGRect {
        guard let frame = window?.frame else { return .zero }
        return CGRect(x: frame.minX + 16, y: frame.minY + 16,
                      width: 320, height: 320)
    }

    init() {
        let panel = ScanFramePanel(contentRect: NSRect(x: 0, y: 0, width: 352, height: 404),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        panel.title = "桌面扫码框"
        panel.collectionBehavior = [.canJoinAllApplications]
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.minSize = NSSize(width: 352, height: 404)
        panel.maxSize = NSSize(width: 352, height: 404)
        panel.center()
        super.init(window: panel)
        panel.delegate = self
        panel.onCancel = { [weak self] in
            guard let action=self?.onClose else{return false}
            action();return true
        }
        buildContent(in: panel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    private func buildContent(in panel: NSPanel) {
        let frame = ScanCornersView(frame: NSRect(x: 0, y: 0, width: 352, height: 404))
        frame.wantsLayer = true
        frame.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = frame

        let bar = DragBar(frame: NSRect(x: 0, y: 352, width: 352, height: 52))
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.95).cgColor
        bar.layer?.cornerRadius = 10
        bar.setAccessibilityLabel("拖动扫码框")
        bar.toolTip = "拖动这里，把透明框放在电脑二维码上"
        frame.addSubview(bar)
        bar.onDragBegan={ [weak self] in
            guard let self else{return};self.onMoved?(self.captureRect)
        }

        let title = titleLabel
        title.setAccessibilityLabel("停稳后自动识别")
        for control in [pauseButton, rescanButton, closeButton] {
            control.isBordered = false
            control.contentTintColor = .white
            control.font = .systemFont(ofSize: 12, weight: .medium)
            control.heightAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true
        }
        pauseButton.target = self
        pauseButton.action = #selector(pausePressed)
        rescanButton.target = self
        rescanButton.action = #selector(rescanPressed)
        closeButton.target = self
        closeButton.action = #selector(closePressed)
        let row = NSStackView(views: [title, pauseButton, rescanButton, closeButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -10),
            row.centerYAnchor.constraint(equalTo: bar.centerYAnchor)
        ])
    }

    func setPaused(_ value: Bool) {
        paused = value
        pauseButton.title = value ? "继续" : "暂停"
        pauseButton.setAccessibilityLabel(value ? "继续扫码画面" : "暂停扫码画面")
        pauseButton.toolTip = value ? "继续扫码画面" : "暂停扫码画面"
        setMessage(value ? "扫码已暂停":"停稳后自动识别")
    }

    func setMessage(_ message:String) {
        titleLabel.stringValue=message;titleLabel.setAccessibilityLabel(message)
    }

    func show() {
        window?.orderFrontRegardless()
        onMoved?(captureRect)
    }

    func show(near rect:CGRect) {
        guard let window else{return}
        let destination=AppWindowMotion.destination(for:window.frame,
            at:NSPoint(x:rect.midX,y:rect.midY),screens:NSScreen.screens.map(\.visibleFrame),
            fallback:NSScreen.main?.visibleFrame ?? window.frame)
        window.setFrame(destination,display:false)
        show()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else{return}
        window.alphaValue=0
        NSAnimationContext.runAnimationGroup { context in
            context.duration=0.16
            window.animator().alphaValue=1
        }
    }

    func windowDidMove(_ notification: Notification) { onMoved?(captureRect) }
    func windowWillMove(_ notification: Notification) {onMoved?(captureRect)}
    func windowShouldClose(_ sender:NSWindow)->Bool {
        guard let onClose else{return true}
        onClose();return false
    }

    @objc private func pausePressed() { onPause?() }
    @objc private func rescanPressed() { onRescan?() }
    @objc private func closePressed() { onClose?() }
}
