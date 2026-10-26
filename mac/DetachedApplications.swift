import AppKit

/// Each application owns a video/control stream and a native Mac window.
/// The authenticated virtual device is shared and outlives these windows.
@MainActor
final class DetachedApplications: NSObject, NSWindowDelegate {
    @MainActor private final class Entry {
        let app: AndroidApplication, ui: ControlWindowController
        let mirror = MirrorSession(), frames = MirrorVideoMailbox()
        var display: Int?, task: Task<Void, Never>?, closing = false
        init(_ app: AndroidApplication) {
            self.app = app; ui = ControlWindowController(title: app.name, standalone: true)
            frames.reset(generation: 1)
        }
    }
    var beforeClose: ((Int) async -> Void)?
    func cameraWindows() -> [(display:Int,window:ControlWindowController)] {
        entries.values.compactMap { entry in
            guard !entry.closing,let display=entry.display else{return nil}
            return (display,entry.ui)
        }
    }
    private let phone: PhoneSession, adb: URL, server: URL
    private let serverSocket: String?
    private var entries: [String: Entry] = [:], stopping = false
    init(phone: PhoneSession, adb: URL, server: URL, serverSocket: String? = nil) {
        self.phone = phone; self.adb = adb; self.server = server; self.serverSocket = serverSocket
    }

    @discardableResult func open(_ app: AndroidApplication, at point: NSPoint?) -> Bool {
        guard !stopping, app.isValid else { return false }
        if let existing = entries[app.packageName] {
            guard !existing.closing, let window = existing.ui.window else { return false }
            if NSApp.activationPolicy() != .prohibited { NSApp.activate(ignoringOtherApps: true) }
            existing.ui.showWindow(nil); AppWindowMotion.reveal(window, from: point); return true
        }
        guard entries.count < 4 else {
            let alert = NSAlert(); alert.messageText = "最多同时打开 4 个独立应用"; alert.informativeText = "请关闭一个应用窗口后再打开。"; alert.runModal(); return false
        }
        let entry = Entry(app); entries[app.packageName] = entry
        guard let window = entry.ui.window else { entries.removeValue(forKey: app.packageName); return false }
        window.isReleasedWhenClosed = false
        window.delegate = self
        entry.ui.onTouch = { [weak entry] action,x,y in
            guard let entry,!entry.closing,entry.display != nil else{return}
            entry.mirror.touch(action:action,x:x,y:y)
        }
        entry.ui.onTap = { [weak entry] x, y in guard let entry, !entry.closing, entry.display != nil else { return }; entry.mirror.tap(x: x, y: y) }
        entry.ui.onSwipe = { [weak entry] x1,y1,x2,y2 in guard let entry, !entry.closing else { return }; entry.mirror.swipe(x1:x1,y1:y1,x2:x2,y2:y2) }
        entry.ui.onBack = { [weak entry] in entry?.mirror.key(4) }
        entry.ui.update(status: "正在打开 \(app.name)", detail: "应用仍在手机运行，画面即将在这里出现。", connected: false, busy: true, paused: true)
        if NSApp.activationPolicy() != .prohibited { NSApp.activate(ignoringOtherApps: true) }
        entry.ui.showWindow(nil)
        AppWindowMotion.reveal(window, from: point)
        entry.task = Task { [weak self, entry] in
            guard let self else { return }
            do {
                let display = try await phone.createAppDisplay(); entry.display = display.id
                try Task.checkCancellation()
                let endpoint = try await phone.mirrorEndpoint(display: display.id)
                let direct=try await phone.directMirror(display:display.id)
                try Task.checkCancellation()
                try await entry.mirror.startVideo(adbURL: adb, serverURL: server, serial: endpoint.serial, displayID: display.id, serverSocket: serverSocket, direct: direct,
                    onFrame: { [frames=entry.frames] pixels in frames.publish(pixels, generation: 1) },
                    onFailure: { [weak entry] _ in Task { @MainActor in
                        guard let entry, !entry.closing else { return }
                        entry.ui.update(status: "画面连接中断", detail: "请关闭此窗口后重新打开应用。", connected: false, busy: false, paused: true)
                    } })
                try Task.checkCancellation(); try await phone.launchApplication(app, on: display.id)
                try Task.checkCancellation()
                guard !entry.closing, !stopping else { return }
                entry.ui.update(status: app.name, detail: "独立应用窗口 · 关闭后移回手机；黄色按钮使用系统程序坞动画。", connected: true, busy: false, paused: true)
            } catch {
                guard !entry.closing, !stopping else { return }
                await entry.mirror.stop()
                if let id = entry.display {
                    do { try await phone.closeAppDisplay(id); entry.display = nil }
                    catch { /* Keep ownership for the next close or disconnect recovery. */ }
                }
                entry.ui.update(status: "应用打开失败", detail: error.localizedDescription, connected: false, busy: false, paused: true)
            }
        }
        return true
    }
    func present() {
        for entry in entries.values where !entry.closing && entry.ui.window?.isMiniaturized != true {
            if let frame = entry.frames.takeLatest() { entry.ui.setPhonePixelBuffer(frame.pixelBuffer) }
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let entry = entries.values.first(where: { $0.ui.window === sender }), !entry.closing else { return false }
        entry.closing = true; entry.task?.cancel()
        entry.ui.update(status: "正在返回手机", detail: "正在收起这个应用窗口…", connected: false, busy: true, paused: true)
        Task { [self, entry] in
            if let id=entry.display {await beforeClose?(id)}
            await entry.mirror.stop(); await entry.task?.value
            do {
                if let id = entry.display { try await phone.closeAppDisplay(id) }
                entry.frames.stop(); entries.removeValue(forKey: entry.app.packageName); sender.orderOut(nil)
            } catch {
                entry.closing = false
                entry.ui.update(status: "收起未完成", detail: error.localizedDescription, connected: false, busy: false, paused: true)
            }
        }
        return false
    }
    func stop() async {
        stopping = true
        let current = Array(entries.values)
        for entry in current { entry.closing = true; entry.task?.cancel(); entry.frames.stop() }
        for entry in current {
            await entry.mirror.stop(); await entry.task?.value
            // PhoneSession.disconnect restores all owned displays together.
            entry.ui.window?.orderOut(nil)
        }
        entries.removeAll()
    }
}
