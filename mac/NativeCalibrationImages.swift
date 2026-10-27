import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Immutable synthetic inputs only. No screen, phone pixels or scanner state
/// enter this cache. Prewarm off the main actor before the user opens a scanner.
enum NativeCalibrationImages {
    private static let images:Result<(Data,Data),Error>=Result {
        func encode(blue:Bool) throws -> Data {
            guard let space=CGColorSpace(name:CGColorSpace.sRGB),
                  let context=CGContext(data:nil,width:720,height:1280,bitsPerComponent:8,bytesPerRow:720*4,
                      space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw ScanError("无法准备原生相机校准图。")
            }
            context.setFillColor(red:0,green:0,blue:blue ? 1:0,alpha:1)
            context.fill(CGRect(x:0,y:0,width:720,height:1280))
            let data=NSMutableData()
            guard let image=context.makeImage(),
                  let destination=CGImageDestinationCreateWithData(data,UTType.png.identifier as CFString,1,nil) else {
                throw ScanError("无法准备原生相机校准图。")
            }
            CGImageDestinationAddImage(destination,image,nil)
            guard CGImageDestinationFinalize(destination) else{throw ScanError("无法编码原生相机校准图。")}
            return data as Data
        }
        return (try encode(blue:false),try encode(blue:true))
    }
    static func prewarm() throws {_=try images.get()}
    static func image(blue:Bool) throws -> Data {
        let value=try images.get();return blue ? value.1:value.0
    }
}
