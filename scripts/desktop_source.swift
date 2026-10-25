// A deliberately narrow desktop source for the QR compatibility experiment.
// Only this process's newly created NSWindow is passed to ScreenCaptureKit.
import AppKit
import ScreenCaptureKit
import Foundation

@MainActor
func captureOwnWindow(_ window: NSWindow, output: URL) async throws {
    guard #available(macOS 14.4, *) else {
        throw NSError(domain: "DesktopQRSource", code: 4,
                      userInfo: [NSLocalizedDescriptionKey: "本工具需要 macOS 14.4 或更新版本"])
    }
    guard window.windowNumber > 0 else {
        throw NSError(domain: "DesktopQRSource", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "测试窗口尚未创建"])
    }
    let ownWindowID = CGWindowID(window.windowNumber)

    // Let AppKit paint the QR into its actual desktop window before capturing.
    try await Task.sleep(nanoseconds: 800_000_000)

    // currentProcess returns only this process's content on macOS 14.4+.
    // Never substitute a display filter or another process's window here.
    let content = try await SCShareableContent.currentProcess
    guard let source = content.windows.first(where: { $0.windowID == ownWindowID }) else {
        throw NSError(domain: "DesktopQRSource", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "未找到本工具的窗口（ID \(ownWindowID)）；请保持窗口可见"])
    }

    let filter = SCContentFilter(desktopIndependentWindow: source)
    let config = SCStreamConfiguration()
    config.width = max(1, Int(source.frame.width * window.backingScaleFactor))
    config.height = max(1, Int(source.frame.height * window.backingScaleFactor))
    config.showsCursor = false
    let pixels = try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                             configuration: config)
    let bitmap = NSBitmapImageRep(cgImage: pixels)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "DesktopQRSource", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "无法编码窗口截图为 PNG"])
    }
    try png.write(to: output, options: .atomic)
    print("CAPTURED window_id=\(ownWindowID) path=\(output.path)")
    fflush(stdout)
}

guard CommandLine.arguments.count == 3 else {
    fputs("用法: desktop-source <已生成的 QR PNG> <输出的窗口截图 PNG>\n", stderr)
    exit(2)
}

let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
guard sourceURL != outputURL, let qr = NSImage(contentsOf: sourceURL) else {
    fputs("输入必须是可读取的 QR 图像，且输出路径不能与输入相同。\n", stderr)
    exit(2)
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let side: CGFloat = 600
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: side, height: side),
                      styleMask: [.borderless], backing: .buffered, defer: false)
window.title = "006IDC QR capture source"
window.backgroundColor = .white
window.isOpaque = true
window.center()
let qrView = NSImageView(frame: NSRect(x: 0, y: 0, width: side, height: side))
qrView.image = qr
qrView.imageScaling = .scaleProportionallyUpOrDown
window.contentView = qrView
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)

Task { @MainActor in
    do {
        try await captureOwnWindow(window, output: outputURL)
        try await Task.sleep(nanoseconds: 2_000_000_000)
        app.terminate(nil)
    } catch {
        fputs("窗口采集失败：\(error.localizedDescription)\n", stderr)
        fputs("若系统提示屏幕录制权限，请在 macOS「系统设置 → 隐私与安全性 → 屏幕与系统音频录制」允许运行本工具的终端或 Codex，然后重试。\n", stderr)
        exit(1)
    }
}

app.run()
