import Foundation
import CoreGraphics
import CoreText
import CoreVideo

@main enum ScannerNavigationOCRTests {
    private enum Icon { case plus, magnifier, ellipsis, blank }
    static func require(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }
    }
    /// Fixed synthetic text only; this test never captures a screen or phone.
    static func fixture(scale: CGFloat = 1) -> CVPixelBuffer {
        let width = Int(720 * scale), height = Int(1280 * scale)
        var result: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &result)
        require(status == kCVReturnSuccess && result != nil, "Cannot create synthetic OCR pixels")
        let buffer = result!
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 36, nil)
        let black = CGColor(gray: 0, alpha: 1)
        let labels: [(String, CGFloat, CGFloat)] = [
            ("HOME", 50, 1110), ("MENU", 455, 1080),
            ("CENTER", 55, 600), ("SCANNER", 270, 78)
        ]
        for (text, x, y) in labels {
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): black
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(line, context)
        }
        return buffer
    }
    static func label(_ name: String, in result: [ScannerNavigationOCR.Text]) -> ScannerNavigationOCR.Text {
        guard let text = result.first(where: { $0.value.uppercased() == name }) else {
            fatalError("Synthetic label \(name) not recognized")
        }
        return text
    }
    static func samePosition(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 9) {
        require(abs(lhs.minX - rhs.minX) < tolerance && abs(lhs.minY - rhs.minY) < tolerance &&
                abs(lhs.width - rhs.width) < tolerance && abs(lhs.height - rhs.height) < tolerance,
                "ROI or input size remapped synthetic coordinates: \(lhs) versus \(rhs)")
    }
    private static func toolbar(width: Int, height: Int, dark: Bool,
                                top: Icon, bottom: Icon) -> CVPixelBuffer {
        var result: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: true,
             kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &result)
        require(status == kCVReturnSuccess && result != nil, "Cannot create synthetic toolbar")
        let buffer = result!
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue |
                CGBitmapInfo.byteOrder32Little.rawValue)!
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(CGColor(gray: dark ? 0.10 : 0.94, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setStrokeColor(CGColor(gray: dark ? 0.94 : 0.06, alpha: 1))
        context.setFillColor(CGColor(gray: dark ? 0.94 : 0.06, alpha: 1))
        let radius = CGFloat(width) * 0.0235
        context.setLineWidth(max(2, radius * 0.10))
        context.setLineCap(.round)
        for (row, icon) in [(CGFloat(38), top), (CGFloat(108), bottom)] {
            let x = CGFloat(width) * 665 / 720
            let y = CGFloat(height) * row / 1280
            switch icon {
            case .plus, .magnifier:
                context.strokeEllipse(in: CGRect(x: x - radius, y: y - radius,
                                               width: radius * 2, height: radius * 2))
                if icon == .plus {
                    context.move(to: CGPoint(x: x - radius * 0.47, y: y))
                    context.addLine(to: CGPoint(x: x + radius * 0.47, y: y))
                    context.move(to: CGPoint(x: x, y: y - radius * 0.47))
                    context.addLine(to: CGPoint(x: x, y: y + radius * 0.47))
                    context.strokePath()
                } else {
                    context.move(to: CGPoint(x: x + radius * 0.65, y: y + radius * 0.65))
                    context.addLine(to: CGPoint(x: x + radius * 1.35, y: y + radius * 1.35))
                    context.strokePath()
                }
            case .ellipsis:
                for offset in [-0.55, 0, 0.55] as [CGFloat] {
                    context.fillEllipse(in: CGRect(x: x + offset * radius - radius * 0.10,
                                                   y: y - radius * 0.10,
                                                   width: radius * 0.20, height: radius * 0.20))
                }
            case .blank: break
            }
        }
        return buffer
    }
    private static func homeWords() -> [ScannerNavigationOCR.Text] {
        [38, 108].map { y in
            ScannerNavigationOCR.Text(value: "微信", rect: CGRect(x: 338, y: y - 16, width: 52, height: 32))
        }
    }
    private static func expectPlus(_ pixels: CVPixelBuffer, near y: CGFloat?) throws {
        let found = try ScannerNavigationOCR.plusButton(in: pixels, homeWords: homeWords())
        if let y {
            require(found != nil && abs(found!.x - 665) <= 8 && abs(found!.y - y) <= 7,
                    "Did not select the verified plus row")
        } else {
            require(found == nil, "Guessed a plus where none exists")
        }
    }
    static func main() throws {
        for (width, height) in [(720, 1280), (1268, 2756), (1000, 1700)] {
            try expectPlus(toolbar(width: width, height: height, dark: false,
                                   top: .blank, bottom: .plus), near: 108)
            try expectPlus(toolbar(width: width, height: height, dark: false,
                                   top: .plus, bottom: .blank), near: 38)
            try expectPlus(toolbar(width: width, height: height, dark: false,
                                   top: .plus, bottom: .plus), near: 38)
            try expectPlus(toolbar(width: width, height: height, dark: false,
                                   top: .blank, bottom: .blank), near: nil)
            try expectPlus(toolbar(width: width, height: height, dark: false,
                                   top: .magnifier, bottom: .ellipsis), near: nil)
            try expectPlus(toolbar(width: width, height: height, dark: false,
                                   top: .magnifier, bottom: .plus), near: 108)
            try expectPlus(toolbar(width: width, height: height, dark: true,
                                   top: .blank, bottom: .plus), near: 108)
        }
        print("PASS synthetic plus pixels: upper/lower/both/absent/search/ellipsis/dark and source aspect ratios")
        if CommandLine.arguments.contains("--plus-only") { return }
        let pixels = fixture()
        let full = try ScannerNavigationOCR.recognize(pixels)
        let menu = try ScannerNavigationOCR.recognize(pixels, region: .menu)
        let scanner = try ScannerNavigationOCR.recognize(pixels, region: .scanner)
        for name in ["HOME", "MENU", "CENTER", "SCANNER"] { _ = label(name, in: full) }
        require(menu.count == 1 && menu[0].value == "MENU", "Menu ROI recognized labels outside the upper-right quadrant")
        require(scanner.count == 1 && scanner[0].value == "SCANNER", "Scanner ROI recognized labels outside the bottom 24 percent")
        let menuFull = label("MENU", in: full).rect
        let scannerFull = label("SCANNER", in: full).rect
        require(menuFull.midX > 450 && menuFull.midY < 250, "Synthetic upper-right label has wrong axis/origin")
        require(scannerFull.midY > 1150, "Synthetic bottom label has wrong axis/origin")
        samePosition(menuFull, label("MENU", in: menu).rect)
        samePosition(scannerFull, label("SCANNER", in: scanner).rect)
        let smaller = fixture(scale: 0.5)
        samePosition(menuFull, label("MENU", in: try ScannerNavigationOCR.recognize(smaller, region: .menu)).rect)
        samePosition(scannerFull, label("SCANNER", in: try ScannerNavigationOCR.recognize(smaller, region: .scanner)).rect)
        print("PASS actual Vision OCR on synthetic pixels: full/menu/scanner ROI exclusion, full-image coordinates and 720×1280 normalization across input sizes")
    }
}
