import Foundation
import CoreImage

@main enum NativeScannerMatteTests {
    static func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CIImage {
        CIImage(color: CIColor(red: r, green: g, blue: b)).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    static func check(black: CIImage, white: CIImage, live: CIImage? = nil,
                      expected: [UInt8], algorithm: NativeScannerMatte.Algorithm = .blackWhite) throws {
        let renderer = try NativeScannerMatte(black: black, white: white, algorithm: algorithm)
        let result = CIImage(cgImage: try renderer.render(black: live ?? black), options: [.colorSpace: NSNull()])
        var bytes = [UInt8](repeating: 0, count: Int(result.extent.width * result.extent.height) * 4)
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        bytes.withUnsafeMutableBytes {
            context.render(result, toBitmap: $0.baseAddress!, rowBytes: Int(result.extent.width) * 4,
                           bounds: result.extent, format: .RGBA8, colorSpace: nil)
        }
        precondition(zip(bytes, expected).allSatisfy { abs(Int($0) - Int($1)) <= 2 })
        _ = try renderer.render(black: live ?? black)
    }
    static func main() throws {
        try NativeScannerMatte.prewarm()
        try check(black: color(0,0,0), white: color(1,1,1), expected: [0,0,0,0])
        try check(black: color(0,0,0), white: color(0,0,0), expected: [0,0,0,255])
        try check(black: color(0.18,0.18,0.18), white: color(0.53,0.53,0.53), expected: [46,46,46,166])
        try check(black: color(0.8,0.8,0.8), white: color(1,1,1), expected: [204,204,204,204])
        try check(black: color(0,0,0), white: color(1,1,1), live: color(0,0.7,0), expected: [0,179,0,179])
        // Single-frame blue extraction: gray controls, static arbitrary colors,
        // and a genuine moving green foreground all retain premultiplied pixels.
        try check(black: color(0,0,0), white: color(0,0,0), live: color(0,0,1), expected: [0,0,0,0], algorithm: .blueWithNativeColorBias)
        try check(black: color(0.18,0.18,0.18), white: color(0,0,0), live: color(0.18,0.18,0.53), expected: [46,46,46,166], algorithm: .blueWithNativeColorBias)
        try check(black: color(0.8,0.2,0.1), white: color(0,0,0), live: color(0.8,0.2,0.1), expected: [204,51,26,255], algorithm: .blueWithNativeColorBias)
        try check(black: color(0,0,0), white: color(0,0,0), live: color(0,0.7,0.3), expected: [0,179,0,179], algorithm: .blueWithNativeColorBias)
        for a: CGFloat in [0.25,0.6,1] {
            for (r,g,b): (CGFloat,CGFloat,CGFloat) in [(0.8,0.2,0.1),(0.1,0.2,0.8),(0.2,0.8,0.2)] {
                try check(black: color(a*r,a*g,a*b), white: color(0,0,0),
                    live: color(a*r,a*g,a*b+1-a),
                    expected: [UInt8((a*r*255).rounded()),UInt8((a*g*255).rounded()),UInt8((a*b*255).rounded()),UInt8((a*255).rounded())], algorithm: .blueWithNativeColorBias)
            }
        }
        try check(black: color(0,0,0), white: color(0,0,0), live: color(0,0,0.3), expected: [0,0,0,179], algorithm: .blueWithNativeColorBias)
        let native = Data([0,0,0,255, 255,255,255,255, 204,51,26,255, 0,0,0,255, 0,0,0,255, 255,255,255,255])
        let observed = Data([0,0,255,255, 255,255,255,255, 204,51,26,255, 0,179,76,255, 0,0,76,255, 255,255,255,255])
        let nativeImage = CIImage(bitmapData: native, bytesPerRow: 8, size: CGSize(width:2,height:3), format: .RGBA8, colorSpace: nil)
        let observedImage = CIImage(bitmapData: observed, bytesPerRow: 8, size: CGSize(width:2,height:3), format: .RGBA8, colorSpace: nil)
        try check(black: nativeImage, white: nativeImage, live: observedImage,
            expected: [0,0,0,0, 255,255,255,255, 204,51,26,255, 0,179,0,179, 0,0,0,179, 255,255,255,255], algorithm: .blueWithNativeColorBias)
        // A moving cyan-tinted glow in one calibration observation must not
        // become a stationary blue ghost in all subsequent native frames.
        let observations = [color(0,0.4,0.3)] + Array(repeating:color(0,0,0),count:8)
        let temporal = try NativeScannerMatte(black:observations[0],white:observations[0],
            algorithm:.blueWithNativeColorBias,blueCalibration:observations)
        let recovered = CIImage(cgImage:try temporal.render(black:color(0,0,1)),options:[.colorSpace:NSNull()])
        var clear=[UInt8](repeating:0,count:4)
        clear.withUnsafeMutableBytes {
            CIContext(options:[.workingColorSpace:NSNull(),.outputColorSpace:NSNull()]).render(recovered,
                toBitmap:$0.baseAddress!,rowBytes:4,bounds:recovered.extent,format:.RGBA8,colorSpace:nil)
        }
        precondition(clear.allSatisfy { $0 <= 2 })
        // Shared immutable pipelines/context must not share mutable calibration.
        let transparent=try NativeScannerMatte(black:color(0,0,0),white:color(1,1,1))
        let opaque=try NativeScannerMatte(black:color(0,0,0),white:color(0,0,0))
        _=try opaque.render(black:color(0,0,0))
        let independent=CIImage(cgImage:try transparent.render(black:color(0,0,0)),options:[.colorSpace:NSNull()])
        var alpha=[UInt8](repeating:255,count:4)
        alpha.withUnsafeMutableBytes {
            CIContext(options:[.workingColorSpace:NSNull(),.outputColorSpace:NSNull()]).render(independent,
                toBitmap:$0.baseAddress!,rowBytes:4,bounds:independent.extent,format:.RGBA8,colorSpace:nil)
        }
        precondition(alpha.allSatisfy{$0<=2},"Shared GPU resources leaked another renderer's calibration")
        do {
            _ = try NativeScannerMatte(black: color(0,0,0), white: color(1,1,1).cropped(to: .zero))
            preconditionFailure("Mismatched calibration accepted")
        } catch is NativeScannerMatte.Unavailable {}
        print("native scanner matte synthetic alpha tests passed")
    }
}
