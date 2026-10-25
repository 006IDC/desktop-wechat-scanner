import Foundation
import Vision

@main struct PhoneIntegration {
    static func words(_ data:Data) throws -> [(String,CGRect)] {
        let request=VNRecognizeTextRequest();request.recognitionLevel = .accurate
        request.recognitionLanguages=["zh-Hans","en-US"]
        try VNImageRequestHandler(data:data).perform([request])
        return (request.results ?? []).compactMap {r in
            guard let value=r.topCandidates(1).first?.string else{return nil}
            let b=r.boundingBox
            return (value,CGRect(x:b.minX*720,y:(1-b.maxY)*1280,width:b.width*720,height:b.height*1280))
        }
    }
    static func main() async {
        let session=PhoneSession(resources:URL(fileURLWithPath:CommandLine.arguments[1]))
        do {
            let model=try await session.connect {print($0);fflush(stdout)}
            print("CONNECTED",model);fflush(stdout)
            try await session.clear(epoch:1)
            try await Task.sleep(nanoseconds:700_000_000)
            let image=try await session.screenshot()
            let labels=try words(image)
            let known=["微信","通讯录","发现","我","扫一扫","发起群聊","添加朋友"]
            for label in labels where known.contains(label.0) {print("UI",label.0,label.1)}
            try image.write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
            print("PREVIEW",image.count);fflush(stdout)
            if CommandLine.arguments.count >= 5 {
                guard labels.first(where:{$0.0.hasPrefix("微信") && $0.1.midY<250}) != nil,
                    labels.contains(where:{$0.0.contains("通讯录") && $0.1.midY>1000}) else {throw ScanError("Expected WeChat home; no automatic tap")}
                try await session.tap(x:606,y:80)
                try await Task.sleep(nanoseconds:1_000_000_000)
                let menuImage=try await session.screenshot()
                try menuImage.write(to:URL(fileURLWithPath:CommandLine.arguments[2]+".menu.jpg"))
                let menu=try words(menuImage)
                guard menu.contains(where:{$0.0.contains("添加朋友")}),let scan=menu.first(where:{$0.0.contains("扫一扫")}) else {throw ScanError("Expected scan menu; no automatic tap")}
                try await session.tap(x:Int(scan.1.midX),y:Int(scan.1.midY))
                try await session.frame(Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[3])),epoch:1)
                let expected=CommandLine.arguments[4]
                var passed=false
                for _ in 0..<12 {
                    try await Task.sleep(nanoseconds:500_000_000)
                    let result=try await session.screenshot()
                    try result.write(to:URL(fileURLWithPath:CommandLine.arguments[2]+".scan.jpg"))
                    if try words(result).contains(where:{$0.0.contains(expected)}) {
                        try result.write(to:URL(fileURLWithPath:CommandLine.arguments[2]));passed=true;break
                    }
                }
                guard passed else {throw ScanError("Synthetic QR text not observed")}
                print("PASS WECHAT SYNTHETIC QR",expected)
            }
            if CommandLine.arguments.count>=7 {
                try await session.clear(epoch:2)
                try await session.openWechat()
                try await Task.sleep(nanoseconds:700_000_000)
                try await session.tap(x:606,y:80)
                try await Task.sleep(nanoseconds:1_000_000_000)
                let menu=try words(await session.screenshot())
                guard menu.contains(where:{$0.0.contains("添加朋友")}),let scan=menu.first(where:{$0.0.contains("扫一扫")}) else {throw ScanError("Rescan did not return to home/menu")}
                try await session.tap(x:Int(scan.1.midX),y:Int(scan.1.midY))
                try await Task.sleep(nanoseconds:1_000_000_000)
                let second=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[5]))
                let expected=CommandLine.arguments[6]
                try await session.frame(second,epoch:1)
                try await Task.sleep(nanoseconds:2_000_000_000)
                guard try !words(await session.screenshot()).contains(where:{$0.0.contains(expected)}) else {throw ScanError("Old epoch was accepted")}
                try await session.frame(second,epoch:2)
                var passed=false
                for _ in 0..<16 {
                    try await Task.sleep(nanoseconds:500_000_000)
                    let result=try await session.screenshot()
                    if try words(result).contains(where:{$0.0.contains(expected)}) {passed=true;break}
                }
                guard passed else {throw ScanError("New epoch did not scan")}
                print("PASS rescan, stale epoch rejected, resumed epoch scanned",expected)
            }
            let result=await session.disconnect()
            guard result.isEmpty else {throw ScanError(result)}
            print("PASS phone connect, preview, verified cleanup")
        } catch {
            print("FAILED",error.localizedDescription)
            print("CLEANUP",await session.disconnect())
            exit(1)
        }
    }
}
