import AppKit
import CoreGraphics
import Foundation

// Draw a local, original scan symbol. It deliberately contains no third-party
// trademark and is not a QR code with a decodable payload.
private let canvas: CGFloat = 1024
private let green = CGColor(red: 0.035, green: 0.59, blue: 0.36, alpha: 1)
private let deepGreen = CGColor(red: 0.015, green: 0.40, blue: 0.28, alpha: 1)
private let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)

private func rounded(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

private func fill(_ context: CGContext, _ path: CGPath) {
    context.addPath(path)
    context.fillPath()
}

private func finder(_ context: CGContext, x: CGFloat, y: CGFloat) {
    context.setFillColor(deepGreen)
    fill(context, rounded(CGRect(x: x, y: y, width: 108, height: 108), radius: 10))
    context.setFillColor(white)
    fill(context, rounded(CGRect(x: x + 19, y: y + 19, width: 70, height: 70), radius: 5))
    context.setFillColor(deepGreen)
    fill(context, rounded(CGRect(x: x + 37, y: y + 37, width: 34, height: 34), radius: 4))
}

private func paint(_ context: CGContext) {
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)

    let base = rounded(CGRect(x: 48, y: 48, width: 928, height: 928), radius: 218)
    context.saveGState()
    context.addPath(base)
    context.clip()
    let colors = [green, deepGreen] as CFArray
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: colors, locations: [0, 1]) {
        context.drawLinearGradient(gradient, start: CGPoint(x: 90, y: 945),
                                   end: CGPoint(x: 930, y: 80), options: [])
    }
    context.restoreGState()

    // Four clear bracket corners remain recognizable at Finder icon sizes.
    context.setStrokeColor(white)
    context.setLineWidth(50)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    let low: CGFloat = 188
    let high: CGFloat = 836
    let run: CGFloat = 94
    for x in [low, high] {
        for y in [low, high] {
            let dx: CGFloat = x == low ? run : -run
            let dy: CGFloat = y == low ? run : -run
            context.move(to: CGPoint(x: x + dx, y: y))
            context.addLine(to: CGPoint(x: x, y: y))
            context.addLine(to: CGPoint(x: x, y: y + dy))
            context.strokePath()
        }
    }

    // A compact abstract code card; the phone and Mac workflow is suggested
    // by the scanning brackets rather than an actual copied QR image.
    context.setFillColor(white)
    fill(context, rounded(CGRect(x: 316, y: 316, width: 392, height: 392), radius: 48))
    finder(context, x: 352, y: 352)
    finder(context, x: 548, y: 352)
    finder(context, x: 352, y: 548)

    context.setFillColor(deepGreen)
    for tile in [
        CGRect(x: 552, y: 548, width: 38, height: 38),
        CGRect(x: 604, y: 548, width: 48, height: 38),
        CGRect(x: 552, y: 602, width: 38, height: 50),
        CGRect(x: 608, y: 610, width: 44, height: 42),
    ] {
        fill(context, rounded(tile, radius: 5))
    }
}

private func png(size: Int) throws -> Data {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(data: nil, width: size, height: size,
                                  bitsPerComponent: 8, bytesPerRow: size * 4,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw NSError(domain: "Icon", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Cannot create graphics context"])
    }
    context.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    paint(context)
    guard let image = context.makeImage(),
          let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        throw NSError(domain: "Icon", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "Cannot encode PNG"])
    }
    return data
}

let build = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    .appendingPathComponent("build", isDirectory: true)
let iconset = build.appendingPathComponent("AppIcon.iconset", isDirectory: true)
let output = build.appendingPathComponent("AppIcon.icns")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let variants: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, size) in variants {
    try png(size: size).write(to: iconset.appendingPathComponent(name), options: .atomic)
}

let tool = Process()
tool.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
tool.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try tool.run()
tool.waitUntilExit()
guard tool.terminationStatus == 0 else {
    throw NSError(domain: "Icon", code: 3,
                  userInfo: [NSLocalizedDescriptionKey: "iconutil failed: \(tool.terminationStatus)"])
}
print("Generated \(output.path)")
