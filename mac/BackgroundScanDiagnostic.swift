import AppKit
import CoreImage
import CoreVideo
import Vision

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

private final class BackgroundScanResult:@unchecked Sendable {
    private let lock=NSLock()
    private var result:(received:Double,observed:Double,sequence:Int)?
    private var firstQR:(received:Double,sequence:Int,textAlreadyMatched:Bool)?
    private var checks=0,prefixSeen=false,bestDistance:Int?
    private var secondaryChecks=0,secondaryMatched=false
    func snapshot()->(received:Double,observed:Double,sequence:Int)? {lock.withLock{result}}
    func qrSnapshot()->(received:Double,sequence:Int,textAlreadyMatched:Bool)? {lock.withLock{firstQR}}
    func diagnostics()->[String:Any] {lock.withLock {
        var value:[String:Any]=["resultOCRChecks":checks,"ownResultPrefixSeen":prefixSeen,
                              "secondaryTextChecks":secondaryChecks,"secondaryExactTextMatched":secondaryMatched]
        if let bestDistance {value["bestResultEditDistance"]=bestDistance};return value
    }}
    /// Identical observation cadence in both supply groups. Vision work does
    /// not block or run more frequently merely because supply is faster.
    func observe(frames:BackgroundScanFrames,payload:String,after shown:Double,until deadline:Double,probeQR:Bool)->Task<Void,Never> {
        Task.detached(priority:.userInitiated) {
            var sequence=0
            while !Task.isCancelled,ProcessInfo.processInfo.systemUptime<deadline,frames.available.isAvailable {
                if let frame=frames.latest(),frame.sequence>sequence,frame.receivedAt>=shown {
                    sequence=frame.sequence
                    let needsQR=probeQR && self.qrSnapshot()==nil
                    let observation=try? SyntheticPhoneFrameProbe.inspect(frame.pixels,expected:payload,probeQR:needsQR)
                    let observed=ProcessInfo.processInfo.systemUptime
                    guard !Task.isCancelled,frames.available.isAvailable,observed<=deadline else{return}
                    self.lock.withLock {
                        self.checks+=1
                        if let observation {
                            self.prefixSeen = self.prefixSeen || observation.prefixSeen
                            if observation.secondaryTextChecked {self.secondaryChecks+=1}
                            self.secondaryMatched = self.secondaryMatched || observation.secondaryTextMatched
                            if let distance=observation.editDistance {self.bestDistance=min(self.bestDistance ?? distance,distance)}
                            if observation.qrVisible,self.firstQR==nil {self.firstQR=(frame.receivedAt,frame.sequence,observation.textMatched)}
                            if observation.textMatched,self.result==nil {self.result=(frame.receivedAt,observed,frame.sequence)}
                        }
                    }
                    if observation?.textMatched==true {return}
                }
                try? await Task.sleep(nanoseconds:125_000_000)
            }
        }
    }
}

