import AppKit
import CoreVideo

// Standalone dependency fakes: compile with AndroidApplication.swift,
// ApplicationLibrary.swift, DesktopCameraInput.swift and DetachedApplications.swift only. No real phone,
// mirror, adb, capture or network implementation is linked into this binary.
struct ScanError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
actor PhoneSession {
    struct Endpoint { let serial = "synthetic-phone" }
    private var block = false, fail = true,failLaunch=false
    private var gate: CheckedContinuation<Void, Never>?
    private(set) var started = false, closed = [Int]()
    func configure(block: Bool, fail: Bool) { self.block = block; self.fail = fail; started = false }
    func release() { gate?.resume(); gate = nil }
    func configureLaunchFailure() {failLaunch=true}
    func createAppDisplay() async throws -> AndroidAppDisplay {
        started = true
        if block { await withCheckedContinuation { gate = $0 } }
        if fail { throw ScanError("Synthetic display start failed") }
        return AndroidAppDisplay(id: 7, width: 1080, height: 1920, dpi: 420)
    }
    func mirrorEndpoint(display: Int) throws -> Endpoint { Endpoint() }
    func directMirror(display: Int) throws -> DirectMirrorDescriptor? { nil }
    func launchApplication(_ app: AndroidApplication, on display: Int) throws -> Bool {
        if failLaunch {throw DesktopCameraLaunchFailure(original:ScanError("Synthetic cleanup uncertainty"))};return true
    }
    func closeAppDisplay(_ display: Int) throws { closed.append(display) }
}
final class MirrorVideoMailbox: @unchecked Sendable {
    struct Frame { let pixelBuffer: CVPixelBuffer }
    func reset(generation: Int) {}
    func publish(_ pixels: CVPixelBuffer, generation: Int) {}
    func takeLatest() -> Frame? { nil }
    func stop() {}
}
final class MirrorSession: @unchecked Sendable {
    func touch(action: UInt8, x: Double, y: Double) {}
    func tap(x: Double, y: Double) {}
    func swipe(x1: Double, y1: Double, x2: Double, y2: Double) {}
    func key(_ value: Int) {}
    func startVideo(adbURL: URL, serverURL: URL, serial: String, displayID: Int, serverSocket: String?,
                    direct: DirectMirrorDescriptor?,
                    onFrame: @escaping @Sendable (CVPixelBuffer) -> Void,
                    onFailure: @escaping @Sendable (String) -> Void) async throws { try Task.checkCancellation() }
    func stop() async {}
}
@MainActor private final class SilentWindow: NSWindow {
    var presentations = 0
    override func makeKeyAndOrderFront(_ sender: Any?) { presentations += 1 }
    override func deminiaturize(_ sender: Any?) {}
}
@MainActor final class ControlWindowController: NSWindowController {
    static var created = [ControlWindowController]()
    var onTouch: ((UInt8, Double, Double) -> Void)?, onTap: ((Double, Double) -> Void)?
    var onSwipe: ((Double, Double, Double, Double) -> Void)?, onBack: (() -> Void)?
    var status = "", detail = ""
    init(title: String, standalone: Bool) {
        let window = SilentWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.ignoresMouseEvents = true; window.isReleasedWhenClosed = false
        super.init(window: window)
        Self.created.append(self)
    }
    required init?(coder: NSCoder) { fatalError("unavailable") }
    override func showWindow(_ sender: Any?) {}
    func update(status: String, detail: String, connected: Bool, busy: Bool, paused: Bool) { self.status = status; self.detail = detail }
    func setPhonePixelBuffer(_ pixels: CVPixelBuffer) {}
}

@main enum DetachedApplicationsTests {
    static func require(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
    @MainActor static func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() {
            guard Date() < deadline else { fatalError("Synthetic lifecycle timed out") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
    @MainActor static func main() async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        defer { for controller in ControlWindowController.created { controller.window?.orderOut(nil); controller.window?.close() } }
        let phone = PhoneSession()
        let manager = DetachedApplications(phone: phone, adb: URL(fileURLWithPath: "/synthetic/adb"), server: URL(fileURLWithPath: "/synthetic/server"))
        let app = AndroidApplication(packageName: "org.example.fixture", component: "org.example.fixture/.Main", name: "Fixture")
        require(manager.open(app, at: NSPoint(x: 600, y: 400)), "Open did not accept a valid app")
        let first = ControlWindowController.created[0]
        require((first.window as? SilentWindow)?.presentations == 1, "Pending window was not presented before phone work")
        try await waitUntil { first.status == "应用打开失败" }
        require(first.detail == "Synthetic display start failed", "Failure reason was lost")
        require(manager.open(app, at: nil) && ControlWindowController.created.count == 1, "Reopen duplicated a retained app")
        require((first.window as? SilentWindow)?.presentations == 2, "Existing failed window did not reveal again")
        require(manager.windowShouldClose(first.window!) == false, "Native close bypassed asynchronous cleanup")
        await phone.configure(block: true, fail: false)
        let reopenDeadline = Date().addingTimeInterval(3)
        while !manager.open(app, at: nil) {
            guard Date() < reopenDeadline else { fatalError("Closed entry remained stuck in map") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        require(ControlWindowController.created.count == 2, "Closed entry was incorrectly reused")
        let second = ControlWindowController.created[1]
        let startupDeadline = Date().addingTimeInterval(3)
        while !(await phone.started) {
            guard Date() < startupDeadline else { fatalError("Synthetic creation did not start") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        require(manager.windowShouldClose(second.window!) == false, "Pending close was not owned")
        require(!manager.open(app, at: nil), "Closing window incorrectly accepted another open request")
        await phone.release()
        let cleanupDeadline = Date().addingTimeInterval(3)
        while !(await phone.closed.contains(7)) {
            guard Date() < cleanupDeadline else { fatalError("Late-created display not cleaned") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        await manager.stop()
        let readyPhone=PhoneSession()
        await readyPhone.configure(block:false,fail:false)
        let readyManager=DetachedApplications(phone:readyPhone,adb:URL(fileURLWithPath:"/synthetic/adb"),server:URL(fileURLWithPath:"/synthetic/server"))
        require(readyManager.open(app,at:nil),"Ready fixture rejected app")
        require(readyManager.cameraWindows().isEmpty,"Pending app became a camera target")
        try await waitUntil{readyManager.cameraWindows().count==1}
        guard let readyWindow=readyManager.cameraWindows().first?.window.window else{fatalError("No ready camera target")}
        require(readyManager.windowShouldClose(readyWindow)==false && readyManager.cameraWindows().isEmpty,"Closing app remained a camera target")
        await readyManager.stop()
        let failedPhone=PhoneSession()
        await failedPhone.configure(block:false,fail:false);await failedPhone.configureLaunchFailure()
        let failedManager=DetachedApplications(phone:failedPhone,adb:URL(fileURLWithPath:"/synthetic/adb"),server:URL(fileURLWithPath:"/synthetic/server"))
        var failures=0
        failedManager.onCameraCleanupFailure={_ in failures+=1}
        require(failedManager.open(app,at:nil),"Failure fixture rejected app")
        try await waitUntil{failures==1}
        require(failedManager.cameraWindows().isEmpty,"Uncertain binding remained a camera target")
        await failedManager.stop()
        require(!manager.open(app, at: nil), "Stopped manager silently accepted an app")
        require(ControlWindowController.created.allSatisfy { $0.window?.isVisible == false }, "Probe ordered a window into shared UI")
        print("PASS pending presentation, failure feedback, reuse, asynchronous close, late display cleanup and stopped rejection; fake phone/mirror only; no ordered windows")
    }
}
