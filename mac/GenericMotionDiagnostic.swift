import AppKit

/// Explicit research only: move our own non-key, mouse-ignoring board behind
/// normal windows. DesktopCapture is already restricted to that board. No
/// pointer events, user windows, application activation or permission requests.
@MainActor enum GenericMotionDiagnostic {
    enum Failure:Error {case scope,owner,source,comparison}
    private final class Publication {var ready=false}
    private static var now:Double {ProcessInfo.processInfo.systemUptime}
    static func succeeded(_ rows:[[String:Any]])->Bool {
        rows.count==4 && rows[0]["framesAcknowledgedDuringMotion"] as? Int==0 &&
            rows[3]["framesAcknowledgedDuringMotion"] as? Int==0 &&
            (rows[1]["framesAcknowledgedDuringMotion"] as? Int ?? 0)>0 &&
            (rows[2]["framesAcknowledgedDuringMotion"] as? Int ?? 0)>0
    }
    static func run(capture:DesktopCapture,phone:PhoneSession,window:NSWindow,display:Int,package:String,epoch:Int,nativeLease:PhoneSession.NativePreviewLease?=nil,
                    available:@escaping @Sendable ()->Bool,draw:@escaping @MainActor (Double?)->Void) async throws ->[[String:Any]] {
        let original=window.frame
        guard NSApp.activationPolicy() == .prohibited,window.isVisible,!window.canBecomeKey,!window.canBecomeMain,
              window.ignoresMouseEvents,window.level.rawValue == -1000,
              window.screen?.visibleFrame.contains(original.insetBy(dx:-8,dy:0))==true else{throw Failure.scope}
        guard await capture.isPreparedDiagnosticBoard(CGWindowID(window.windowNumber)) else{throw Failure.scope}
        defer{window.setFrame(original,display:true);draw(nil)}
        var rows=[[String:Any]]()
        for (index,continuous) in [false,true,true,false].enumerated() {
            try Task.checkCancellation()
            let state=try await phone.cameraState()
            guard let owner=state.captureActivity(),owner.displayId==display,owner.package==package else{throw Failure.owner}
            let pump=CameraPumpMailbox(sourceIsAvailable:available),publication=Publication()
            pump.prepareRegion(at:now,immediateFirst:true,continuousMovement:continuous)
            pump.publish(try DesktopCaptureTarget.current(for:original))
            let began=now,until=began+3
            let producer=Task { @MainActor in
                do {
                    while now<until {
                        try Task.checkCancellation();guard available() else{throw Failure.source}
                        if continuous {pump.invalidateRegion()}
                        else {pump.delayCapture(until:now+0.18)}
                        let phase=now-began
                        window.setFrameOrigin(NSPoint(x:original.minX+8*sin(phase*4),y:original.minY))
                        draw(phase)
                        pump.prepareRegion(at:now,immediateFirst:true,continuousMovement:continuous)
                        pump.publish(try DesktopCaptureTarget.current(for:window.frame));publication.ready=true
                        try await Task.sleep(nanoseconds:33_333_333)
                    }
                } catch {pump.fail(error);throw error}
            }
            var sent=0,dropped=0,late=0,costs=[Double](),first:Double?,nativePacer=NativeCapturePacer()
            do {
                while now<until {
                    try Task.checkCancellation();guard available() else{throw Failure.source}
                    if let failure=pump.snapshot().failure {throw failure}
                    guard publication.ready,pump.captureReady(at:now),let selection=pump.selection() else {
                        try await Task.sleep(nanoseconds:10_000_000);continue
                    }
                    let iteration=now
                    if nativeLease != nil,!nativePacer.admit(publishedAt:selection.target.selectedAt,now:iteration) {
                        try await Task.sleep(nanoseconds:2_000_000);continue
                    }
                    do {
                        let image=try await capture.capture(selection.target,maximumDimension:720)
                        guard now<until else{break}
                        let receipt=try await phone.frame(image,epoch:epoch,selectedAt:selection.target.selectedAt,
                            isCurrent:{pump.isCurrent(selection) && pump.captureReady(at:ProcessInfo.processInfo.systemUptime)},nativeLease:nativeLease)
                        if now<until {
                            sent+=1;costs.append(receipt.requestMilliseconds)
                            if first==nil{first=(now-began)*1000}
                        }else{late+=1}
                    }catch is DesktopCaptureTransientError {dropped+=1}
                    catch is CameraFrameExpiredError {dropped+=1}
                    let rest=nativeLease == nil ? 0.125-(now-iteration):0
                    if rest>0{try await Task.sleep(nanoseconds:UInt64(rest*1_000_000_000))}
                }
            } catch {
                pump.stop();producer.cancel();_ = try? await producer.value;throw error
            }
            pump.stop();producer.cancel()
            do{try await producer.value}catch is CancellationError {}
            let after=try await phone.cameraState()
            guard let afterOwner=after.captureActivity(),afterOwner.displayId==display,afterOwner.package==package else{throw Failure.owner}
            var row:[String:Any]=["round":index+1,"continuousMovement":continuous,"durationMilliseconds":(now-began)*1000,
                "framesAcknowledgedDuringMotion":sent,"lateAcknowledgements":late,"droppedFrames":dropped]
            if let first{row["firstAcknowledgementMilliseconds"]=first}
            if !costs.isEmpty {row["maximumRequestMilliseconds"]=costs.max()!}
            rows.append(row)
        }
        return rows
    }
}
