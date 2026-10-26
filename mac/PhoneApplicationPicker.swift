import AppKit

/// A native fallback for phones whose virtual display has no usable HOME UI.
/// Every entry comes from the connected phone's application catalog.
final class PhoneApplicationPicker: NSView, NSCollectionViewDataSource, NSCollectionViewDelegate {
    private final class ApplicationCollectionView: NSCollectionView {
        var onActivateItem: ((Int) -> Void)?
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2,
               let item = indexPathForItem(at: convert(event.locationInWindow, from: nil))?.item {
                onActivateItem?(item)
                return
            }
            super.mouseDown(with: event)
        }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 36 || event.keyCode == 76,
               let item = selectionIndexPaths.first?.item {
                onActivateItem?(item)
                return
            }
            super.keyDown(with: event)
        }
    }

    private final class ApplicationItem: NSCollectionViewItem {
        static let identifier = NSUserInterfaceItemIdentifier("PhoneApplicationItem")
        private let icon = NSImageView()
        private let titleLabel = NSTextField(labelWithString: "")
        private let openButton = NSButton(title: "打开", target: nil, action: nil)
        var onOpen: (() -> Void)?

        override func loadView() {
            let surface = NSView()
            surface.wantsLayer = true
            surface.layer?.cornerRadius = 9
            surface.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            icon.image = NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil)
            icon.contentTintColor = .secondaryLabelColor
            icon.imageScaling = .scaleProportionallyDown
            titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
            titleLabel.lineBreakMode = .byTruncatingTail
            titleLabel.maximumNumberOfLines = 1
            openButton.bezelStyle = .rounded
            openButton.font = .systemFont(ofSize: 11)
            openButton.target = self
            openButton.action = #selector(openPressed)
            for child in [icon, titleLabel, openButton] {
                child.translatesAutoresizingMaskIntoConstraints = false
                surface.addSubview(child)
            }
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 12),
                icon.centerYAnchor.constraint(equalTo: surface.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 24),
                icon.heightAnchor.constraint(equalToConstant: 24),
                titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
                titleLabel.centerYAnchor.constraint(equalTo: surface.centerYAnchor),
                titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: openButton.leadingAnchor, constant: -8),
                openButton.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -10),
                openButton.centerYAnchor.constraint(equalTo: surface.centerYAnchor),
                openButton.widthAnchor.constraint(equalToConstant: 48)
            ])
            view = surface
        }

        func configure(_ app: AndroidApplication, onOpen: @escaping () -> Void) {
            titleLabel.stringValue = app.name
            openButton.toolTip = "打开 \(app.name)"
            openButton.setAccessibilityLabel("打开 \(app.name)")
            view.setAccessibilityLabel(app.name)
            self.onOpen = onOpen
        }

        @objc private func openPressed() { onOpen?() }
    }

    var onOpenApplication: ((AndroidApplication) -> Void)?
    var onDetachApplication: ((AndroidApplication, NSPoint) -> Void)?
    private(set) var visibleApplications: [AndroidApplication] = []
    private var allApplications: [AndroidApplication] = []
    private var drag = ApplicationDragIntent()
    private var cancellationMonitor: Any?
    private let search = NSSearchField()
    private let collection = ApplicationCollectionView()
    private let scroll = NSScrollView()
    private let flow = NSCollectionViewFlowLayout()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let heading = NSTextField(labelWithString: "手机应用")
        heading.font = .systemFont(ofSize: 19, weight: .semibold)
        let explanation = NSTextField(wrappingLabelWithString: "当前小米副屏桌面未正常显示，选择应用后显示真实手机画面。")
        explanation.font = .systemFont(ofSize: 11)
        explanation.textColor = .secondaryLabelColor
        explanation.maximumNumberOfLines = 3
        search.placeholderString = "搜索手机应用"
        search.setAccessibilityLabel("搜索手机应用")
        search.target = self
        search.action = #selector(searchChanged)
        search.sendsSearchStringImmediately = true
        search.sendsWholeSearchString = false

        flow.minimumInteritemSpacing = 0
        flow.minimumLineSpacing = 6
        flow.sectionInset = NSEdgeInsets(top: 2, left: 0, bottom: 8, right: 0)
        flow.itemSize = NSSize(width: 260, height: 52)
        collection.collectionViewLayout = flow
        collection.dataSource = self
        collection.delegate = self
        collection.onActivateItem = { [weak self] item in self?.activateApplication(at: item) }
        collection.isSelectable = true
        collection.register(ApplicationItem.self, forItemWithIdentifier: ApplicationItem.identifier)
        collection.setDraggingSourceOperationMask(.copy, forLocal: false)
        collection.setDraggingSourceOperationMask(.copy, forLocal: true)
        collection.autoresizingMask = [.width]
        collection.frame = NSRect(x: 0, y: 0, width: 260, height: 300)
        scroll.documentView = collection
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        for child in [heading, explanation, search, scroll] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            heading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            heading.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            explanation.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 6),
            explanation.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            explanation.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            search.topAnchor.constraint(equalTo: explanation.bottomAnchor, constant: 16),
            search.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            search.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        ])
        setAccessibilityRole(.group)
        setAccessibilityLabel("手机应用选择器")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            drag.cancel()
            removeCancellationMonitor()
        }
    }

    override func layout() {
        super.layout()
        let width = max(100, scroll.contentSize.width - 2)
        if abs(flow.itemSize.width - width) > 1 {
            flow.itemSize = NSSize(width: width, height: 52)
            flow.invalidateLayout()
        }
    }

    func setApplications(_ apps: [AndroidApplication]) {
        allApplications = apps.filter(\.isValid).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        applyFilter()
    }

    @objc private func searchChanged() { applyFilter() }

    private func applyFilter() {
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        visibleApplications = query.isEmpty ? allApplications : allApplications.filter {
            $0.name.localizedStandardContains(query) || $0.packageName.localizedStandardContains(query)
        }
        collection.reloadData()
    }

    func activateApplication(at index: Int) {
        guard visibleApplications.indices.contains(index) else { return }
        onOpenApplication?(visibleApplications[index])
    }

    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        visibleApplications.count
    }
    func collectionView(_ collectionView: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: ApplicationItem.identifier, for: indexPath)
        guard let appItem = item as? ApplicationItem, visibleApplications.indices.contains(indexPath.item) else { return item }
        let app = visibleApplications[indexPath.item]
        appItem.configure(app) { [weak self] in self?.onOpenApplication?(app) }
        return appItem
    }

    func collectionView(_ collectionView: NSCollectionView,
                        pasteboardWriterForItemAt indexPath: IndexPath) -> (any NSPasteboardWriting)? {
        guard visibleApplications.indices.contains(indexPath.item) else { return nil }
        let pasteboard = NSPasteboardItem()
        pasteboard.setString(visibleApplications[indexPath.item].component,
                             forType: NSPasteboard.PasteboardType("com.idc006.phone-application"))
        return pasteboard
    }

    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession,
                        willBeginAt screenPoint: NSPoint, forItemsAt indexPaths: Set<IndexPath>) {
        let app = indexPaths.count == 1 ? indexPaths.first.flatMap {
            visibleApplications.indices.contains($0.item) ? visibleApplications[$0.item] : nil
        } : nil
        beginApplicationDrag(app)
        session.animatesToStartingPositionsOnCancelOrFail = false
    }

    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession,
                        endedAt screenPoint: NSPoint, dragOperation operation: NSDragOperation) {
        let event = NSApp.currentEvent
        let escape = event?.type == .keyDown && event?.keyCode == 53 && (event?.timestamp ?? 0) >= drag.beganAt
        finishApplicationDrag(at: screenPoint, cancelledByEscape: escape)
    }

    func beginApplicationDrag(_ app: AndroidApplication?, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        removeCancellationMonitor()
        drag.begin(app, at: time)
        guard app != nil else { return }
        cancellationMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { MainActor.assumeIsolated { self?.drag.cancel() } }
            return event
        }
    }

    func cancelApplicationDrag() { drag.cancel() }

    func finishApplicationDrag(at point: NSPoint, cancelledByEscape: Bool = false) {
        removeCancellationMonitor()
        guard let app = drag.finish(at: point, libraryFrame: window?.frame,
                                    cancelledByEscape: cancelledByEscape) else { return }
        onDetachApplication?(app, point)
    }

    private func removeCancellationMonitor() {
        if let cancellationMonitor { NSEvent.removeMonitor(cancellationMonitor) }
        cancellationMonitor = nil
    }
}
