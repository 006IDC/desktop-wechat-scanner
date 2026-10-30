import CoreGraphics
import CoreImage
import CoreText
import CoreVideo
import Foundation
import Vision

/// Explicit diagnostics only. Model initialization must not age a phone frame
/// past the navigation/input deadline or contaminate the timed camera path.
/// This fixture never reaches a display, file, phone or product capture path.
enum SyntheticVisionPreparation {
    enum Failure: Error { case fixture, text, barcode }
    struct Metrics: Sendable {
        let textMilliseconds: Double
        let barcodeMilliseconds: Double
        let totalMilliseconds: Double
    }
    static func run() throws -> Metrics {
        try Task.checkCancellation()
        let began=ProcessInfo.processInfo.systemUptime
        let expected="006IDCWARMUPFIXTURE01"
        var buffer:CVPixelBuffer?
        guard CVPixelBufferCreate(nil,720,1280,kCVPixelFormatType_32BGRA,nil,&buffer)==kCVReturnSuccess,
              let buffer,CVPixelBufferLockBaseAddress(buffer,[])==kCVReturnSuccess else{throw Failure.fixture}
        do {
            defer{CVPixelBufferUnlockBaseAddress(buffer,[])}
            guard let context=CGContext(data:CVPixelBufferGetBaseAddress(buffer),width:720,height:1280,
                bitsPerComponent:8,bytesPerRow:CVPixelBufferGetBytesPerRow(buffer),space:CGColorSpaceCreateDeviceRGB(),
                bitmapInfo:CGImageAlphaInfo.premultipliedFirst.rawValue|CGBitmapInfo.byteOrder32Little.rawValue) else{throw Failure.fixture}
            context.setFillColor(CGColor(gray:1,alpha:1));context.fill(CGRect(x:0,y:0,width:720,height:1280))
            for (text,y) in [("MIRADROID",CGFloat(1080)),("扫一扫",CGFloat(980))] {
                let attributes:[NSAttributedString.Key:Any]=[
                    NSAttributedString.Key(kCTFontAttributeName as String):CTFontCreateWithName("PingFangSC-Regular" as CFString,48,nil),
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String):CGColor(gray:0,alpha:1)]
                context.textPosition=CGPoint(x:70,y:y)
                CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string:text,attributes:attributes)),context)
            }
            guard let filter=CIFilter(name:"CIQRCodeGenerator") else{throw Failure.fixture}
            filter.setValue(Data(expected.utf8),forKey:"inputMessage")
            guard let qr=filter.outputImage,
                  let image=CIContext(options:[.useSoftwareRenderer:true]).createCGImage(qr,from:qr.extent) else{throw Failure.fixture}
            context.interpolationQuality = .none;context.draw(image,in:CGRect(x:110,y:280,width:500,height:500))
            context.flush()
        }
        let textBegan=ProcessInfo.processInfo.systemUptime
        try Task.checkCancellation()
        let words=try ScannerNavigationOCR.recognize(buffer)
        let textEnd=ProcessInfo.processInfo.systemUptime
        // A synchronous Vision call finishes before honoring cancellation.
        // No phone session exists while this diagnostic preparation is running.
        try Task.checkCancellation()
        guard words.contains(where:{$0.value=="MIRADROID"}),words.contains(where:{$0.value=="扫一扫"}) else{throw Failure.text}
        let request=VNDetectBarcodesRequest();request.symbologies=[.qr]
        try VNImageRequestHandler(cvPixelBuffer:buffer).perform([request])
        let ended=ProcessInfo.processInfo.systemUptime
        try Task.checkCancellation()
        guard request.results?.contains(where:{$0.payloadStringValue==expected})==true else{throw Failure.barcode}
        return Metrics(textMilliseconds:(textEnd-textBegan)*1000,barcodeMilliseconds:(ended-textEnd)*1000,
                       totalMilliseconds:(ended-began)*1000)
    }
}
