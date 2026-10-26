import Foundation
import CoreGraphics
import CoreText
import CoreVideo

@main enum ScannerNavigationOCRTests {
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
    static func main() throws {
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
