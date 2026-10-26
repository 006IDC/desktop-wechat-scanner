import AppKit

// Manual synthetic fixture: verify the center shows the blue desktop, while
// the orange top and green bottom stay visible and forward phone taps. Press
// the fixture Scan button to re-enable the aperture, Back to restore all pixels.
// Running or compiling this fixture alone does not prove native click targeting.
@MainActor final class PreviewFixture:NSObject,NSApplicationDelegate {
    let control=ControlWindowController()
    let background=NSWindow(contentRect:NSRect(x:100,y:100,width:660,height:760),styleMask:[.titled,.closable],backing:.buffered,defer:false)
    let label=NSTextField(labelWithString:"背景点击 0 · 手机点击 0")
    private var backgroundHits=0,phoneHits=0
    func applicationDidFinishLaunching(_ n:Notification){
        let menu=NSMenu(),item=NSMenuItem(),app=NSMenu()
        app.addItem(withTitle:"退出测试",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        item.submenu=app;menu.addItem(item);NSApp.mainMenu=menu
        background.title="合成透明预览测试底图"
        background.backgroundColor=NSColor(calibratedRed:0.12,green:0.48,blue:0.84,alpha:1)
        let button=NSButton(title:"合成背景按钮",target:self,action:#selector(hitBackground))
        button.bezelStyle = .rounded;button.frame=NSRect(x:180,y:280,width:240,height:180)
        background.contentView!.addSubview(button)
        label.frame=NSRect(x:12,y:12,width:630,height:40);label.textColor = .white
        label.font = .systemFont(ofSize:20);background.contentView!.addSubview(label)
        background.makeKeyAndOrderFront(nil)
        control.window?.title="本地预览验收（合成）"
        control.setPhoneImage(NSImage(size:NSSize(width:1268,height:2756),flipped:false){r in
            NSColor.systemIndigo.setFill();r.fill()
            NSColor.systemOrange.setFill()
            NSRect(x:0,y:r.height*0.84,width:r.width,height:r.height*0.16).fill()
            NSColor.systemGreen.setFill()
            NSRect(x:0,y:0,width:r.width,height:r.height*0.25).fill()
            return true
        })
        control.update(status:"透明预览测试",detail:"纯合成；无手机连接",connected:true,busy:false,paused:false)
        control.setCameraActive(true);control.setLocalScanPreview(true)
        control.onScan={ [weak self] in self?.control.setLocalScanPreview(true) }
        control.onBack={ [weak self] in self?.control.setLocalScanPreview(false) }
        control.onTap={ [weak self] x,y in
            guard let self else{return}
            self.phoneHits+=1
            print(String(format:"PHONE_TAP x=%.3f y=%.3f region=%@",x,y,
                         y < 0.16 ? "top" : (y >= 0.75 ? "bottom" : "center")))
            self.report()
        }
        control.showWindow(nil)
        control.window?.contentView?.layoutSubtreeIfNeeded()
        let phone=control.desktopCaptureRect,target=background.convertToScreen(button.frame).center
        if let window=control.window {window.setFrameOrigin(NSPoint(x:window.frame.minX+target.x-phone.midX,y:window.frame.minY+target.y-phone.midY))}
        NSApp.activate(ignoringOtherApps:true);report()
    }
    @objc func hitBackground(){backgroundHits+=1;report()}
    func report(){label.stringValue="背景点击 \(backgroundHits) · 手机点击 \(phoneHits)";print("HITS background=\(backgroundHits) phone=\(phoneHits)");fflush(stdout)}
}
private extension CGRect {var center:CGPoint {CGPoint(x:midX,y:midY)}}
@main struct LocalScanPreview { @MainActor static func main(){let app=NSApplication.shared;app.setActivationPolicy(.regular);let fixture=PreviewFixture();app.delegate=fixture;withExtendedLifetime(fixture){app.run()}} }
