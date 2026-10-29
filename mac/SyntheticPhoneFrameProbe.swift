import Foundation
import CoreVideo
import Vision

/// Explicit synthetic diagnostics only. A QR visible in the returned video is
/// not evidence that the phone app has produced a text result.
enum SyntheticPhoneFrameProbe {
    struct Observation {
        let qrVisible:Bool,textMatched:Bool,prefixSeen:Bool
        let editDistance:Int?
    }
    static func inspect(_ pixels:CVPixelBuffer,expected:String,probeQR:Bool) throws -> Observation {
        guard expected.range(of:"^006IDC[A-Z0-9]{8,32}$",options:.regularExpression) != nil else {
            throw ScanError("测试码格式无效。")
        }
        let words=try ScannerNavigationOCR.recognize(pixels)
        let normalized=words.map{$0.value.filter{!$0.isWhitespace}}
        let candidates=normalized.filter{$0.contains("006IDC") && $0.count<=64}
        let textMatched=normalized.joined().contains(expected)
        var qrVisible=false
        if probeQR {
            let request=VNDetectBarcodesRequest();request.symbologies=[.qr]
            try VNImageRequestHandler(cvPixelBuffer:pixels).perform([request])
            qrVisible=request.results?.contains{$0.payloadStringValue==expected} ?? false
        }
        return Observation(qrVisible:qrVisible,textMatched:textMatched,prefixSeen:!candidates.isEmpty,
                           editDistance:candidates.map{distance($0,expected)}.min())
    }
    private static func distance(_ input:String,_ expected:String)->Int {
        let a=Array(input),b=Array(expected);var row=Array(0...b.count)
        for (i,x) in a.enumerated() {
            var next=[i+1]+Array(repeating:0,count:b.count)
            for (j,y) in b.enumerated(){next[j+1]=min(row[j+1]+1,next[j]+1,row[j]+(x==y ? 0:1))}
            row=next
        }
        return row.last!
    }
}
