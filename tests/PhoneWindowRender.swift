import AppKit
import Foundation
import ScreenCaptureKit

// Visual regression helper for the production ControlWindowController.
// It captures only its own synthetic test window; never connects to a phone.
private enum RenderError: Error {
    case missingWindow
    case invalidCaptureRect
    case cannotCacheWindow
    case cannotEncodePNG
}

private func fill(_ rect: CGRect, color: NSColor, radius: CGFloat = 0) {
    color.setFill()
    if radius > 0 {
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    } else {
        rect.fill()
    }
}

private func label(_ value: String, x: CGFloat, y: CGFloat,
                   size: CGFloat, color: NSColor, bold: Bool = false) {
    (value as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [
        .font: NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular),
        .foregroundColor: color
    ])
}

private func samplePhone(width: Int, height: Int, scanner: Bool) -> NSImage {
    let dimensions = NSSize(width: width, height: height)
    return NSImage(size: dimensions, flipped: false) { _ in
        guard let context = NSGraphicsContext.current?.cgContext else { return false }
        let scale = CGFloat(width) / 720
        let h = CGFloat(height) / scale
        context.saveGState()
        context.scaleBy(x: scale, y: scale)

        if scanner {
            fill(CGRect(x: 0, y: 0, width: 720, height: h),
                 color: NSColor(calibratedRed: 0.09, green: 0.13, blue: 0.12, alpha: 1))
            fill(CGRect(x: 0, y: h - 112, width: 720, height: 112),
                 color: NSColor(calibratedRed: 0.13, green: 0.17, blue: 0.16, alpha: 1))
            label("9:41", x: 29, y: h - 38, size: 19, color: .white, bold: true)
            label("扫一扫", x: 296, y: h - 93, size: 31, color: .white, bold: true)
            let side: CGFloat = 540
            let center = CGPoint(x: 360, y: h * 0.51)
            fill(CGRect(x: center.x - side / 2, y: center.y - side / 2,
                        width: side, height: side),
                 color: NSColor(calibratedWhite: 0.20, alpha: 1), radius: 16)
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(10)
            context.setLineCap(.round)
            for x in [center.x - side / 2 + 22, center.x + side / 2 - 22] {
                for y in [center.y - side / 2 + 22, center.y + side / 2 - 22] {
                    let dx: CGFloat = x < center.x ? 62 : -62
                    let dy: CGFloat = y < center.y ? 62 : -62
                    context.move(to: CGPoint(x: x + dx, y: y))
                    context.addLine(to: CGPoint(x: x, y: y))
                    context.addLine(to: CGPoint(x: x, y: y + dy))
                    context.strokePath()
                }
            }
            label("将扫码窗口移到电脑二维码上", x: 168, y: h * 0.51 - 340,
                  size: 23, color: .white)
            label("仅用于窗口视觉检查 · 合成图像", x: 185, y: 115,
                  size: 17, color: NSColor(calibratedWhite: 0.70, alpha: 1))
        } else {
            fill(CGRect(x: 0, y: 0, width: 720, height: h),
                 color: NSColor(calibratedWhite: 0.96, alpha: 1))
            fill(CGRect(x: 0, y: h - 180, width: 720, height: 180),
                 color: NSColor(calibratedRed: 0.11, green: 0.62, blue: 0.40, alpha: 1))
            label("9:41", x: 28, y: h - 39, size: 19, color: .white, bold: true)
            label("手机镜像", x: 28, y: h - 132, size: 34, color: .white, bold: true)
            label("合成测试画面 · 不含手机数据", x: 28, y: h - 165,
                  size: 18, color: .white)
            for index in 0..<4 {
                let top = h - 235 - CGFloat(index) * 132
                fill(CGRect(x: 26, y: top - 92, width: 668, height: 106),
                     color: .white, radius: 17)
                fill(CGRect(x: 48, y: top - 63, width: 65, height: 65),
                     color: NSColor(calibratedRed: 0.86, green: 0.95, blue: 0.89, alpha: 1),
                     radius: 15)
                label(["测试应用", "桌面文件", "设置", "相机"][index],
                      x: 143, y: top - 43, size: 25, color: .black, bold: true)
                label("仅用于检查显示比例与布局", x: 143, y: top - 72,
                      size: 17, color: .darkGray)
            }
            fill(CGRect(x: 0, y: 0, width: 720, height: 95), color: .white)
            label("主屏幕", x: 315, y: 37, size: 19, color: .darkGray)
        }
        context.restoreGState()
        return true
    }
}

@MainActor
private func render(_ controller: ControlWindowController,
                    appearance: NSAppearance.Name, kind: String,
                    width: Int, height: Int, output: URL) async throws {
    guard let window = controller.window, let content = window.contentView else {
        throw RenderError.missingWindow
    }
    window.appearance = NSAppearance(named: appearance)
    let scanning = kind == "wechat"
    controller.setPhoneImage(samplePhone(width: width, height: height, scanner: scanning))
    controller.setCameraActive(scanning)
    controller.setMode(scanning ? "桌面相机" : "手机镜像")
    controller.update(status: scanning ? "正在扫码" : "已连接 · 测试手机",
                      detail: scanning ? "将此窗口移到电脑二维码上。" : "合成画面，仅供视觉回归。",
                      connected: true, busy: false, paused: !scanning)
    window.displayIfNeeded()
    content.layoutSubtreeIfNeeded()

    let target = controller.desktopCaptureRect
    guard target.width >= 100, abs(target.width - target.height) < 1,
          window.frame.contains(target) else {
        throw RenderError.invalidCaptureRect
    }
    try await Task.sleep(nanoseconds:350_000_000)
    let shareable=try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:true)
    guard let own=shareable.windows.first(where:{$0.windowID==CGWindowID(window.windowNumber)}) else{throw RenderError.missingWindow}
    let filter=SCContentFilter(desktopIndependentWindow:own)
    let configuration=SCStreamConfiguration()
    configuration.width=Int(window.frame.width*2);configuration.height=Int(window.frame.height*2)
    configuration.showsCursor=false;configuration.ignoreShadowsSingleWindow=true
    let image=try await SCScreenshotManager.captureImage(contentFilter:filter,configuration:configuration)
    let bitmap=NSBitmapImageRep(cgImage:image)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw RenderError.cannotEncodePNG
    }
    try png.write(to: output, options: .atomic)
    print("RENDERED \(output.path) window=\(window.frame) capture=\(target)")
}

@main
struct PhoneWindowRender {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let controller = ControlWindowController()
        controller.showWindow(nil)
        controller.window?.orderFrontRegardless()
        Task { @MainActor in
            do {
                let directory=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent(".local")
                try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
                for appearance:NSAppearance.Name in [.aqua,.darkAqua] {
                    let theme=appearance == .darkAqua ? "dark" : "light"
                    try await render(controller,appearance:appearance,kind:"physical",width:1268,height:2756,output:directory.appendingPathComponent("window-preview-\(theme)-physical.png"))
                    try await render(controller,appearance:appearance,kind:"wechat",width:720,height:1280,output:directory.appendingPathComponent("window-preview-\(theme)-wechat.png"))
                }
                exit(0)
            } catch {print("FAILED",error.localizedDescription);exit(1)}
        }
        withExtendedLifetime(controller){app.run()}
    }
}