/// Non-activating, explicit research entry. The only captured window is our
/// synthetic QR board, ordered behind normal windows and unable to receive input.
/// It exercises production capture/mailbox/socket/decoder components, not the
/// AppController UI, physical dragging, or another application's desktop pixels.
@MainActor enum BackgroundScanDiagnostic {
    static func validScope(alipay:Bool,wechat:Bool,abba:Bool)->Bool {
        guard !(alipay && wechat) else{return false}
        return !abba || alipay != wechat
    }
    static func validExperiments(supplyABBA:Bool,snapshotABBA:Bool,snapshot:Bool,expire:Bool=false)->Bool {
        !(supplyABBA && snapshotABBA) && !(snapshotABBA && snapshot) && (!expire || (snapshot && !supplyABBA && !snapshotABBA))
    }
    static func canRetryScan(_ state:PhoneCameraState,display:Int,component:String,at time:Double,
                             frameReceivedAt:Double,retry:ScannerNavigationOCR.PlusRetry)->Bool {
        retry.attempts>0 && state.activities.first(where:{$0.displayId==display})?.component==component &&
            state.activeStreams==0 && state.ownerKnown && state.cameraOwner==nil &&
            retry.permitsTap(at:time,frameReceivedAt:frameReceivedAt)
    }
    static func navigationFrameIsCurrent(receivedAt:Double,startCommandIssuedAt:Double,now:Double)->Bool {
        receivedAt.isFinite && startCommandIssuedAt.isFinite && now.isFinite && startCommandIssuedAt>=0 &&
            receivedAt>=startCommandIssuedAt && receivedAt<=now && now-receivedAt<1
    }
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
                                 package:String,display:Int,startCommandIssuedAt:Double,evidence:inout [String:Any]) async throws ->Double? {
        let began=now,deadline=now+25
        if let entry=frames.latest() {
            evidence["navigationEntryFrameAgeMilliseconds"]=(began-entry.receivedAt)*1000
            evidence["navigationEntryFrameAfterStartCommandIssue"]=entry.receivedAt>=startCommandIssuedAt
            evidence["navigationEntryFrameBeforeNavigation"]=entry.receivedAt<began
        }
        var lastFrame=0,lastTap=0.0,scanTap:Double?,firstScanTap:Double?,scanComponent:String?
        var plusRetry=ScannerNavigationOCR.PlusRetry(),scanRetry=ScannerNavigationOCR.PlusRetry(),homeSelected=false
        var fixedLabels=Set<String>(),ocrFrames=0,staleAfterOCR=0
        var ocrCosts=[Double]()
        var postTapSamples=0,lastRouteKind="absent",lastOwnerEvidence="unknown",lastStreams=0
        defer {
            evidence["navigationScanTapSent"]=scanTap != nil;evidence["navigationPlusTaps"]=plusRetry.attempts
            evidence["navigationOCRFrames"]=ocrFrames;evidence["navigationKnownLabels"]=fixedLabels.sorted()
            evidence["navigationOCRMilliseconds"]=percentiles(ocrCosts)
            evidence["navigationFramesExpiredDuringOCR"]=staleAfterOCR
            evidence["navigationMilliseconds"]=(now-began)*1000
            evidence["navigationDiscoverTapSent"]=false
            evidence["navigationHomeTapSent"]=homeSelected
            evidence["navigationScanTapAttempts"]=scanRetry.attempts
            if let first=firstScanTap,let last=scanTap {evidence["navigationScanRetryDelayMilliseconds"]=(last-first)*1000}
            if postTapSamples>0 {
                evidence["postTapStateSamples"]=postTapSamples;evidence["postTapRouteKind"]=lastRouteKind
                evidence["postTapOwnerEvidence"]=lastOwnerEvidence;evidence["postTapActiveStreams"]=lastStreams
            }
        }
        while now<deadline {
            try Task.checkCancellation()
            guard frames.available.isAvailable else{throw Failure.mirror}
            let state=try await phone.cameraState()
            guard now<deadline else{break}
            if scanTap != nil {
                postTapSamples+=1;lastStreams=state.activeStreams
                lastOwnerEvidence = !state.ownerKnown ? "unknown":(state.cameraOwner==nil ? "closed":(state.cameraOwner==package ? "target":"other"))
                let activity=state.activities.first(where:{$0.displayId==display})
                if let activity {
                    lastRouteKind=activity.package != package ? "other":(activity.component==scanComponent ? "initial":(DesktopScannerRoute.isScanner(activity.component) ? "known-scanner":"other-target"))
                }else{lastRouteKind="absent"}
            }
            if state.captureActivity()?.package==package,state.captureActivity()?.displayId==display {
                evidence["cameraAlreadyActive"] = scanTap==nil
                return scanTap
            }
            guard let activity=state.activities.first(where:{$0.displayId==display}),activity.package==package,
                  let frame=frames.latest(),frame.sequence>lastFrame,
                  navigationFrameIsCurrent(receivedAt:frame.receivedAt,startCommandIssuedAt:startCommandIssuedAt,now:now),now-lastTap>0.8 else {
                try await Task.sleep(nanoseconds:60_000_000);continue
            }
            if scanTap != nil {
                // An unconfirmed click must not turn into a 25s blind wait.
                // Retry only a newly verified home/menu on the identical route,
                // with a known closed camera and a fresh post-tap observation.
                guard let component=scanComponent,canRetryScan(state,display:display,component:component,at:now,
                      frameReceivedAt:frame.receivedAt,retry:scanRetry) else {
                    try await Task.sleep(nanoseconds:60_000_000);continue
                }
            }
            lastFrame=frame.sequence
            let ocrBegan=now
            let words=try await Task.detached(priority:.userInitiated){try ScannerNavigationOCR.recognize(frame.pixels)}.value
            ocrCosts.append((now-ocrBegan)*1000)
            guard navigationFrameIsCurrent(receivedAt:frame.receivedAt,startCommandIssuedAt:startCommandIssuedAt,now:now) else {
                staleAfterOCR+=1;continue
            }
            guard now<deadline else{break}
            ocrFrames+=1
            let known:Set<String>=["首页","消息","理财","生活","我的","扫一扫","收付款","收付钱","微信","通讯录","发现","我","发起群聊","添加朋友","朋友圈","视频号","小程序","看一看"]
            fixedLabels.formUnion(words.compactMap{known.contains($0.value) ? $0.value:nil})
            var point:CGPoint?,isPlus=false,isHome=false
            if package=="com.tencent.mm" {
                let menu=words.contains{$0.value.contains("添加朋友")} && words.contains{$0.value.contains("发起群聊")}
                if let scan=WechatDiagnosticNavigation.scanRow(in:words) {point=scan}
                else if menu,let scan=words.first(where:{$0.value.replacingOccurrences(of:" ",with:"")=="扫一扫" && $0.rect.midY<800}) {
                    point=CGPoint(x:scan.rect.midX/720,y:scan.rect.midY/1280)
                } else if words.contains(where:{$0.value=="通讯录" && $0.rect.midY>1000}),
                          let plus=try ScannerNavigationOCR.plusButton(in:frame.pixels,homeWords:words),
                          plusRetry.permitsTap(at:now,frameReceivedAt:frame.receivedAt) {
                    point=CGPoint(x:plus.x/720,y:plus.y/1280);isPlus=true
                } else if !homeSelected,let home=WechatDiagnosticNavigation.homeTabFromDiscover(in:words) {
                    point=home;isHome=true
                }
                // A transition frame can have a title before its plus glyph is
                // visible. Stay on Home for a later verified frame; switching
                // to Discover here can strand navigation on a customized page.
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
                if scanTap != nil,(isPlus || isHome) {continue}
                if !isPlus && !isHome,!scanRetry.permitsTap(at:now,frameReceivedAt:frame.receivedAt) {continue}
                let current=try await phone.cameraState()
                guard current.activities.first(where:{$0.displayId==display})?.component==activity.component,
                      current.ownerKnown,current.cameraOwner==nil,current.activeStreams==0,
                      navigationFrameIsCurrent(receivedAt:frame.receivedAt,startCommandIssuedAt:startCommandIssuedAt,now:now) else{continue}
                let tap=now
                try Task.checkCancellation();guard tap<deadline else{break}
                if scanTap != nil {
                    guard let component=scanComponent,canRetryScan(current,display:display,component:component,at:tap,
                          frameReceivedAt:frame.receivedAt,retry:scanRetry) else{continue}
                }
                if isPlus,!plusRetry.permitsTap(at:tap,frameReceivedAt:frame.receivedAt) {continue}
                if !isPlus && !isHome,!scanRetry.permitsTap(at:tap,frameReceivedAt:frame.receivedAt) {continue}
                if isPlus {plusRetry.recordTap(at:tap,frameReceivedAt:frame.receivedAt)}
                else if isHome {homeSelected=true}
                else {
                    scanRetry.recordTap(at:tap,frameReceivedAt:frame.receivedAt)
                    if firstScanTap==nil {firstScanTap=tap;scanComponent=activity.component}
                    scanTap=tap
                }
                mirror.tap(x:point.x,y:point.y);lastTap=tap
            }
            try await Task.sleep(nanoseconds:60_000_000)
        }
        throw Failure.navigation
    }
    static func run() async -> Int32 {
        let alipayOnly=CommandLine.arguments.contains("--diagnostic-alipay-only"),wechatOnly=CommandLine.arguments.contains("--diagnostic-wechat-only")
        let supplyABBA=CommandLine.arguments.contains("--diagnostic-supply-abba")
        let snapshotABBA=CommandLine.arguments.contains("--diagnostic-snapshot-abba")
        let initialSnapshot=CommandLine.arguments.contains("--diagnostic-startup-snapshot")
        let abba=supplyABBA || snapshotABBA
        let immediateQR=CommandLine.arguments.contains("--diagnostic-immediate-qr")
        let expireWarmup=CommandLine.arguments.contains("--diagnostic-expire-stream-warmup")
        let probeQR=CommandLine.arguments.contains("--diagnostic-preview-timing")
        guard validScope(alipay:alipayOnly,wechat:wechatOnly,abba:abba),
              validExperiments(supplyABBA:supplyABBA,snapshotABBA:snapshotABBA,snapshot:initialSnapshot,expire:expireWarmup) else{return 2}
        guard CommandLine.arguments.contains("--diagnostic-usb"),CommandLine.arguments.contains("--locked-applications"),
              let path=option("--background-report"),let resources=Bundle.main.resourceURL else{return 2}
        let frontBefore=NSWorkspace.shared.frontmostApplication?.processIdentifier
        let journal=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/006IDC/DesktopWeChatScanner/session.json")
        guard !FileManager.default.fileExists(atPath:journal.path),
              NSRunningApplication.runningApplications(withBundleIdentifier:"com.idc006.DesktopWeChatScanner").allSatisfy({$0.processIdentifier==ProcessInfo.processInfo.processIdentifier}),
              let output=PrivateDiagnosticReport.openNew(path) else{return 2}
        // The product declares this activity while scanning. Keep this explicit
        // user-requested background test eligible for the same scheduling; do
        // not prevent display or system idle sleep. Always release after cleanup.
        let activity=ProcessInfo.processInfo.beginActivity(options:.userInitiatedAllowingIdleSystemSleep,
            reason:"用户请求的后台手机扫码验证")
        defer {ProcessInfo.processInfo.endActivity(activity)}
        var report:[String:Any]=["test":"background-owned-board-scan","physicalInputMeasured":false,"appControllerTested":false,
            "captureScope":"own-synthetic-board-only","activationRequested":false,"phoneVideoQRProbeEnabled":probeQR,
            "immediateSyntheticQR":immediateQR,"forcedExpiredStreamWarmup":expireWarmup,
            "userInitiatedActivityRequested":true,"idleSystemSleepAllowed":true]
        let adb=resources.appendingPathComponent("adb/bin/adb"),phone=PhoneSession(resources:resources,adbURL:adb)
        let capture=DesktopCapture()
        var board:BoardWindow?,mirror:MirrorSession?,recognitionTask:Task<Void,Never>?,streamWarmup:Task<Void,Error>?,items=[[String:Any]](),stage="prerequisites",passed=false
        do {
            guard CGPreflightScreenCaptureAccess() else{throw Failure.permission}
            report["existingCapturePermission"]=true
            let devices=try await ADBConnectionManager(adbURL:adb).devices().filter{$0.transport == .usb && $0.authorization == .authorized}
            guard devices.count==1 else{throw Failure.device}
            stage="diagnostic-preparation"
            let preparing=Task.detached(priority:.userInitiated){try SyntheticVisionPreparation.run()}
            let preparation=try await withTaskCancellationHandler(operation:{try await preparing.value},onCancel:{preparing.cancel()})
            report["diagnosticPreparationTextMilliseconds"]=preparation.textMilliseconds
            report["diagnosticPreparationBarcodeMilliseconds"]=preparation.barcodeMilliseconds
            report["diagnosticPreparationTotalMilliseconds"]=preparation.totalMilliseconds
            report["diagnosticPreparationScope"]="memory-only-synthetic-fixture-before-phone-session"
            try Task.checkCancellation()
            stage="connect"
            _=try await phone.connect(openWechatOnConnect:false,selectedSerial:devices[0].serial,allowLockedApplications:true,desktopHome:true,genericDesktopCamera:true){_ in}
            guard await phone.independentApplicationsWhenLocked,let display=await phone.scannerDisplay()?.id else{throw Failure.device}
            let apps=try await phone.applications()
            let packages=alipayOnly ? ["com.eg.android.AlipayGphone"]:(wechatOnly ? ["com.tencent.mm"]:["com.tencent.mm","com.eg.android.AlipayGphone"])
            let plans:[(String,Double,Bool)]
            if snapshotABBA {plans=[false,true,true,false].map{(packages[0],8,$0)}}
            else if supplyABBA {plans=[8.0,30.0,30.0,8.0].map{(packages[0],$0,initialSnapshot)}}
            else {plans=packages.map{($0,8,initialSnapshot)}}
            for (index,plan) in plans.enumerated() {
                let (package,cadence,snapshotBootstrap)=plan
                var item:[String:Any]=["application":package=="com.tencent.mm" ? "wechat":"alipay","recognized":false,
                    "supplyCadenceHz":cadence,"captureBootstrapMode":snapshotBootstrap ? "snapshot_then_stream":"stream_only"]
                var captureOperation:String?
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
                    item["launcherValidationMilliseconds"]=await phone.lastLauncherValidationMilliseconds
                    item["launcherQueryScoped"]=await phone.lastLauncherQueryScoped
                    item["launchStages"]=await phone.lastLaunchStages
                    guard let startCommandIssuedAt=await phone.lastApplicationStartCommandIssuedAt,
                          startCommandIssuedAt>=launch,startCommandIssuedAt<=now else{throw Failure.application}
                    stage="navigate"
                    let tap=try await navigate(phone:phone,mirror:stream,frames:frames,package:package,display:display,startCommandIssuedAt:startCommandIssuedAt,evidence:&item)
                    if let tap {
                        let last=(now-tap)*1000,retry=item["navigationScanRetryDelayMilliseconds"] as? Double ?? 0
                        item["scanTapMetricOrigin"]="last-verified-navigation-tap"
                        item["scanTapToOwnerMilliseconds"]=last;item["firstScanTapToOwnerMilliseconds"]=last+retry
                    }
                    let pump=CameraPumpMailbox(sourceIsAvailable:{frames.available.isAvailable})
                    // The final clear retires the previous application's epoch.
                    // The next application's frame epoch must advance past it.
                    let epoch=100+index*100
                    try await phone.clear(epoch:epoch,requireConnection:true)
                    await capture.setDiagnosticBoard(CGWindowID(window.windowNumber))
                    stage="capture-prepare"
                    let prepare=now;try await capture.prepare();item["capturePrepareMilliseconds"]=(now-prepare)*1000
                    let until=now+9,blankUntil=now+(immediateQR ? 0:1.5)
                    pump.prepareRegion(at:now,immediateFirst:true)
                    var qrShownAt:Double?,firstQRACK:Double?,firstACK:Double?,sent=0,recognized=false
                    var costs=[Double](),captures=[Double](),sourceVerificationCosts=[Double](),startTimes=[Double](),dispatchTimes=[Double](),ackTimes=[Double]()
                    var resultFrameTime:Double?
                    let result=BackgroundScanResult()
                    var verifiedQRAt:Double?
                    var streamSourceVerified=false
                    var snapshotAttempted=false
                    stage="capture-send-recognize"
                    while now<until {
                        let iteration=now
                        guard frames.available.isAvailable else{throw Failure.mirror}
                        if qrShownAt==nil,now>=blankUntil {
                            pattern.showQR=true;pattern.needsDisplay=true;pattern.displayIfNeeded();qrShownAt=now
                            recognitionTask=result.observe(frames:frames,payload:String(payload),after:qrShownAt!,until:until,probeQR:probeQR)
                        }
                        captureOperation="select_target"
                        let target=try DesktopCaptureTarget.current(for:window.frame)
                        pump.publish(target)
                        guard let selection=pump.selection() else{throw Failure.camera}
                        var imageWasSnapshot=false
                        do {
                            captureOperation="capture"
                            let begin=now,image:Data
                            if snapshotBootstrap,!snapshotAttempted {
                                snapshotAttempted=true;imageWasSnapshot=true
                                image=try await capture.captureDiagnosticSnapshot(selection.target,maximumDimension:720)
                                // The screenshot has completed before stream startup
                                // changes DesktopCapture's internal stream generation.
                                let warmingTarget=expireWarmup ? DesktopCaptureTarget(rect:target.rect,displayID:target.displayID,
                                    screenFrame:target.screenFrame,pixelSize:target.pixelSize,selectedAt:target.selectedAt-1):selection.target
                                streamWarmup=Task {try await capture.startDiagnosticStream(warmingTarget)}
                            } else {
                                if let warming=streamWarmup {
                                    do {
                                        try await withTaskCancellationHandler(operation:{try await warming.value},onCancel:{warming.cancel()})
                                        streamWarmup=nil;try Task.checkCancellation()
                                    } catch {
                                        streamWarmup=nil;try Task.checkCancellation()
                                        guard CGPreflightScreenCaptureAccess(),await !capture.permissionBlocked else{throw Failure.permission}
                                        item["streamWarmupFailed"]=true;item["startupSnapshotFallback"]=true
                                        await capture.stop()
                                    }
                                }
                                image=try await capture.capture(selection.target,maximumDimension:720)
                            }
                            captures.append((now-begin)*1000)
                            if qrShownAt != nil,(verifiedQRAt==nil || (snapshotBootstrap && !imageWasSnapshot && !streamSourceVerified)) {
                                captureOperation="verify_own_source"
                                // Diagnostic fixture validity only. Production
                                // generic camera delivery never decodes QR data.
                                let verificationBegan=now
                                let matches=try await Task.detached(priority:.userInitiated) {
                                    let request=VNDetectBarcodesRequest();request.symbologies=[.qr]
                                    try VNImageRequestHandler(data:image).perform([request])
                                    return request.results?.contains{$0.payloadStringValue==payload} ?? false
                                }.value
                                sourceVerificationCosts.append((now-verificationBegan)*1000)
                                if !matches {
                                    item[imageWasSnapshot ? "startupSnapshotSourceNotReady":"streamSourceNotReady"]=true
                                    continue
                                }
                                if verifiedQRAt==nil {verifiedQRAt=now}
                                if !imageWasSnapshot {streamSourceVerified=true;item["streamHandoffSourceVerified"]=true}
                            }
                            captureOperation="send_frame"
                            let receipt=try await phone.frame(image,epoch:epoch,selectedAt:target.selectedAt,isCurrent:{pump.isCurrent(selection) && pump.captureReady(at:ProcessInfo.processInfo.systemUptime)})
                            costs.append(receipt.requestMilliseconds);sent+=1;startTimes.append(iteration)
                            if let dispatch=receipt.requestStartedAt,dispatch.isFinite,dispatch>=iteration,dispatch<=now {
                                dispatchTimes.append(dispatch);ackTimes.append(dispatch+receipt.requestMilliseconds/1000)
                            }else{item["requestTimestampUnavailable"]=true}
                            if firstACK==nil {
                                firstACK=now;item["firstACKUsedSnapshot"]=imageWasSnapshot
                                item["firstCaptureMilliseconds"]=captures.last;item["firstImagePipelineMilliseconds"]=(now-begin)*1000
                                if let tap {
                                    let last=(now-tap)*1000,retry=item["navigationScanRetryDelayMilliseconds"] as? Double ?? 0
                                    item["scanTapToFirstACKMilliseconds"]=last;item["firstScanTapToFirstACKMilliseconds"]=last+retry
                                }
                            }
                            if qrShownAt != nil,firstQRACK==nil {firstQRACK=now}
                        } catch is DesktopCaptureTransientError {item["captureTransientOccurred"]=true;if imageWasSnapshot {item["startupSnapshotFallback"]=true}}
                        catch is CameraFrameExpiredError {item["expiredFrameOccurred"]=true}
                        if let qrShownAt,let verifiedQRAt,let match=result.snapshot(),sent>0,frames.available.isAvailable,
                           match.received>=verifiedQRAt,match.observed<=until,now<=until,(!snapshotBootstrap || streamSourceVerified) {
                            recognized=true;resultFrameTime=match.received;item["qrShownToResultDecodedMilliseconds"]=(match.received-qrShownAt)*1000
                            item["qrShownToResultObservedMilliseconds"]=(match.observed-qrShownAt)*1000
                            if let tap {
                                let last=(match.received-tap)*1000,retry=item["navigationScanRetryDelayMilliseconds"] as? Double ?? 0
                                item["scanTapToResultDecodedMilliseconds"]=last;item["firstScanTapToResultDecodedMilliseconds"]=last+retry
                            }
                            break
                        }
                        let rest=max(0,1/cadence-(now-iteration));if rest>0 {try await Task.sleep(nanoseconds:UInt64(rest*1_000_000_000))}
                    }
                    recognitionTask?.cancel();await recognitionTask?.value;recognitionTask=nil
                    item.merge(result.diagnostics()){_,new in new}
                    if probeQR {item["phoneVideoQRConfirmed"]=false;item["phoneVideoQRTextRelation"]="no_verified_qr"}
                    if let shown=qrShownAt,let verified=verifiedQRAt,let qr=result.qrSnapshot(),qr.received>=verified {
                        item["phoneVideoQRConfirmed"]=true
                        item["phoneVideoQRFrameSequence"]=qr.sequence
                        item["phoneVideoQRTextRelation"]="no_text"
                        item["qrShownToPhoneVideoQRMilliseconds"]=(qr.received-shown)*1000
                        item["verifiedSourceToPhoneVideoQRMilliseconds"]=(qr.received-verified)*1000
                        if let text=result.snapshot() {
                            item["phoneVideoTextFrameSequence"]=text.sequence
                            item["phoneVideoQRTextRelation"]=qr.sequence<text.sequence ? "before":(qr.sequence==text.sequence ? "same_frame":"after")
                            let earlier=qr.sequence<text.sequence && !qr.textAlreadyMatched
                            item["phoneVideoQRWitnessBeforeText"]=earlier
                            if earlier {item["phoneVideoQRToResultFrameMilliseconds"]=(text.received-qr.received)*1000}
                        }
                    }
                    item["capturedExpectedQRConfirmed"] = verifiedQRAt != nil
                    if let qrShownAt,let verifiedQRAt {item["qrShownToSourceVerifiedMilliseconds"]=(verifiedQRAt-qrShownAt)*1000}
                    captureOperation="final_state"
                    let finalState=try await phone.cameraState()
                    item["activeStreamsAtResultCheck"]=finalState.activeStreams
                    item["targetActivityAtResultCheck"]=finalState.activities.contains{$0.displayId==display && $0.package==package}
                    if let timing=finalState.paintTiming {item["phonePaintTiming"]=timing.diagnostics;item["phonePaintTimingScope"]="last-128-current-source-first-posts-since-clear"}
                    let videoTiming=stream.timingSnapshot
                    item["mirrorTimingScope"]="current-stream-last-240-samples"
                    item["mirrorDecodedFrames"]=videoTiming.decodedFrameCount
                    item["mirrorDecodeFailures"]=videoTiming.decodeFailureCount
                    item["mirrorDecodeP95Milliseconds"]=videoTiming.decodeP95Milliseconds
                    item["mirrorDecodeMaximumMilliseconds"]=videoTiming.decodeMaxMilliseconds
                    // Receive-minus-phone-PTS has unrelated clock origins;
                    // this is relative queue drift, never absolute latency.
                    item["mirrorRelativeBacklogP95Milliseconds"]=videoTiming.relativeBacklogP95Milliseconds
                    if let frames=await phone.encoderLatencyFrames(),frames>=0,frames<=120 {item["encoderReportedLatencyFrames"]=frames}
                    pump.stop();try await phone.clear(epoch:epoch+20,requireConnection:true)
                    item["recognized"]=recognized;item["sentFrames"]=sent
                    item["startupSnapshotAttempted"]=snapshotAttempted
                    item["sourceVerificationMilliseconds"]=percentiles(sourceVerificationCosts)
                    item["requestMilliseconds"]=percentiles(costs);item["captureMilliseconds"]=percentiles(captures)
                    item["loopIterationGapMilliseconds"]=percentiles(zip(startTimes.dropFirst(),startTimes).map{($0-$1)*1000})
                    item["sendStartGapMilliseconds"]=percentiles(zip(dispatchTimes.dropFirst(),dispatchTimes).map{($0-$1)*1000})
                    item["sendStartGapClock"]="phone_actor_request_start"
                    item["acknowledgementGapMilliseconds"]=percentiles(zip(ackTimes.dropFirst(),ackTimes).map{($0-$1)*1000})
                    if let qrShownAt,let firstQRACK {item["qrShownToFirstACKMilliseconds"]=(firstQRACK-qrShownAt)*1000}
                    guard recognized,verifiedQRAt != nil,sent>0,(!snapshotBootstrap || streamSourceVerified) else{throw Failure.result}
                    if abba,index+1<plans.count {
                        // Limit ordinary asynchronous BACK input to a fresh
                        // result of this run, checked against two owned snapshots.
                        // As with other mirror input, page transitions can race
                        // the queued event; this is not an atomic route command.
                        let before=try await phone.cameraState()
                        let after=try await phone.cameraState()
                        guard let resultFrameTime,now-resultFrameTime<1,
                              let activity=before.activities.first(where:{$0.displayId==display}),activity.package==package,
                              after.activities.first(where:{$0.displayId==display})?.component==activity.component else{throw Failure.navigation}
                        stream.key(4);item["ownResultBackSent"]=true
                        try await Task.sleep(nanoseconds:250_000_000)
                    }
                } catch {
                    if !(error is Failure) {item.merge(BackgroundDiagnosticFailure.fields(error)){_,new in new}}
                    if stage=="capture-send-recognize",let captureOperation {item["failureOperation"]=captureOperation}
                    if stage=="launch" {
                        item["launcherValidationMilliseconds"]=await phone.lastLauncherValidationMilliseconds
                        item["launcherQueryScoped"]=await phone.lastLauncherQueryScoped
                        item["launchStages"]=await phone.lastLaunchStages
                        item["launchPlacement"]=await phone.lastApplicationLaunchEvidence
                        if let validation=error as? AndroidTaskSnapshot.ValidationError {item["launchFailureKind"]="task_"+validation.reason.rawValue}
                        else if let scan=error as? ScanError,scan.message=="应用未出现在指定屏幕；已保留恢复记录。" {item["launchFailureKind"]="not_arrived"}
                    }
                    item["failureStage"]=stage;item["failureCode"]=(error as? Failure)?.rawValue ?? "backend"
                    items.append(item);throw error
                }
                items.append(item)
                streamWarmup?.cancel();await capture.stop();_ = try? await streamWarmup?.value;streamWarmup=nil
                await mirror?.stop();mirror=nil;try await phone.stopDirectMirror(display:display);board?.orderOut(nil);board=nil
            }
            passed=true
        } catch {
            report["failureStage"]=stage;report["failureCode"]=(error as? Failure)?.rawValue ?? "backend"
        }
        recognitionTask?.cancel();await recognitionTask?.value
        streamWarmup?.cancel();await capture.stop();_ = try? await streamWarmup?.value
        await mirror?.stop();board?.orderOut(nil)
        let cleanup=await phone.disconnect()
        report["applications"]=items;report["cleanupSucceeded"]=cleanup.isEmpty
        report["cleanupStage"]=await phone.cleanupStage
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
