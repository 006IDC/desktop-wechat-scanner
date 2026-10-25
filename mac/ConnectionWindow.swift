import AppKit

@MainActor
private final class ConnectionDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// Modeless device selection. Network/process work stays in the connection
/// manager; closing cancels selection and invalidates pending UI completions.
/// Explicit connects remain owned until their bounded reply, then are cleaned.
@MainActor
final class ConnectionWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var onCancel: (() -> Void)?
    private let onSelect: (ADBDevice) -> Void
    private let manager: ADBConnectionManager
    private let adbURL: URL
    private var wirelessServer: ADBManagedServer?
    private var wirelessManager: ADBConnectionManager?
    private var wirelessLease: WirelessConnectionLease?
    private let serverHandoff = ADBWirelessServerHandoff()
    private var handedOffServerSocket: String?
    private var devices = [ADBDevice]()
    private var services = [ADBDiscoveredService]()
    private var task: Task<Void, Never>?
    private var cleanupTask: Task<Bool, Never>?
    private var handedOffSerial: String?
    private var generation = 0
    private var busy = false, closed = false, didSelect = false, didNotifyCancel = false

    private let table = NSTableView()
    private let pairEndpoint = NSTextField()
    private let pairingCode = NSSecureTextField()
    private let connectEndpoint = NSTextField()
    private let servicePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let status = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private let refreshButton = NSButton(title: "刷新设备", target: nil, action: nil)
    private let selectButton = NSButton(title: "连接所选手机", target: nil, action: nil)
    private let pairButton = NSButton(title: "配对", target: nil, action: nil)
    private let connectButton = NSButton(title: "建立无线连接", target: nil, action: nil)
    private let discoverButton = NSButton(title: "查找无线设备", target: nil, action: nil)

    init(adbURL: URL, onSelect: @escaping (ADBDevice) -> Void) {
        let manager = ADBConnectionManager(adbURL: adbURL)
        self.manager = manager
        self.adbURL = adbURL
        self.onSelect = onSelect
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 710),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "连接 Android 手机"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 640, height: 560)
        window.delegate = self
        buildContent(window)
        if let resource=Bundle.main.resourceURL,
           let data=try? Data(contentsOf:resource.appendingPathComponent("adb/manifest.json")),
           let manifest=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
           let features=manifest["features"] as? [String:Bool],features["mdns_discovery"]==false {
            discoverButton.isHidden=true;servicePicker.isHidden=true
        }
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        // A chooser owns one connection scope. App creates a new chooser for
        // another attempt, avoiding reconnect/cleanup races with a closed one.
        guard !closed else { return }
        guard !busy else { showWindow(nil); window?.makeKeyAndOrderFront(nil); return }
        closed = false; didSelect = false; didNotifyCancel = false
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        refreshDevices()
    }

    /// Call after close (including onSelect/onCancel) before App exit or another
    /// connection attempt. False means an exact-endpoint cleanup failed.
    func waitForCleanup() async -> Bool {
        guard let cleanupTask else { return true }
        return await cleanupTask.value
    }

    /// Only call after waitForCleanup. Taking transfers the sole runtime
    /// responsibility to App; an untaken server is stopped on deallocation.
    func takeSelectedWirelessServer() -> ADBManagedServer? {
        serverHandoff.take()
    }

    private func listedDevices() async throws -> [ADBDevice] {
        let defaults = try await manager.devices()
        guard let wirelessManager else { return defaults }
        return defaults + (try await wirelessManager.devices())
    }

    private func wirelessConnection(current: Int) async throws -> WirelessConnectionLease {
        if let wirelessLease { return wirelessLease }
        let server = try await ADBManagedServer.start(adbURL: adbURL)
        guard !Task.isCancelled, !closed, generation == current else {
            await server.stop(); throw CancellationError()
        }
        let manager = ADBConnectionManager(adbURL: adbURL, serverSocket: server.socket)
        let lease = WirelessConnectionLease(manager: manager)
        wirelessServer = server; wirelessManager = manager; wirelessLease = lease
        return lease
    }

    private func buildContent(_ window: NSWindow) {
        guard let content = window.contentView else { return }
        let title = NSTextField(labelWithString: "选择要连接的手机")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let intro = note("USB：连接并解锁手机，允许此 Mac 调试。无线：先在手机开启无线调试，手机与 Mac 需在同一网络。配对会保留此 Mac 的调试信任；可在手机无线调试的“已配对设备”中取消。")
        let deviceTitle = heading("可用设备")
        table.headerView = NSTableHeaderView()
        for (identifier, title, width) in [("model", "设备", 330.0), ("transport", "连接方式", 120.0), ("authorization", "状态", 150.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title; column.width = width
            table.addTableColumn(column)
        }
        table.rowHeight = 30
        table.usesAlternatingRowBackgroundColors = true
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.delegate = self; table.dataSource = self
        table.setAccessibilityLabel("Android 手机列表，请选择状态为已授权的设备")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: 150).isActive = true

        configure(refreshButton, action: #selector(refreshDevices))
        configure(selectButton, action: #selector(selectDevice))
        selectButton.keyEquivalent = "\r"
        let devicesActions = row([refreshButton, spacer(), selectButton])
        let chooseHint = note("无线连接建立后，请在上方列表中明确选择手机。未授权或离线的设备无法进入镜像。")

        pairEndpoint.placeholderString = "例如 192.168.1.20:37123"
        pairEndpoint.setAccessibilityLabel("配对地址与端口，来自手机配对码窗口")
        pairingCode.placeholderString = "六位配对码"
        pairingCode.setAccessibilityLabel("手机显示的六位配对码")
        pairingCode.widthAnchor.constraint(equalToConstant: 115).isActive = true
        configure(pairButton, action: #selector(pairWireless))
        let pairRow = row([pairEndpoint, pairingCode, pairButton])

        connectEndpoint.placeholderString = "例如 192.168.1.20:42567"
        connectEndpoint.setAccessibilityLabel("连接地址与端口，来自无线调试主页")
        configure(connectButton, action: #selector(connectWireless))
        let connectRow = row([connectEndpoint, connectButton])
        configure(discoverButton, action: #selector(discoverWireless))
        servicePicker.addItem(withTitle: "也可手动输入连接地址")
        servicePicker.target = self; servicePicker.action = #selector(serviceChosen)
        servicePicker.setAccessibilityLabel("发现的无线连接服务，选择后填入连接地址")
        servicePicker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let discoveryRow = row([servicePicker, discoverButton])

        let wireless = NSStackView(views: [
            note("首次使用：在手机“无线调试”中点“使用配对码配对设备”。支持 Android 11 或更高。"),
            heading("1. 配对地址与端口（配对码窗口）"), pairRow,
            note("配对码仅用于本次配对，提交或关闭窗口后立即从输入框清空。"),
            heading("2. 连接地址与端口（无线调试主页）"), connectRow,
            note("配对端口与连接端口通常不同。配对成功后，请回到无线调试主页查看连接端口。"),
            discoveryRow
        ])
        wireless.orientation = .vertical; wireless.alignment = .leading; wireless.spacing = 8
        fillWidth(wireless)
        let wirelessTitle = NSTextField(labelWithString: "无线调试")
        wirelessTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        let box = NSStackView(views: [wirelessTitle, wireless])
        box.orientation = .vertical; box.alignment = .leading; box.spacing = 12
        fillWidth(box)

        progress.style = .spinning; progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        progress.widthAnchor.constraint(equalToConstant: 18).isActive = true
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.setAccessibilityLabel("连接操作状态")
        status.heightAnchor.constraint(greaterThanOrEqualToConstant: 38).isActive = true
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelSelection))
        cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"
        let footer = row([progress, status, cancel])
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [title, intro, deviceTitle, scroll, devicesActions, chooseHint, box])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        let page = NSScrollView()
        page.hasVerticalScroller = true
        page.autohidesScrollers = true
        page.drawsBackground = false
        page.translatesAutoresizingMaskIntoConstraints = false
        let document = ConnectionDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        page.documentView = document
        content.addSubview(page)
        footer.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(footer)
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            page.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            page.topAnchor.constraint(equalTo: content.topAnchor),
            page.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            document.widthAnchor.constraint(equalTo: page.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -16)
        ])
        fillWidth(stack)
        updateEnabled()
        window.initialFirstResponder = table
    }

    private func configure(_ button: NSButton, action: Selector) {
        button.target = self; button.action = action; button.bezelStyle = .rounded
    }
    private func heading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        return label
    }
    private func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12); label.textColor = .secondaryLabelColor
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }
    private func spacer() -> NSView { NSView() }
    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal; stack.alignment = .centerY; stack.spacing = 8
        stack.distribution = .fill
        return stack
    }
    private func fillWidth(_ stack: NSStackView) {
        for view in stack.arrangedSubviews { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { devices.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard devices.indices.contains(row) else { return nil }
        let device = devices[row]
        let text: String
        switch tableColumn?.identifier.rawValue {
        case "transport":
            switch device.transport {
            case .usb: text = "USB"
            case .wireless: text = device.serverSocket == nil ? "无线" : "无线（本 App）"
            case .unknown: text = "其他 / 未知"
            }
        case "authorization":
            switch device.authorization {
            case .authorized: text = "已授权"
            case .unauthorized: text = "请在手机授权"
            case .offline: text = "离线"
            case .unavailable: text = "当前不可用"
            }
        default: text = "\(device.model ?? "Android 手机") · \(row + 1)"
        }
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingTail
        label.textColor = device.authorization == .authorized ? .labelColor : .secondaryLabelColor
        let cell = NSTableCellView()
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label); cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateEnabled() }

    private var selectedDevice: ADBDevice? {
        guard devices.indices.contains(table.selectedRow), devices[table.selectedRow].authorization == .authorized else { return nil }
        return devices[table.selectedRow]
    }
    private func updateEnabled() {
        for button in [refreshButton, pairButton, connectButton, discoverButton] { button.isEnabled = !busy }
        for field in [pairEndpoint, pairingCode, connectEndpoint] { field.isEnabled = !busy }
        servicePicker.isEnabled = !busy && !services.isEmpty
        table.isEnabled = !busy
        selectButton.isEnabled = !busy && selectedDevice != nil
        if busy { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
    }

    private func startOperation(_ message: String, operation: @escaping @MainActor (Int) async throws -> String) {
        guard !busy, !closed else { return }
        generation += 1
        let current = generation
        busy = true; status.stringValue = message; status.textColor = .secondaryLabelColor
        updateEnabled()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await operation(current)
                try Task.checkCancellation()
                guard !self.closed, self.generation == current else { return }
                self.status.stringValue = result
            } catch is CancellationError {
                guard !self.closed, self.generation == current else { return }
                self.status.stringValue = "操作已取消。"
            } catch {
                guard !self.closed, self.generation == current else { return }
                self.status.stringValue = error.localizedDescription
                self.status.textColor = .systemRed
            }
            guard !self.closed, self.generation == current else { return }
            self.busy = false; self.task = nil; self.updateEnabled()
        }
    }

    private func replaceDevices(_ result: [ADBDevice]) {
        devices = result; table.reloadData(); table.deselectAll(nil)
    }
    @objc private func refreshDevices() {
        startOperation("正在读取设备列表…") { [weak self] current in
            guard let self else { throw CancellationError() }
            let result = try await self.listedDevices()
            try Task.checkCancellation()
            guard !self.closed, self.generation == current else { throw CancellationError() }
            self.replaceDevices(result)
            return result.isEmpty ? "未发现设备。请连接 USB 或在下方建立无线连接，再刷新。" : "请选择一台已授权的手机，再点“连接所选手机”。"
        }
    }
    @objc private func pairWireless() {
        let endpoint = pairEndpoint.stringValue
        let code = pairingCode.stringValue
        pairingCode.stringValue = ""
        startOperation("正在无线配对…") { [weak self] _ in
            guard let self else { throw CancellationError() }
            try await self.manager.pair(endpoint: endpoint, code: code)
            return "配对成功。请从手机无线调试主页填写连接地址与端口，再建立无线连接。"
        }
    }
    @objc private func connectWireless() {
        let endpoint = connectEndpoint.stringValue
        startOperation("正在建立无线连接…") { [weak self] current in
            guard let self else { throw CancellationError() }
            _ = try ADBEndpoint(endpoint)
            let lease = try await self.wirelessConnection(current: current)
            try await lease.connect(endpoint: endpoint)
            let result = try await self.listedDevices()
            try Task.checkCancellation()
            guard !self.closed, self.generation == current else { throw CancellationError() }
            self.replaceDevices(result)
            return "无线连接已建立。请在上方明确选择一台已授权的手机。"
        }
    }
    @objc private func discoverWireless() {
        startOperation("正在查找无线连接服务…") { [weak self] current in
            guard let self else { throw CancellationError() }
            let found = try await self.manager.discover().filter { $0.kind == .connection }
            try Task.checkCancellation()
            guard !self.closed, self.generation == current else { throw CancellationError() }
            self.services = found
            self.servicePicker.removeAllItems()
            self.servicePicker.addItem(withTitle: "选择一个连接地址…")
            for service in found { self.servicePicker.addItem(withTitle: service.endpoint) }
            return found.isEmpty ? "未发现无线连接服务，可直接填写手机显示的连接地址与端口。" : "请选择发现的连接地址，核对后点“建立无线连接”。"
        }
    }
    @objc private func serviceChosen() {
        let index = servicePicker.indexOfSelectedItem - 1
        guard !busy, services.indices.contains(index) else { return }
        connectEndpoint.stringValue = services[index].endpoint
    }
    @objc private func selectDevice() {
        guard !busy, !closed, let device = selectedDevice else { return }
        didSelect = true
        handedOffSerial = device.serial
        handedOffServerSocket = device.serverSocket
        window?.close()
        onSelect(device)
    }
    @objc private func cancelSelection() { window?.close() }
    func windowWillClose(_ notification: Notification) {
        closed = true; generation += 1
        let pendingOperation = task
        pendingOperation?.cancel(); task = nil
        if cleanupTask == nil {
            cleanupTask = Task { [self] in
                // Also settle enumeration/pairing/discovery process shutdown,
                // including a connect preflight that had not acquired a lease.
                await pendingOperation?.value
                let server = wirelessServer
                let transfer = server != nil && server?.socket == handedOffServerSocket
                let succeeded = await wirelessLease?.close(keeping: transfer ? handedOffSerial : nil) ?? true
                if transfer { serverHandoff.finish(with: server) }
                else { await server?.stop() }
                wirelessServer = nil; wirelessManager = nil; wirelessLease = nil
                return succeeded
            }
        }
        pairingCode.stringValue = ""
        busy = false; progress.stopAnimation(nil)
        guard !didSelect, !didNotifyCancel else { return }
        didNotifyCancel = true
        onCancel?()
    }
}
