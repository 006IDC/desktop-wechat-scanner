import AppKit
import AVFoundation

@main enum PhoneApplicationPickerTests {
    private static func require(_ condition: Bool, _ message: String) {
        if !condition { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }

    @MainActor private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let matched = view as? T { return matched }
        return view.subviews.lazy.compactMap { find(type, in: $0) }.first
    }

    @MainActor private static func video(in view: NSView) -> NSView? {
        if view.layer?.sublayers?.contains(where: { $0 is AVSampleBufferDisplayLayer }) == true { return view }
        return view.subviews.lazy.compactMap { video(in: $0) }.first
    }

    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let wechat = AndroidApplication(packageName: "com.tencent.mm", component: "com.tencent.mm/.ui.LauncherUI", name: "微信")
        let alipay = AndroidApplication(packageName: "com.eg.android.AlipayGphone",
                                        component: "com.eg.android.AlipayGphone/.AlipayLogin", name: "支付宝")
        let picker = PhoneApplicationPicker()
        var opened: AndroidApplication?
        picker.onOpenApplication = { opened = $0 }
        picker.setApplications([wechat, alipay])
        require(picker.visibleApplications.count == 2, "Actual phone catalog was lost")
        let firstApp = picker.visibleApplications[0]
        picker.activateApplication(at: 0)
        require(opened == firstApp, "Open callback used a fabricated or wrong app")
        picker.activateApplication(at: 99)
        require(opened == firstApp, "Out-of-range app selection changed the target")
        let dragType = NSPasteboard.PasteboardType("com.idc006.phone-application")
        let dragItem = picker.collectionView(NSCollectionView(),
                                             pasteboardWriterForItemAt: IndexPath(item: 0, section: 0)) as? NSPasteboardItem
        require(dragItem?.string(forType: dragType) == firstApp.component,
                "Drag did not carry the selected phone application")
        guard let search = find(NSSearchField.self, in: picker) else { fatalError("Missing search") }
        search.stringValue = "微信"
        _ = search.sendAction(search.action, to: search.target)
        require(picker.visibleApplications == [wechat], "Search did not filter real catalog entries")
        search.stringValue = ""
        _ = search.sendAction(search.action, to: search.target)
        require(picker.visibleApplications.count == 2, "Clearing search did not restore catalog")

        let dragWindow = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 360, height: 540),
                                  styleMask: [.titled], backing: .buffered, defer: false)
        dragWindow.contentView?.addSubview(picker)
        defer { dragWindow.close() }
        var detached: [AndroidApplication] = []
        picker.onDetachApplication = { app, _ in detached.append(app) }
        let outside = NSPoint(x: dragWindow.frame.maxX + 20, y: dragWindow.frame.midY)
        picker.beginApplicationDrag(firstApp)
        picker.cancelApplicationDrag()
        picker.finishApplicationDrag(at: outside)
        require(detached.isEmpty, "Escape-cancelled picker drag opened an application")
        picker.beginApplicationDrag(firstApp)
        picker.finishApplicationDrag(at: outside, cancelledByEscape: true)
        require(detached.isEmpty, "Current Escape event was ignored by picker")
        picker.beginApplicationDrag(firstApp)
        picker.finishApplicationDrag(at: outside)
        require(detached == [firstApp], "Normal desktop drag did not detach the selected application")
        picker.beginApplicationDrag(firstApp)
        picker.removeFromSuperview()
        picker.finishApplicationDrag(at: outside)
        require(detached == [firstApp], "Removing picker left a drag that could open an application")

        let control = ControlWindowController()
        guard let window = control.window, let root = window.contentView,
              let phone = video(in: root), let embeddedPicker = find(PhoneApplicationPicker.self, in: root) else {
            fatalError("Main mirror was not built")
        }
        window.isReleasedWhenClosed = false
        defer { window.close() }
        require(embeddedPicker.isHidden && !phone.isHidden, "Phone mirror was hidden before fallback")
        control.showApplicationPicker([wechat, alipay], onOpen: { opened = $0 }, onDetach: { _, _ in })
        root.layoutSubtreeIfNeeded()
        require(!embeddedPicker.isHidden && phone.isHidden, "Fallback did not replace the unusable HOME surface")
        require(embeddedPicker.frame == phone.frame, "Picker did not occupy the real phone viewport")
        require(control.desktopCaptureRect == .zero, "Desktop capture remained available behind the picker")
        require(embeddedPicker.visibleApplications.count == 2, "Main picker did not receive actual phone catalog")
        let selectedApp = embeddedPicker.visibleApplications[1]
        embeddedPicker.activateApplication(at: 1)
        require(opened == selectedApp, "Main picker did not pass the selected phone app")
        control.hideApplicationPicker()
        require(embeddedPicker.isHidden && !phone.isHidden, "Hiding picker did not restore the live mirror")
        require(!window.isVisible && !NSApp.isActive, "UI test displayed or activated a window")
        print("PASS actual-catalog fallback, Escape-safe drag, app open, same-size phone overlay and mirror restoration")
    }
}
