import Foundation
import CoreGraphics
import ImageIO

@main enum NativeCalibrationImagesTests {
    static func main() throws {
        let began=ProcessInfo.processInfo.systemUptime
        try NativeCalibrationImages.prewarm()
        let cold=(ProcessInfo.processInfo.systemUptime-began)*1000
        for blue in [false,true] {
            let data=try NativeCalibrationImages.image(blue:blue)
            guard let source=CGImageSourceCreateWithData(data as CFData,nil),
                  let image=CGImageSourceCreateImageAtIndex(source,0,nil) else{fatalError("Invalid PNG")}
            precondition(image.width==720 && image.height==1280,"Calibration input introduced letterboxing")
            var bytes=[UInt8](repeating:0,count:720*1280*4)
            bytes.withUnsafeMutableBytes {raw in
                let context=CGContext(data:raw.baseAddress,width:720,height:1280,bitsPerComponent:8,bytesPerRow:720*4,
                    space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(image,in:CGRect(x:0,y:0,width:720,height:1280))
            }
            for (x,y) in [(0,0),(719,0),(0,1279),(719,1279),(360,640)] {
                let p=(y*720+x)*4
                precondition(bytes[p]==0 && bytes[p+1]==0 && bytes[p+2]==(blue ? 255:0) && bytes[p+3]==255)
            }
            let cached=try NativeCalibrationImages.image(blue:blue)
            precondition(data==cached)
        }
        let warmStart=ProcessInfo.processInfo.systemUptime
        for _ in 0..<1000 {_=try NativeCalibrationImages.image(blue:true)}
        let warm=(ProcessInfo.processInfo.systemUptime-warmStart)*1000/1000
        print("PASS synthetic-only cached PNGs: dimensions, opaque full-extent colors, stable bytes; coldMillis=\(cold) cachedMeanMillis=\(warm)")
    }
}
