import Foundation
import CoreVideo
import Vision

/// Explicit synthetic diagnostics only. A QR visible in the returned video is
/// not evidence that the phone app has produced a text result.
enum SyntheticPhoneFrameProbe {
    struct Observation {
        let qrVisible:Bool,textMatched:Bool,prefixSeen:Bool
        let secondaryTextChecked:Bool,secondaryTextMatched:Bool
        let editDistance:Int?
    }
    static func inspect(_ pixels:CVPixelBuffer,expected:String,probeQR:Bool) throws -> Observation {
        guard expected.range(of:"^006IDC[A-Z0-9]{8,32}$",options:.regularExpression) != nil else {
            throw ScanError("测试码格式无效。")
        }
        let words=try ScannerNavigationOCR.recognize(pixels)
        let normalized=words.map{$0.value.filter{!$0.isWhitespace}}
        let candidates=normalized.filter{$0.contains("006IDC") && $0.count<=64}
        let primaryMatched=SyntheticResultText.matches(words,expected:expected)
        let best=candidates.map{distance($0,expected)}.min()
        let secondaryChecked = !primaryMatched && best.map{$0<=2}==true
        var secondaryMatched=false
        if secondaryChecked {
            // An independent top-1 ASCII pass, without customWords or fuzzy
            // correction. Expected text is never supplied to Vision itself.
            let request=VNRecognizeTextRequest()
            request.recognitionLevel = .accurate;request.recognitionLanguages=["en-US"]
            request.usesLanguageCorrection=false
            try VNImageRequestHandler(cvPixelBuffer:pixels).perform([request])
            secondaryMatched=SyntheticResultText.secondaryMatches((request.results ?? []).compactMap{$0.topCandidates(1).first?.string},expected:expected)
        }
        var qrVisible=false
        if probeQR {
            let request=VNDetectBarcodesRequest();request.symbologies=[.qr]
            try VNImageRequestHandler(cvPixelBuffer:pixels).perform([request])
            qrVisible=request.results?.contains{$0.payloadStringValue==expected} ?? false
        }
        return Observation(qrVisible:qrVisible,textMatched:primaryMatched || secondaryMatched,prefixSeen:!candidates.isEmpty,
                           secondaryTextChecked:secondaryChecked,secondaryTextMatched:secondaryMatched,editDistance:best)
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
