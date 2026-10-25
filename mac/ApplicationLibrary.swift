import AppKit
import QuartzCore

/// Native drag-and-drop owns the gesture; no mouse polling or synthetic events.
@MainActor
final class ApplicationLibrary: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    var onOpen: ((AndroidApplication, NSPoint?) -> Void)?
    private let table = NSTableView(), search = NSSearchField(), message = NSTextField(wrappingLabelWithString: "正在读取手机应用…")
    private var apps: [AndroidApplication] = [], filtered: [AndroidApplication] = []
    private var drag = ApplicationDragIntent()
    private var cancellationMonitor: Any?
    private let dragType = NSPasteboard.PasteboardType("com.idc006.android-application")

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 390, height: 510),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "手机应用"; window.minSize = NSSize(width: 330, height: 350)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let header = NSTextField(wrappingLabelWithString: "拖出一个应用，在 Mac 上独立打开。也可双击或选中后点“打开”。")
        header.textColor = .secondaryLabelColor; header.font = .systemFont(ofSize: 12)
        search.placeholderString = "搜索手机应用"; search.delegate = self
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app")); column.title = "应用"
        table.addTableColumn(column); table.headerView = nil; table.rowHeight = 50
        table.dataSource = self; table.delegate = self; table.target = self; table.doubleAction = #selector(openSelected)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.setDraggingSourceOperationMask(.copy, forLocal: true)
        table.setAccessibilityLabel("手机应用，双击打开或拖到窗口外独立打开")
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let open = NSButton(title: "打开独立窗口", target: self, action: #selector(openSelected)); open.bezelStyle = .rounded
        open.keyEquivalent = "\r"
        message.font = .systemFont(ofSize: 11); message.textColor = .secondaryLabelColor
        let root = NSStackView(views: [header, search, scroll, message, open]); root.orientation = .vertical
        root.alignment = .leading; root.spacing = 12; root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 18),
            root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -18),
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 18),
            root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -18),
            header.widthAnchor.constraint(equalTo: root.widthAnchor), search.widthAnchor.constraint(equalTo: root.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: root.widthAnchor), message.widthAnchor.constraint(equalTo: root.widthAnchor)
        ])
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    func setApplications(_ value: [AndroidApplication]) { apps = value; filter() }
    func showError(_ detail: String) { message.stringValue = detail; message.textColor = .systemRed }
    func controlTextDidChange(_ notification: Notification) { filter() }
    private func filter() {
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        filtered = apps.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.packageName.localizedCaseInsensitiveContains(query) }
        table.reloadData(); message.stringValue = "\(filtered.count) 个应用 · 窗口使用手机上的同一个应用实例"
        message.textColor = .secondaryLabelColor
    }
    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard filtered.indices.contains(row) else { return nil }
        let item = filtered[row], title = NSTextField(labelWithString: item.name), subtitle = NSTextField(labelWithString: item.packageName)
        title.font = .systemFont(ofSize: 13, weight: .medium); subtitle.font = .systemFont(ofSize: 10)
        subtitle.textColor = .secondaryLabelColor
        let labels = NSStackView(views: [title, subtitle]); labels.orientation = .vertical; labels.alignment = .leading; labels.spacing = 3
        let icon = NSImageView(image: NSImage(systemSymbolName: "app", accessibilityDescription: nil)!)
        icon.contentTintColor = .controlAccentColor; icon.widthAnchor.constraint(equalToConstant: 30).isActive = true
        let row = NSStackView(views: [icon, labels]); row.spacing = 10; row.edgeInsets = NSEdgeInsets(top: 5, left: 7, bottom: 5, right: 7)
        return row
    }
    @objc private func openSelected() {
        guard filtered.indices.contains(table.selectedRow) else { return }
        requestOpen(filtered[table.selectedRow], at: nil)
    }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard filtered.indices.contains(row) else { return nil }
        let writer = NSPasteboardItem(); writer.setString(filtered[row].packageName, forType: dragType); return writer
    }
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes indexes: IndexSet) {
        removeCancellationMonitor()
        drag.begin(indexes.first.flatMap { filtered.indices.contains($0) ? filtered[$0] : nil },
                   at: ProcessInfo.processInfo.systemUptime)
        cancellationMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { MainActor.assumeIsolated { self?.drag.cancel() } }
            return event
        }
        session.animatesToStartingPositionsOnCancelOrFail = false
    }
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt point: NSPoint, operation: NSDragOperation) {
        removeCancellationMonitor()
        let event = NSApp.currentEvent
        let escape = event?.type == .keyDown && event?.keyCode == 53 && (event?.timestamp ?? 0) >= drag.beganAt
        // .none is also the normal result of releasing a private drag type on
        // the desktop. A successful .copy is not cancellation either. Global
        // key/button state can be stale while this delegate callback runs.
        guard let app = drag.finish(at: point, libraryFrame: window?.frame, cancelledByEscape: escape) else { return }
        requestOpen(app, at: point)
    }

    private func requestOpen(_ app: AndroidApplication, at point: NSPoint?) {
        guard let onOpen else { showError("当前无法打开应用，请重新连接手机后再试。"); return }
        onOpen(app, point)
    }
    private func removeCancellationMonitor() {
        if let cancellationMonitor { NSEvent.removeMonitor(cancellationMonitor) }
        cancellationMonitor = nil
    }
    func windowWillClose(_ notification: Notification) { drag.cancel(); removeCancellationMonitor() }
}

