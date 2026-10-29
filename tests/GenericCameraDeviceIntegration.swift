import AppKit
import CoreVideo
import CoreImage
import Vision
import Darwin

/// Explicit backend integration: normal catalog launch on our owned display,
/// no OS input, app-page shortcuts, desktop capture, screenshots or pixel export.
/// A third app that opens its own camera on launch can exercise generic routing.
private final class GenericCameraObservation:@unchecked Sendable {
    private let lock=NSLock()
    private var latest:CVPixelBuffer?,sequence=0,failure=false
    func publish(_ image:CVPixelBuffer){lock.withLock{latest=image;sequence+=1}}
    func failed(){lock.withLock{failure=true}}
    func snapshot()->(CVPixelBuffer?,Int,Bool){lock.withLock{(latest,sequence,failure)}}
    func release(){lock.withLock{latest=nil}}
}
@main enum GenericCameraDeviceIntegration {
    static let payload="006IDCGENERIC"+UUID().uuidString.replacingOccurrences(of:"-",with:"").prefix(12)
    enum Failure:Error {case prerequisites,notInstalled,notCamera,notBound,cameraNotOpened,mirrorFailed,noSyntheticImage,cleanup}
    static func option(_ name:String)->String? {
        guard let i=CommandLine.arguments.firstIndex(of:name),CommandLine.arguments.indices.contains(i+1) else{return nil}
        return CommandLine.arguments[i+1]
    }
    static func image() throws -> Data {
        let code=CIFilter(name:"CIQRCodeGenerator")!
        code.setValue(Data(payload.utf8),forKey:"inputMessage");code.setValue("M",forKey:"inputCorrectionLevel")
        guard let pixels=code.outputImage,
              let qr=CIContext(options:[.useSoftwareRenderer:true]).createCGImage(pixels,from:pixels.extent),
              let canvas=CGContext(data:nil,width:720,height:720,bitsPerComponent:8,bytesPerRow:720*4,
                    space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else{throw Failure.prerequisites}
        canvas.setFillColor(CGColor(gray:1,alpha:1));canvas.fill(CGRect(x:0,y:0,width:720,height:720))
        canvas.interpolationQuality = .none;canvas.draw(qr,in:CGRect(x:144,y:144,width:432,height:432))
        guard let output=canvas.makeImage(),let png=NSBitmapImageRep(cgImage:output).representation(using:.png,properties:[:]) else{throw Failure.prerequisites}
        return png
    }
    static func match(_ pixels:CVPixelBuffer) throws -> (image:Bool,result:Bool) {
        let qr=VNDetectBarcodesRequest();qr.symbologies=[.qr]
        let text=VNRecognizeTextRequest();text.recognitionLevel = .accurate;text.recognitionLanguages=["en-US"]
        try VNImageRequestHandler(cvPixelBuffer:pixels).perform([qr,text])
        return (qr.results?.contains{$0.payloadStringValue==payload} ?? false,
                text.results?.contains{$0.topCandidates(1).first?.string.replacingOccurrences(of:" ",with:"").contains(payload)==true} ?? false)
    }
    static func blockingHints(_ pixels:CVPixelBuffer?) throws -> [String] {
        guard let pixels else{return []}
        let request=VNRecognizeTextRequest();request.recognitionLevel = .accurate
        request.recognitionLanguages=["zh-Hans","en-US"]
        try VNImageRequestHandler(cvPixelBuffer:pixels).perform([request])
        // Only emit these fixed diagnostic labels; never export arbitrary OCR.
        let markers=["同意","不同意","取消","继续","允许","隐私","拍照","照片","视频","不支持","副屏","主屏幕"]
        let words=(request.results ?? []).compactMap{$0.topCandidates(1).first?.string}
        return markers.filter{marker in words.contains{$0.contains(marker)}}
    }
    static func main() async {
        guard CommandLine.arguments.contains("--run-device-test"),let folder=option("--resources"),let pkg=option("--package"),
              AndroidApplication(packageName:pkg,component:pkg+"/.Main",name:"").isValid,
              !["com.tencent.mm","com.eg.android.AlipayGphone"].contains(pkg),
              let output=option("--output") else{print("Explicit third-app device-test arguments required");exit(2)}
        let reportRoot=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent(".local/generic-camera-tests").standardizedFileURL
        let outputURL=URL(fileURLWithPath:output).standardizedFileURL
        guard outputURL.deletingLastPathComponent()==reportRoot else{print("Reports must stay in .local/generic-camera-tests");exit(2)}
        do {try FileManager.default.createDirectory(at:reportRoot,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])}
        catch {print("Report directory unavailable");exit(2)}
        let reportFD=Darwin.open(outputURL.path,O_WRONLY|O_CREAT|O_EXCL,mode_t(0o600))
        guard reportFD>=0 else{print("Report must be a new file");exit(2)}
        let reportHandle=FileHandle(fileDescriptor:reportFD,closeOnDealloc:true)
        let resources=URL(fileURLWithPath:folder),adb=resources.appendingPathComponent("adb/bin/adb")
        let support=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/006IDC/DesktopWeChatScanner")
        guard !FileManager.default.fileExists(atPath:support.appendingPathComponent("session.json").path),
              NSRunningApplication.runningApplications(withBundleIdentifier:"com.idc006.DesktopWeChatScanner").isEmpty else{print("An existing session or GUI must be stopped first");exit(2)}
        let phone=PhoneSession(resources:resources,adbURL:adb),mirror=MirrorSession(),observed=GenericCameraObservation()
        var report:[String:Any]=["test":"generic-third-app-camera-api","package":pkg,"desktopCaptureTested":false,"physicalMouseTested":false,"validationScope":"third-app-camera-input-delivery"]
        var stage="device",passed=false
        let began=ProcessInfo.processInfo.systemUptime
        do {
            let devices=try await ADBConnectionManager(adbURL:adb).devices().filter{$0.transport == .usb && $0.authorization == .authorized}
            guard devices.count==1 else{throw Failure.prerequisites}
            stage="connect"
            _=try await phone.connect(openWechatOnConnect:false,selectedSerial:devices[0].serial,
                allowLockedApplications:CommandLine.arguments.contains("--locked-applications"),desktopHome:true,genericDesktopCamera:true){_ in}
            let apps=try await phone.applications()
            guard let app=apps.first(where:{$0.packageName==pkg}),let display=await phone.scannerDisplay()?.id else{throw Failure.notInstalled}
            let endpoint=try await phone.mirrorEndpoint(display:display)
            let direct=try await phone.directMirror(display:display)
            try await mirror.startVideo(adbURL:adb,serverURL:resources.appendingPathComponent("scrcpy-server"),serial:endpoint.serial,displayID:display,direct:direct,
                onFrame:{observed.publish($0)},onFailure:{_ in observed.failed()})
            stage="launch"
            let launched=ProcessInfo.processInfo.systemUptime
            guard try await phone.launchApplication(app,on:display) else{throw Failure.notCamera}
            var state=try await phone.cameraState()
            guard state.desktopCameraEnabled,state.desktopCameraBindings.contains(where:{$0.displayId==display && $0.packageName==pkg}) else{throw Failure.notBound}
            report["bindingConfirmed"]=true;report["launchMilliseconds"]=(ProcessInfo.processInfo.systemUptime-launched)*1000
            stage="cameraOwner"
            let until=ProcessInfo.processInfo.systemUptime+8
            while state.captureActivity()?.package != pkg,ProcessInfo.processInfo.systemUptime<until {
                try await Task.sleep(nanoseconds:100_000_000);state=try await phone.cameraState()
            }
            report["ownerKnown"]=state.ownerKnown;report["activeStreams"]=state.activeStreams
            report["cameraOwnerMatchesTarget"]=state.cameraOwner==pkg;report["cameraOwnerAbsent"]=state.cameraOwner==nil
            if state.captureActivity()?.package != pkg {
                let frame=observed.snapshot();report["mirrorFramesBeforeCamera"]=frame.1;report["mirrorFailedBeforeCamera"]=frame.2
                report["fixedBlockingUIHints"]=try blockingHints(frame.0)
                throw Failure.cameraNotOpened
            }
            report["genericOwnerConfirmed"]=true;report["legacyScannerRouteAbsent"]=state.scannerActivity()==nil
            report["launchToCameraOwnerMilliseconds"]=(ProcessInfo.processInfo.systemUptime-launched)*1000
            stage="syntheticImage"
            let png=try image();try await phone.clear(epoch:10,requireConnection:true)
            let first=observed.snapshot().1
            var preview=false,result=false,lastChecked=first,sent=0
            var afterFirstSend:Int?,previewSequence:Int?,previewAt:TimeInterval?
            let end=ProcessInfo.processInfo.systemUptime+8
            while ProcessInfo.processInfo.systemUptime<end {
                let frame=observed.snapshot();if frame.2{throw Failure.mirrorFailed}
                if let afterFirstSend,frame.1>afterFirstSend,frame.1>lastChecked,let pixels=frame.0 {
                    lastChecked=frame.1
                    let match=try match(pixels)
                    if match.image,previewSequence==nil {preview=true;previewSequence=frame.1;previewAt=ProcessInfo.processInfo.systemUptime}
                    // A result is accepted only after a distinct preview frame of
                    // this run's unique QR. Fast results without that proof stay unconfirmed.
                    if match.result,let previewSequence,frame.1>previewSequence {result=true;break}
                    if let previewAt,ProcessInfo.processInfo.systemUptime-previewAt>=1 {break}
                }
                state=try await phone.cameraState()
                if state.captureActivity()?.package==pkg {
                    do {try await phone.frame(png,epoch:10,selectedAt:ProcessInfo.processInfo.systemUptime);sent+=1
                        if afterFirstSend==nil {afterFirstSend=observed.snapshot().1}
                    }
                    catch is CameraFrameExpiredError {}
                }
                try await Task.sleep(nanoseconds:125_000_000)
            }
            report["sentFrames"]=sent;report["mirrorFrames"]=observed.snapshot().1-first
            report["syntheticQRVisibleInApp"]=preview
            report["cameraDeliveryPassed"]=sent>0 && preview
            report["appRecognitionPassed"]=sent>0 && preview && result
            guard sent>0,preview else{throw Failure.noSyntheticImage}
            try await phone.discardFrame(epoch:10);report["clearAcknowledged"]=true
            passed=true
        } catch let failure as Failure {report["failure"]=String(describing:failure);report["failureStage"]=stage}
        catch {report["failure"]="operationFailed";report["failureStage"]=stage}
        await mirror.stop();observed.release()
        let cleanup=await phone.disconnect()
        report["cleanupSucceeded"]=cleanup.isEmpty
        report["cleanupStage"]=await phone.cleanupStage
        report["cameraClosureConfirmed"]=await phone.cleanupCameraClosureConfirmed
        report["streamsBeforeSleep"]=await phone.cleanupCameraStreamsBeforeSleep
        report["cleanupCameraWasEligible"]=await phone.cleanupScannerBeforeSleep
        report["sessionRecordAbsent"] = !FileManager.default.fileExists(atPath:support.appendingPathComponent("session.json").path)
        report["validationPassed"]=passed && cleanup.isEmpty && report["sessionRecordAbsent"] as? Bool==true
        report["seconds"]=ProcessInfo.processInfo.systemUptime-began
        do {let data=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]);try reportHandle.write(contentsOf:data);try reportHandle.close();print(String(data:data,encoding:.utf8)!)}
        catch {print("Could not write numeric-only report");exit(1)}
        exit(report["validationPassed"] as? Bool==true ? 0:1)
    }
}
