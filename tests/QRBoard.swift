import AppKit
let app=NSApplication.shared
app.setActivationPolicy(.regular)
let window=NSWindow(contentRect:NSRect(x:0,y:0,width:400,height:400),styleMask:[.titled],backing:.buffered,defer:false)
window.title="桌面扫码 · 纯文本测试二维码"
window.backgroundColor = .white
window.center()
let side=CommandLine.arguments.count>3 ? Double(CommandLine.arguments[3]) ?? 320 : 320
let image=NSImageView(frame:NSRect(x:(400-side)/2,y:(400-side)/2,width:side,height:side))
image.image=NSImage(contentsOfFile:CommandLine.arguments[1]);image.imageScaling = .scaleProportionallyUpOrDown
window.contentView?.addSubview(image)
window.makeKeyAndOrderFront(nil);app.activate(ignoringOtherApps:true)
let rect=window.convertToScreen(image.frame)
let data=try JSONEncoder().encode([rect.minX,rect.minY,rect.width,rect.height])
try data.write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
DispatchQueue.main.asyncAfter(deadline:.now()+120){app.terminate(nil)}
app.run()
