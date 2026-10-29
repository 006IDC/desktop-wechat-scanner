import Foundation
import CoreGraphics
import CoreText
import CoreImage
import CoreVideo

@main enum SyntheticPhoneFrameProbeTests {
    static let expected="006IDC20261026PERF"
    static func fixture(qr:String?=nil,text:String?=nil) throws -> CVPixelBuffer {
        var value:CVPixelBuffer?
        precondition(CVPixelBufferCreate(nil,720,1280,kCVPixelFormatType_32BGRA,nil,&value)==kCVReturnSuccess)
        let pixels=value!
        precondition(CVPixelBufferLockBaseAddress(pixels,[])==kCVReturnSuccess)
        defer{CVPixelBufferUnlockBaseAddress(pixels,[])}
        let context=CGContext(data:CVPixelBufferGetBaseAddress(pixels),width:720,height:1280,bitsPerComponent:8,
            bytesPerRow:CVPixelBufferGetBytesPerRow(pixels),space:CGColorSpaceCreateDeviceRGB(),
            bitmapInfo:CGImageAlphaInfo.premultipliedFirst.rawValue|CGBitmapInfo.byteOrder32Little.rawValue)!
        context.setFillColor(CGColor(gray:1,alpha:1));context.fill(CGRect(x:0,y:0,width:720,height:1280))
        if let qr {
            let filter=CIFilter(name:"CIQRCodeGenerator")!
            filter.setValue(Data(qr.utf8),forKey:"inputMessage")
            let output=filter.outputImage!,image=CIContext(options:[.useSoftwareRenderer:true]).createCGImage(output,from:output.extent)!
            context.interpolationQuality = .none;context.draw(image,in:CGRect(x:110,y:680,width:500,height:500))
        }
        if let text {
            let font=CTFontCreateWithName("Menlo" as CFString,48,nil)
            let attributes:[NSAttributedString.Key:Any]=[
                NSAttributedString.Key(kCTFontAttributeName as String):font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String):CGColor(gray:0,alpha:1)]
            let line=CTLineCreateWithAttributedString(NSAttributedString(string:text,attributes:attributes))
            context.textPosition=CGPoint(x:60,y:400);CTLineDraw(line,context)
        }
        context.flush();return pixels
    }
    static func main() throws {
        let preview=try SyntheticPhoneFrameProbe.inspect(fixture(qr:expected),expected:expected,probeQR:true)
        precondition(preview.qrVisible && !preview.textMatched,"A visible QR was counted as an app text result")
        let text=try SyntheticPhoneFrameProbe.inspect(fixture(text:expected),expected:expected,probeQR:true)
        precondition(!text.qrVisible && text.textMatched,"Plain native result could not be distinguished from the preview")
        let combined=try SyntheticPhoneFrameProbe.inspect(fixture(qr:expected,text:expected),expected:expected,probeQR:true)
        precondition(combined.qrVisible && combined.textMatched,"Same-frame QR/text observation lost one channel")
        let wrong=try SyntheticPhoneFrameProbe.inspect(fixture(qr:"006IDC20261026DIFF",text:"006IDC20261026PERE"),expected:expected,probeQR:true)
        precondition(!wrong.qrVisible && !wrong.textMatched && wrong.editDistance.map{$0>0}==true,"Another code or fuzzy text passed exact matching")
        do {_=try SyntheticPhoneFrameProbe.inspect(fixture(),expected:"private",probeQR:true);fatalError("Non-synthetic query accepted")}catch{}
        print("PASS synthetic preview QR vs exact native text, same-frame observation, wrong code/fuzzy rejection; no screen or phone")
    }
}