/// One native drag's intent, independent of AppKit's global current event or
/// the destination accepting this app-private pasteboard format.
struct ApplicationDragIntent {
    private var application: AndroidApplication?
    private var cancelled = false
    private(set) var beganAt: TimeInterval = 0
    mutating func begin(_ application: AndroidApplication?, at time: TimeInterval) {
        self.application = application; cancelled = false; beganAt = time
    }
    mutating func cancel() { cancelled = true }
    mutating func finish(at point: NSPoint, libraryFrame: NSRect?, cancelledByEscape: Bool = false) -> AndroidApplication? {
        defer { application = nil; cancelled = false }
        guard !cancelled, !cancelledByEscape, point.x.isFinite, point.y.isFinite,
              let libraryFrame, !libraryFrame.contains(point) else { return nil }
        return application
    }
}

enum AppWindowMotion {
    static func destination(for frame: NSRect, at point: NSPoint?, screens: [NSRect], fallback: NSRect) -> NSRect {
        let point = point.flatMap { $0.x.isFinite && $0.y.isFinite ? $0 : nil }
        let usable = screens.first(where: { $0.contains(point ?? frame.origin) }) ?? fallback
        var destination = frame
        if let point { destination.origin = NSPoint(x: point.x - destination.width / 2, y: point.y - destination.height / 2) }
        destination.origin.x = min(max(usable.minX, destination.minX), max(usable.minX, usable.maxX - destination.width))
        destination.origin.y = min(max(usable.minY, destination.minY), max(usable.minY, usable.maxY - destination.height))
        return destination
    }
    @MainActor static func reveal(_ window: NSWindow, from point: NSPoint?) {
        let destination = destination(for: window.frame, at: point, screens: NSScreen.screens.map(\.visibleFrame),
                                      fallback: NSScreen.main?.visibleFrame ?? window.frame)
        window.deminiaturize(nil)
        window.alphaValue = 1
        window.setFrame(destination, display: false)
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { window.makeKeyAndOrderFront(nil); return }
        let start = NSRect(x: destination.midX - destination.width * 0.46, y: destination.midY - destination.height * 0.46,
                           width: destination.width * 0.92, height: destination.height * 0.92)
        window.setFrame(start, display: false)
        window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22; context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().setFrame(destination, display: true)
        }
    }
}
