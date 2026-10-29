import AppKit
import CoreVideo

// Compile with AndroidApplication.swift, ApplicationLibrary.swift,
// DesktopCameraInput.swift, CameraWindowAvailability.swift, MirrorVideoMailbox.swift and DetachedApplications.swift.
// Fake phone/mirror only; SilentWindow never enters the user's window stack.
struct ScanError:LocalizedError {
    let message:String
    init(_ message:String){self.message=message}
    var errorDescription:String?{message}
}
actor PhoneSession {
    struct Endpoint {let serial="synthetic-phone"}
    private var failCreate=false,failLaunch=false,failClose=false
    private var createHeld=false,launchHeld=false
    private var createGate:CheckedContinuation<Void,Never>?,launchGate:CheckedContinuation<Void,Never>?
    private(set) var created=[Int](),closed=[Int](),createEntered=0,launchEntered=0
    func configure(failCreate:Bool=false,failLaunch:Bool=false,failClose:Bool=false,holdCreate:Bool=false,holdLaunch:Bool=false){
        self.failCreate=failCreate;self.failLaunch=failLaunch;self.failClose=failClose
        createHeld=holdCreate;launchHeld=holdLaunch
    }
    func releaseCreate(){createHeld=false;createGate?.resume();createGate=nil}
    func releaseLaunch(){launchHeld=false;launchGate?.resume();launchGate=nil}
    func createAppDisplay() async throws->AndroidAppDisplay {
        createEntered+=1
        if createHeld {await withCheckedContinuation{createGate=$0}}
        if failCreate {throw ScanError("Synthetic display failure")}
        let id=7+created.count;created.append(id)
        return AndroidAppDisplay(id:id,width:1080,height:1920,dpi:420)
    }
    func mirrorEndpoint(display:Int)throws->Endpoint{Endpoint()}
    func directMirror(display:Int)throws->DirectMirrorDescriptor?{nil}
    func launchApplication(_ app:AndroidApplication,on display:Int) async throws->Bool {
        launchEntered+=1
        if launchHeld {await withCheckedContinuation{launchGate=$0}}
        try Task.checkCancellation()
        if failLaunch {throw DesktopCameraLaunchFailure(original:ScanError("Synthetic uncertain camera"))}
        return true
    }
    func closeAppDisplay(_ display:Int)throws {
        if failClose {throw ScanError("Synthetic restore failure")}
        closed.append(display)
    }
}
final class MirrorSession:@unchecked Sendable {
    struct Callbacks {let frame:@Sendable(CVPixelBuffer)->Void;let failure:@Sendable(String)->Void}
    private let lock=NSLock()
    private var callbacks=[Callbacks](),events=[String]()
    static var created=[MirrorSession]()
    init(){Self.created.append(self)}
    var callbackCount:Int {lock.withLock{callbacks.count}}
    var input:[String]{lock.withLock{events}}
    func touch(action:UInt8,x:Double,y:Double){lock.withLock{events.append("touch\(action)")}}
    func tap(x:Double,y:Double){lock.withLock{events.append("tap")}}
    func swipe(x1:Double,y1:Double,x2:Double,y2:Double){lock.withLock{events.append("swipe")}}
    func key(_ value:Int){lock.withLock{events.append("key\(value)")}}
    func startVideo(adbURL:URL,serverURL:URL,serial:String,displayID:Int,serverSocket:String?,direct:DirectMirrorDescriptor?,
                    onFrame:@escaping @Sendable(CVPixelBuffer)->Void,onFailure:@escaping @Sendable(String)->Void) async throws {
        lock.withLock{callbacks.append(Callbacks(frame:onFrame,failure:onFailure))}
        try Task.checkCancellation()
    }
    func emit(_ index:Int,pixels:CVPixelBuffer){let f=lock.withLock{callbacks[index].frame};f(pixels)}
    func fail(_ index:Int){let f=lock.withLock{callbacks[index].failure};f("Synthetic mirror failure")}
    func stop() async{}
}
@MainActor private final class SilentWindow:NSWindow {
    var presentations=0
    override func makeKeyAndOrderFront(_ sender:Any?){presentations+=1}
    override func deminiaturize(_ sender:Any?){}
}
@MainActor final class ControlWindowController:NSWindowController {
    static var created=[ControlWindowController]()
    var onTouch:((UInt8,Double,Double)->Void)?,onTap:((Double,Double)->Void)?
    var onSwipe:((Double,Double,Double,Double)->Void)?,onBack:(()->Void)?
    var status="",detail="",inputEnabled=true,lastWidth=0,gestureHeld=false
    init(title:String,standalone:Bool){
        let window=SilentWindow(contentRect:NSRect(x:0,y:0,width:360,height:600),styleMask:[.borderless],backing:.buffered,defer:false)
        window.ignoresMouseEvents=true;window.isReleasedWhenClosed=false
        super.init(window:window);Self.created.append(self)
    }
    required init?(coder:NSCoder){fatalError("unavailable")}
    override func showWindow(_ sender:Any?){}
    func update(status:String,detail:String,connected:Bool,busy:Bool,paused:Bool){self.status=status;self.detail=detail}
    func setPhonePixelBuffer(_ pixels:CVPixelBuffer?){lastWidth=pixels.map{CVPixelBufferGetWidth($0)} ?? 0}
    func setPhoneInteractionEnabled(_ enabled:Bool){
        if !enabled,gestureHeld {onTouch?(1,0.5,0.5);gestureHeld=false}
        inputEnabled=enabled
    }
}
@MainActor private final class ClearGate {
    private var continuation:CheckedContinuation<Bool,Never>?
    private(set) var entered=false
    func wait() async->Bool {entered=true;return await withCheckedContinuation{continuation=$0}}
    func release(_ value:Bool){continuation?.resume(returning:value);continuation=nil}
}
@main enum DetachedApplicationsTests {
    static func require(_ value:Bool,_ message:String){precondition(value,message)}
    @MainActor static func until(_ condition:@escaping () async->Bool) async throws {
        let deadline=Date().addingTimeInterval(4)
        while !(await condition()) {guard Date()<deadline else{fatalError("Synthetic lifecycle timed out")};try await Task.sleep(nanoseconds:5_000_000)}
    }
    static func pixels(_ width:Int)->CVPixelBuffer {
        var p:CVPixelBuffer?;precondition(CVPixelBufferCreate(nil,width,16,kCVPixelFormatType_32BGRA,nil,&p)==kCVReturnSuccess);return p!
    }
    @MainActor static func manager(_ phone:PhoneSession)->DetachedApplications {
        DetachedApplications(phone:phone,adb:URL(fileURLWithPath:"/synthetic/adb"),server:URL(fileURLWithPath:"/synthetic/server"))
    }
    @MainActor static func rejectedInputs(_ ui:ControlWindowController,_ mirror:MirrorSession){
        let before=mirror.input.count
        ui.onTouch?(0,0.5,0.5);ui.onTouch?(2,0.6,0.6);ui.onTouch?(1,0.6,0.6)
        ui.onTap?(0.5,0.5);ui.onSwipe?(0,0,1,1);ui.onBack?()
        require(mirror.input.count==before,"Input escaped a non-ready window")
        require(!ui.inputEnabled,"Non-ready phone view remained interactive")
    }
    @MainActor static func main() async throws {
        _=NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
        defer{for c in ControlWindowController.created{c.window?.orderOut(nil);c.window?.close()}}
        let app=AndroidApplication(packageName:"org.example.fixture",component:"org.example.fixture/.Main",name:"Fixture")
        let image=pixels(16),old=pixels(32)

        // A decoded frame during launch cannot open the input/camera gate.
        let p=PhoneSession();await p.configure(holdLaunch:true);let m=manager(p)
        var readyCallbacks=0;m.onCameraReady={readyCallbacks+=1}
        require(m.open(app,at:NSPoint(x:600,y:400)),"Open rejected")
        let ui=ControlWindowController.created.last!,mirror=MirrorSession.created.last!
        require((ui.window as? SilentWindow)?.presentations==1,"Window not revealed promptly")
        try await until{await p.launchEntered==1}
        mirror.emit(0,pixels:image);m.present();require(ui.lastWidth==16,"Loading frame not presented")
        require(m.cameraWindows().isEmpty,"Loading window became camera target")
        rejectedInputs(ui,mirror)
        await p.releaseLaunch();try await until{m.cameraWindows().count==1}
        require(readyCallbacks==1 && ui.inputEnabled,"Ready notification/input missing")
        ui.onTouch?(0,0.5,0.5);ui.gestureHeld=true
        let acceptedDown=mirror.input.count
        ui.onTouch?(0,0.6,0.6)
        require(mirror.input.count==acceptedDown,"Duplicate DOWN escaped an active gesture")

        // Failure retires immediately; clear is awaited before disposal/retry.
        let gate=ClearGate();var unavailableCalls=0,retiredBeforeHook=false
        m.onCameraUnavailable={_ in unavailableCalls+=1;retiredBeforeHook=m.cameraWindows().isEmpty;return Task{await gate.wait()}}
        let liveAvailability=m.cameraAvailability(display:7,window:ui)!
        DispatchQueue.global().sync{mirror.fail(0)}
        require(!liveAvailability.isAvailable && m.cameraWindows().isEmpty,"Failure waited for AppKit before retiring source")
        let beforeFailureInput=mirror.input.count
        ui.onTouch?(0,0.5,0.5);ui.onTap?(0.5,0.5);ui.onSwipe?(0,0,1,1);ui.onBack?()
        require(mirror.input.count==beforeFailureInput,"Failure admitted input before MainActor cleanup")
        mirror.emit(0,pixels:old);m.present();require(ui.lastWidth==16,"Failure admitted decoded frame before AppKit cleanup")
        try await until{gate.entered}
        require(m.cameraWindows().isEmpty && retiredBeforeHook,"Failed mirror stayed a camera target")
        require(mirror.input.last=="touch1","Disabling the old gesture dropped its UP")
        rejectedInputs(ui,mirror)
        mirror.emit(0,pixels:old);m.present();require(ui.lastWidth==16,"Failed mirror published another frame")
        require(m.open(app,at:nil) && m.open(app,at:nil),"Recovery intent rejected")
        let countBefore=await p.created.count
        require(countBefore==1 && unavailableCalls==1,"Retry bypassed pending camera clear")
        require(await p.closed.isEmpty,"Display closed before camera clear")
        gate.release(true)
        try await until{mirror.callbackCount==2 && m.cameraWindows().count==1}
        require(ControlWindowController.created.last === ui,"Retry replaced the Mac window")
        let retriedCreated=await p.created,retriedClosed=await p.closed
        require(retriedCreated.count==2 && retriedClosed==[7],"Retry did not serialize old disposal/new display")
        mirror.emit(0,pixels:old);mirror.fail(0);m.present()
        try await Task.sleep(nanoseconds:15_000_000)
        require(m.cameraWindows().count==1 && ui.lastWidth==0,"Old callback contaminated retry")
        mirror.emit(1,pixels:image);m.present();require(ui.lastWidth==16,"New attempt did not present")
        require(readyCallbacks==2,"Retry did not notify exactly once")
        let n=mirror.input.count;ui.onTap?(0.5,0.5);ui.onSwipe?(0,0,1,1);ui.onBack?()
        require(mirror.input.count==n+3,"Ready input did not resume")
        m.onCameraUnavailable={_ in Task{true}}
        require(m.windowShouldClose(ui.window!)==false && m.cameraWindows().isEmpty,"Close kept ready target")
        rejectedInputs(ui,mirror)
        try await until{await p.closed.count==2};await m.stop()
        require(!m.open(app,at:nil),"Stopped manager reopened")

        // A late launch success cannot overwrite a failure or notify readiness.
        let early=PhoneSession();await early.configure(holdLaunch:true);let em=manager(early)
        var earlyReady=0;em.onCameraReady={earlyReady+=1}
        require(em.open(app,at:nil),"Early fixture rejected")
        let eu=ControlWindowController.created.last!,ev=MirrorSession.created.last!
        try await until{await early.launchEntered==1};ev.fail(0)
        try await until{eu.status=="正在清理中断窗口"};await early.releaseLaunch()
        try await until{eu.status=="应用打开失败"}
        require(earlyReady==0 && em.cameraWindows().isEmpty,"Late launch resurrected failed mirror")
        rejectedInputs(eu,ev);await em.stop()

        // Failed creation can be retried in the same window after cleanup.
        let failed=PhoneSession();await failed.configure(failCreate:true);let fm=manager(failed)
        require(fm.open(app,at:nil),"Failure fixture rejected")
        let fu=ControlWindowController.created.last!
        try await until{fu.status=="应用打开失败"}
        await failed.configure();require(fm.open(app,at:nil),"Failed entry could not retry")
        try await until{fm.cameraWindows().count==1}
        require(ControlWindowController.created.last === fu,"Failure retry allocated another Mac window")
        require(await failed.createEntered==2,"Failure retry did not launch again")
        await fm.stop()

        // Closing while create is blocked still owns the late display result.
        let late=PhoneSession();await late.configure(holdCreate:true);let lm=manager(late)
        require(lm.open(app,at:nil),"Late create rejected")
        let lu=ControlWindowController.created.last!;try await until{await late.createEntered==1}
        require(lm.windowShouldClose(lu.window!)==false && !lm.open(app,at:nil),"Closing entry accepted open")
        await late.releaseCreate();try await until{await late.closed==[7]};await lm.stop()

        // A failed camera clear never discards the display or permits retry.
        let uncertain=PhoneSession(),um=manager(uncertain);var alarms=0
        um.onCameraCleanupFailure={_ in alarms+=1};um.onCameraUnavailable={_ in Task{false}}
        require(um.open(app,at:nil),"Uncertain fixture rejected")
        let uu=ControlWindowController.created.last!,uv=MirrorSession.created.last!
        try await until{um.cameraWindows().count==1};uv.fail(0)
        try await until{alarms==1};rejectedInputs(uu,uv)
        require(await uncertain.closed.isEmpty,"Unconfirmed camera cleanup lost display ownership")
        require(!um.open(app,at:nil),"Uncertain camera permitted local retry")
        await um.stop()

        // Uncertain binding rollback forces whole-session recovery, even when
        // this display never became an active desktop camera in App.
        let binding=PhoneSession();await binding.configure(failLaunch:true);let bm=manager(binding);var bindingAlarms=0
        bm.onCameraCleanupFailure={_ in bindingAlarms+=1}
        require(bm.open(app,at:nil),"Binding fixture rejected")
        try await until{bindingAlarms==1}
        require(bm.cameraWindows().isEmpty && !bm.open(app,at:nil),"Uncertain binding allowed ready/retry")
        await bm.stop();require(await binding.closed.isEmpty,"Uncertain binding discarded its display")

        // A failed task restoration must finish before creating a replacement.
        let restore=PhoneSession(),rm=manager(restore)
        require(rm.open(app,at:nil),"Restore fixture rejected")
        let ru=ControlWindowController.created.last!,rv=MirrorSession.created.last!
        try await until{rm.cameraWindows().count==1};await restore.configure(failClose:true);rv.fail(0)
        try await until{ru.status=="旧窗口清理未完成"}
        require(await restore.created.count==1,"Restore failure allocated another display")
        await restore.configure();require(rm.open(app,at:nil),"Cleanup retry rejected")
        try await until{rm.cameraWindows().count==1}
        let restoredClosed=await restore.closed,restoredCreated=await restore.created
        require(restoredClosed==[7] && restoredCreated.count==2,"Cleanup retry did not preserve ownership")
        await rm.stop()

        // Stop joins pending recovery and suppresses an explicit queued retry.
        let stopPhone=PhoneSession(),sm=manager(stopPhone),stopGate=ClearGate()
        sm.onCameraUnavailable={_ in Task{await stopGate.wait()}}
        require(sm.open(app,at:nil),"Stop fixture rejected")
        let sv=MirrorSession.created.last!;try await until{sm.cameraWindows().count==1};sv.fail(0)
        try await until{stopGate.entered};require(sm.open(app,at:nil),"Queued retry rejected")
        let stopping=Task{await sm.stop()};try await Task.sleep(nanoseconds:10_000_000)
        stopGate.release(true);await stopping.value
        let stoppedCreated=await stopPhone.created,stoppedClosed=await stopPhone.closed
        require(stoppedCreated.count==1 && stoppedClosed.isEmpty,"Stop retried or raced global restoration")
        require(ControlWindowController.created.allSatisfy{$0.window?.isVisible==false},"Test exposed a window")
        print("PASS startup input gates, mirror failure retirement, camera-clear barrier, same-window retry, old callback fencing, late creation/launch, uncertain cleanup and stop; fake device, no ordered windows")
    }
}
