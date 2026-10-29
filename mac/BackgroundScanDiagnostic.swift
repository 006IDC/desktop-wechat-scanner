import AppKit
import CoreImage
import CoreVideo

private final class BackgroundScanFrames:@unchecked Sendable {
    struct Frame:@unchecked Sendable {let pixels:CVPixelBuffer;let sequence:Int;let receivedAt:Double}
    private let lock=NSLock()
    private var frame:Frame?,sequence=0
    let available=CameraWindowAvailability()
    func receive(_ pixels:CVPixelBuffer) {
        lock.withLock {sequence+=1;frame=Frame(pixels:pixels,sequence:sequence,receivedAt:ProcessInfo.processInfo.systemUptime)}
    }
    func latest()->Frame? {lock.withLock{frame}}
}

/// Non-activating, explicit research entry. The only captured window is our
/// synthetic QR board, ordered behind normal windows and unable to receive input.
/// It exercises production capture/mailbox/socket/decoder components, not the
/// AppController UI, physical dragging, or another application's desktop pixels.
@MainActor enum BackgroundScanDiagnostic {
    enum Failure:String,Error {case arguments,existingSession,permission,device,application,mirror,navigation,camera,result,focus,cleanup}
    private final class BoardWindow:NSWindow {
        override var canBecomeKey:Bool {false}
        override var canBecomeMain:Bool {false}
    }
    private final class Pattern:NSView {
        let image:CGImage
        var showQR=false
        init(payload:String) throws {
            let filter=CIFilter(name:"CIQRCodeGenerator")!
            filter.setValue(Data(payload.utf8),forKey:"inputMessage")
            filter.setValue("M",forKey:"inputCorrectionLevel")
            guard let qr=filter.outputImage,let image=CIContext().createCGImage(qr,from:qr.extent) else{throw Failure.arguments}
            self.image=image;super.init(frame:.zero)
        }
        required init?(coder:NSCoder){fatalError("init(coder:) is not supported")}
        override func draw(_ dirtyRect:NSRect) {
            NSColor.white.setFill();bounds.fill()
            if showQR,let context=NSGraphicsContext.current?.cgContext {
                context.interpolationQuality = .none
                let side=min(bounds.width,bounds.height)*0.64
                context.draw(image,in:CGRect(x:bounds.midX-side/2,y:bounds.midY-side/2,width:side,height:side))
            }
        }
    }
    private static func option(_ name:String)->String? {
        guard let i=CommandLine.arguments.firstIndex(of:name),CommandLine.arguments.indices.contains(i+1) else{return nil}
        return CommandLine.arguments[i+1]
    }
    private static var now:Double {ProcessInfo.processInfo.systemUptime}
    private static func percentiles(_ values:[Double])->[String:Double] {
        guard !values.isEmpty else{return [:]};let sorted=values.sorted()
        return ["count":Double(values.count),"p50":sorted[(sorted.count-1)/2],"p95":sorted[max(0,Int(ceil(Double(sorted.count)*0.95))-1)],"max":sorted.last!]
    }
    /// Only fixed, independently confirmed navigation targets are tapped.
    /// Nothing from OCR is exported, and login/consent/payment pages fail closed.
    private static func navigate(phone:PhoneSession,mirror:MirrorSession,frames:BackgroundScanFrames,
                                 package:String,display:Int) async throws ->Double {
        let began=now,deadline=now+25
        var lastFrame=0,lastTap=0.0,scanTap:Double?,plusRetry=ScannerNavigationOCR.PlusRetry()
        while now<deadline {
            guard frames.available.isAvailable else{throw Failure.mirror}
            let state=try await phone.cameraState()
            if state.captureActivity()?.package==package,state.captureActivity()?.displayId==display {
                guard let scanTap else{throw Failure.navigation};return scanTap
            }
            if scanTap != nil {try await Task.sleep(nanoseconds:60_000_000);continue}
            guard let activity=state.activities.first(where:{$0.displayId==display}),activity.package==package,
                  let frame=frames.latest(),frame.sequence>lastFrame,frame.receivedAt>=began,
                  now-frame.receivedAt<1,now-lastTap>0.8 else {
                try await Task.sleep(nanoseconds:60_000_000);continue
            }
            lastFrame=frame.sequence
            let words=try await Task.detached(priority:.userInitiated){try ScannerNavigationOCR.recognize(frame.pixels)}.value
            var point:CGPoint?,isPlus=false
            if package=="com.tencent.mm" {
                let menu=words.contains{$0.value.contains("添加朋友")} && words.contains{$0.value.contains("发起群聊")}
                if menu,let scan=words.first(where:{$0.value.replacingOccurrences(of:" ",with:"")=="扫一扫" && $0.rect.midY<800}) {
                    point=CGPoint(x:scan.rect.midX/720,y:scan.rect.midY/1280)
                } else if words.contains(where:{$0.value=="通讯录" && $0.rect.midY>1000}),
                          let plus=try ScannerNavigationOCR.plusButton(in:frame.pixels,homeWords:words),
                          plusRetry.permitsTap(at:now,frameReceivedAt:frame.receivedAt) {
                    point=CGPoint(x:plus.x/720,y:plus.y/1280);isPlus=true
                }
            } else {
                let tabs=Set(words.filter{$0.rect.midY>1000 && ["消息","理财","生活"].contains($0.value)}.map(\.value))
                let home=(words.contains{$0.value=="首页" && $0.rect.midY>1000} || tabs.count>=2) &&
                    words.contains{$0.value=="我的" && $0.rect.midY>1000} &&
                    words.contains{["收付款","收付钱"].contains($0.value) && $0.rect.midY<400}
                if home,let scan=words.first(where:{$0.value=="扫一扫" && $0.rect.midY<400}) {
                    point=CGPoint(x:scan.rect.midX/720,y:scan.rect.midY/1280)
                }
            }
            if let point {
                let current=try await phone.cameraState()
                guard current.activities.first(where:{$0.displayId==display})?.component==activity.component,
                      current.captureActivity()==nil,now-frame.receivedAt<1 else{continue}
                let tap=now
                if isPlus {plusRetry.recordTap(at:tap,frameReceivedAt:frame.receivedAt)}else{scanTap=tap}
                mirror.tap(x:point.x,y:point.y);lastTap=tap
            }
            try await Task.sleep(nanoseconds:60_000_000)
        }
        throw Failure.navigation
    }
    static func run() async -> Int32 {
        guard CommandLine.arguments.contains("--diagnostic-usb"),CommandLine.arguments.contains("--locked-applications"),
              let path=option("--background-report"),let resources=Bundle.main.resourceURL else{return 2}
        let frontBefore=NSWorkspace.shared.frontmostApplication?.processIdentifier
        let journal=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/006IDC/DesktopWeChatScanner/session.json")
        guard !FileManager.default.fileExists(atPath:journal.path),
              NSRunningApplication.runningApplications(withBundleIdentifier:"com.idc006.DesktopWeChatScanner").allSatisfy({$0.processIdentifier==ProcessInfo.processInfo.processIdentifier}),
              let output=PrivateDiagnosticReport.openNew(path) else{return 2}
        var report:[String:Any]=["test":"background-owned-board-scan","physicalInputMeasured":false,"appControllerTested":false,
            "captureScope":"own-synthetic-board-only","activationRequested":false]
        let adb=resources.appendingPathComponent("adb/bin/adb"),phone=PhoneSession(resources:resources,adbURL:adb)
        let capture=DesktopCapture()
        var board:BoardWindow?,mirror:MirrorSession?,items=[[String:Any]](),stage="prerequisites",passed=false
        do {
            guard CGPreflightScreenCaptureAccess() else{throw Failure.permission}
            report["existingCapturePermission"]=true
            let devices=try await ADBConnectionManager(adbURL:adb).devices().filter{$0.transport == .usb && $0.authorization == .authorized}
            guard devices.count==1 else{throw Failure.device}
            stage="connect"
            _=try await phone.connect(openWechatOnConnect:false,selectedSerial:devices[0].serial,allowLockedApplications:true,desktopHome:true,genericDesktopCamera:true){_ in}
            guard await phone.independentApplicationsWhenLocked,let display=await phone.scannerDisplay()?.id else{throw Failure.device}
            let apps=try await phone.applications()
            let packages=CommandLine.arguments.contains("--diagnostic-alipay-only") ? ["com.eg.android.AlipayGphone"] : ["com.tencent.mm","com.eg.android.AlipayGphone"]
            for (index,package) in packages.enumerated() {
                var item:[String:Any]=["application":package=="com.tencent.mm" ? "wechat":"alipay","recognized":false]
                do {
                    guard let app=apps.first(where:{$0.packageName==package}),let screen=NSScreen.screens.first else{throw Failure.application}
                    let payload="006IDC"+UUID().uuidString.replacingOccurrences(of:"-",with:"").prefix(12)
                    let pattern=try Pattern(payload:String(payload))
                    let side=min(600,min(screen.visibleFrame.width,screen.visibleFrame.height)-40)
                    let window=BoardWindow(contentRect:NSRect(x:screen.visibleFrame.midX-side/2,y:screen.visibleFrame.midY-side/2,width:side,height:side),styleMask:[.borderless],backing:.buffered,defer:false)
                    window.isReleasedWhenClosed=false;window.ignoresMouseEvents=true;window.level=NSWindow.Level(rawValue:-1000)
                    window.contentView=pattern;window.orderBack(nil);pattern.displayIfNeeded();board=window
                    let frames=BackgroundScanFrames(),stream=MirrorSession();mirror=stream
                    let endpoint=try await phone.mirrorEndpoint(display:display),direct=try await phone.directMirror(display:display)
                    try await stream.startVideo(adbURL:adb,serverURL:resources.appendingPathComponent("scrcpy-server"),serial:endpoint.serial,displayID:display,direct:direct,
                        onFrame:{frames.receive($0)},onFailure:{_ in frames.available.invalidate()})
                    stage="launch"
                    let launch=now
                    guard try await phone.launchApplication(app,on:display) else{throw Failure.application}
                    item["launchConfirmedMilliseconds"]=(now-launch)*1000
                    stage="navigate"
                    let tap=try await navigate(phone:phone,mirror:stream,frames:frames,package:package,display:display)
                    item["scanTapToOwnerMilliseconds"]=(now-tap)*1000
                    let pump=CameraPumpMailbox(sourceIsAvailable:{frames.available.isAvailable})
                    // The final clear retires the previous application's epoch.
                    // The next application's frame epoch must advance past it.
                    let epoch=100+index*100
                    try await phone.clear(epoch:epoch,requireConnection:true)
                    await capture.setDiagnosticBoard(CGWindowID(window.windowNumber))
                    stage="capture-prepare"
                    let prepare=now;try await capture.prepare();item["capturePrepareMilliseconds"]=(now-prepare)*1000
                    let until=now+9,blankUntil=now+1.5
                    pump.prepareRegion(at:now,immediateFirst:true)
                    var qrShownAt:Double?,firstQRACK:Double?,firstACK:Double?,lastChecked=0,sent=0,recognized=false
                    var costs=[Double](),captures=[Double](),startTimes=[Double]()
                    stage="capture-send-recognize"
                    while now<until {
                        let iteration=now
                        guard frames.available.isAvailable else{throw Failure.mirror}
                        if qrShownAt==nil,now>=blankUntil {pattern.showQR=true;pattern.needsDisplay=true;pattern.displayIfNeeded();qrShownAt=now}
                        let target=try DesktopCaptureTarget.current(for:window.frame)
                        pump.publish(target)
                        guard let selection=pump.selection() else{throw Failure.camera}
                        do {
                            let begin=now,image=try await capture.capture(selection.target,maximumDimension:720)
                            captures.append((now-begin)*1000)
                            let receipt=try await phone.frame(image,epoch:epoch,selectedAt:target.selectedAt,isCurrent:{pump.isCurrent(selection) && pump.captureReady(at:ProcessInfo.processInfo.systemUptime)})
                            costs.append(receipt.requestMilliseconds);sent+=1;startTimes.append(iteration)
                            if firstACK==nil {firstACK=now;item["scanTapToFirstACKMilliseconds"]=(now-tap)*1000}
                            if qrShownAt != nil,firstQRACK==nil {firstQRACK=now}
                        } catch is DesktopCaptureTransientError {item["captureTransientOccurred"]=true}
                        catch is CameraFrameExpiredError {item["expiredFrameOccurred"]=true}
                        if let qrShownAt,let frame=frames.latest(),frame.sequence>lastChecked,frame.receivedAt>=qrShownAt {
                            lastChecked=frame.sequence
                            let found=try await Task.detached(priority:.userInitiated){
                                try ScannerNavigationOCR.recognize(frame.pixels).contains{$0.value.replacingOccurrences(of:" ",with:"").contains(payload)}
                            }.value
                            if found {
                                recognized=true;item["qrShownToResultDecodedMilliseconds"]=(frame.receivedAt-qrShownAt)*1000
                                item["qrShownToResultObservedMilliseconds"]=(now-qrShownAt)*1000;break
                            }
                        }
                        let rest=max(0,0.125-(now-iteration));if rest>0 {try await Task.sleep(nanoseconds:UInt64(rest*1_000_000_000))}
                    }
                    pump.stop();try await phone.clear(epoch:epoch+20,requireConnection:true)
                    item["recognized"]=recognized;item["sentFrames"]=sent
                    item["requestMilliseconds"]=percentiles(costs);item["captureMilliseconds"]=percentiles(captures)
                    item["sendStartGapMilliseconds"]=percentiles(zip(startTimes.dropFirst(),startTimes).map{($0-$1)*1000})
                    if let qrShownAt,let firstQRACK {item["qrShownToFirstACKMilliseconds"]=(firstQRACK-qrShownAt)*1000}
                    guard recognized else{throw Failure.result}
                } catch {
                    item["failureStage"]=stage;item["failureCode"]=(error as? Failure)?.rawValue ?? "backend"
                    items.append(item);throw error
                }
                items.append(item)
                await capture.stop();await mirror?.stop();mirror=nil;try await phone.stopDirectMirror(display:display);board?.orderOut(nil);board=nil
            }
            passed=true
        } catch {
            report["failureStage"]=stage;report["failureCode"]=(error as? Failure)?.rawValue ?? "backend"
        }
        await capture.stop();await mirror?.stop();board?.orderOut(nil)
        let cleanup=await phone.disconnect()
        report["applications"]=items;report["cleanupSucceeded"]=cleanup.isEmpty
        report["sessionRecordAbsent"] = !FileManager.default.fileExists(atPath:journal.path)
        report["frontmostUnchanged"] = frontBefore==NSWorkspace.shared.frontmostApplication?.processIdentifier
        report["passed"]=passed && cleanup.isEmpty && report["sessionRecordAbsent"] as? Bool==true
        do {
            let data=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
            try output.write(contentsOf:data);try output.close()
        } catch {try? output.close();return 1}
        return report["passed"] as? Bool==true ? 0:1
    }
}
