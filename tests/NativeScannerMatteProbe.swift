import AppKit
import CoreImage
import CoreVideo

/// Explicit in-memory device probe. Never writes phone pixels or OCR text.
/// A gray observation tests the two-background model independently of its fit.
enum NativeScannerMatteProbe {
    struct InvalidSample: Error {}
    static func solid(_ brightness: Double) throws -> Data {
        let extent = CGRect(x: 0, y: 0, width: 720, height: 1280)
        guard brightness.isFinite, (0...1).contains(brightness),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 720, height: 1280, bitsPerComponent: 8,
                bytesPerRow: 720 * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw InvalidSample() }
        context.setFillColor(red: brightness, green: brightness, blue: brightness, alpha: 1)
        context.fill(extent)
        guard let cg = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: cg).representation(using: .jpeg,
                properties: [.compressionFactor: 1.0]) else { throw InvalidSample() }
        return data
    }
    static func blue() throws -> Data {
        let extent = CGRect(x: 0, y: 0, width: 720, height: 1280)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 720, height: 1280, bitsPerComponent: 8,
                bytesPerRow: 720 * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw InvalidSample() }
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1); context.fill(extent)
        guard let cg = context.makeImage(), let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { throw InvalidSample() }
        return data
    }
    static let width = 180, height = 320
    static func sample(_ pixels: CVPixelBuffer) throws -> [UInt8] {
        guard CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(pixels, .readOnly) == kCVReturnSuccess else { throw InvalidSample() }
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels)?.assumingMemoryBound(to: UInt8.self) else { throw InvalidSample() }
        let w = CVPixelBufferGetWidth(pixels), h = CVPixelBufferGetHeight(pixels)
        let row = CVPixelBufferGetBytesPerRow(pixels)
        guard w >= width, h >= height else { throw InvalidSample() }
        var output = [UInt8](); output.reserveCapacity(width * height * 3)
        for y in 0..<height { for x in 0..<width {
            let offset = min(h - 1, y * h / height) * row + min(w - 1, x * w / width) * 4
            output.append(contentsOf: [base[offset], base[offset + 1], base[offset + 2]])
        }}
        return output
    }
    static func median(_ images: [[UInt8]]) throws -> [UInt8] {
        guard images.count == 3, images.allSatisfy({ $0.count == width * height * 3 }) else { throw InvalidSample() }
        return (0..<images[0].count).map { i in
            let a = images[0][i], b = images[1][i], c = images[2][i]
            return max(min(a, b), min(max(a, b), c))
        }
    }
    // Numeric coverage only; never persists pixels or text from the phone.
    static func coverage(source: CVPixelBuffer, output: CGImage) throws -> [[String: Any]] {
        let input = try sample(source)
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        let reduced = CIImage(cgImage: output, options: [.colorSpace: NSNull()]).transformed(by:
            CGAffineTransform(scaleX: Double(width) / Double(output.width), y: Double(height) / Double(output.height)))
        rgba.withUnsafeMutableBytes {
            context.render(reduced, toBitmap: $0.baseAddress!, rowBytes: width * 4,
                bounds: CGRect(x: 0,y: 0,width: width,height: height), format: .RGBA8, colorSpace: nil)
        }
        return [("upper",0,80),("middle",80,240),("lower",240,320)].map { name,top,bottom in
            var alpha = 0.0, nearClear = 0, blue = 0.0, red = 0.0, green = 0.0
            let total = (bottom-top)*width
            for y in top..<bottom { for x in 0..<width {
                let i = y*width+x
                alpha += Double(rgba[i*4+3])/255
                if rgba[i*4+3] < 32 { nearClear += 1 }
                blue += Double(input[i*3])/255; green += Double(input[i*3+1])/255; red += Double(input[i*3+2])/255
            }}
            return ["band":name,"alphaMean":alpha/Double(total),"nearClearFraction":Double(nearClear)/Double(total),
                    "sourceBlueMean":blue/Double(total),"sourceGreenMean":green/Double(total),"sourceRedMean":red/Double(total)]
        }
    }
    static func analyse(black: [UInt8], white: [UInt8], gray: [UInt8]) throws -> [String: Any] {
        guard black.count == width * height * 3, black.count == white.count, black.count == gray.count else { throw InvalidSample() }
        var bands = [[String: Any]]()
        for (name, top, bottom) in [("upper", 0, 80), ("middle", 80, 240), ("lower", 240, 320)] {
            var errors = [Double](), transmitted = 0, violated = 0, total = 0
            var bSum = 0.0, wSum = 0.0, gSum = 0.0
            for y in top..<bottom { for x in 0..<width {
                let i = (y * width + x) * 3
                let b = (0..<3).map { Double(black[i + $0]) / 255 }
                let w = (0..<3).map { Double(white[i + $0]) / 255 }
                let g = (0..<3).map { Double(gray[i + $0]) / 255 }
                let delta = zip(w, b).map(-)
                let t = delta.sorted()[1]
                total += 1
                if t > 0.15 { transmitted += 1 }
                if delta.min()! < -0.04 || delta.max()! - delta.min()! > 0.10 { violated += 1 }
                errors.append((0..<3).map { abs(g[$0] - (b[$0] + 0.5 * t)) }.max()!)
                bSum += b.reduce(0,+) / 3; wSum += w.reduce(0,+) / 3; gSum += g.reduce(0,+) / 3
            }}
            errors.sort()
            bands.append(["band": name, "transmittingFraction": Double(transmitted) / Double(total),
                "nonMatteFraction": Double(violated) / Double(total), "grayErrorMean": errors.reduce(0,+) / Double(total),
                "grayErrorP95": errors[Int(Double(errors.count - 1) * 0.95)],
                "blackMean": bSum / Double(total), "whiteMean": wSum / Double(total), "grayMean": gSum / Double(total)])
        }
        let modelSupported = bands.allSatisfy {
            ($0["grayErrorP95"] as? Double ?? 1) < 0.08 &&
            ($0["nonMatteFraction"] as? Double ?? 1) < 0.08
        } && (bands[1]["transmittingFraction"] as? Double ?? 0) > 0.5
        return ["modelSupported": modelSupported, "bands": bands, "sampleWidth": width, "sampleHeight": height, "model": "observedGray=black+0.5*median(white-black)"]
    }
}
