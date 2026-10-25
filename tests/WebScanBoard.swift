import AppKit
import WebKit

// Offline webpage fixture. QR pixels are the repository's synthetic C3 PNG.
// This executable never connects to a phone or navigates to an external page.
@MainActor
private final class WebScanBoardController:NSObject,NSApplicationDelegate,NSWindowDelegate,WKNavigationDelegate {
    private var window:NSWindow!
    private var web:WKWebView!
    private var imageBase64=""
    private let showButton=NSButton(title:"显示测试二维码",target:nil,action:nil)
    private let hideButton=NSButton(title:"隐藏二维码",target:nil,action:nil)
    private let status=NSTextField(labelWithString:"纯合成网页 · 二维码已隐藏")

    func applicationDidFinishLaunching(_ notification:Notification) {
        do {
            let repository=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent()
            let qr=Bundle.main.url(forResource:"qr",withExtension:"png")
                ?? repository.appendingPathComponent(".local/ui-test/qr.png")
            imageBase64=try Data(contentsOf:qr).base64EncodedString()
        } catch {
            FileHandle.standardError.write(Data(("Synthetic QR fixture unavailable: "+error.localizedDescription+"\n").utf8))
            NSApp.terminate(nil);return
        }
        let menu=NSMenu(),appItem=NSMenuItem(),appMenu=NSMenu()
        appMenu.addItem(withTitle:"退出验收",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        appItem.submenu=appMenu;menu.addItem(appItem);NSApp.mainMenu=menu
        let frame=NSScreen.main?.visibleFrame ?? NSRect(x:0,y:0,width:1100,height:760)
        window=NSWindow(contentRect:frame,styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title="网页扫码验收（合成）";window.delegate=self
        window.setFrame(frame,display:false)
        let configuration=WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript=false
        web=WKWebView(frame:.zero,configuration:configuration)
        web.navigationDelegate=self
        showButton.target=self;showButton.action=#selector(showQR)
        hideButton.target=self;hideButton.action=#selector(hideQR)
        for button in [showButton,hideButton] {
            button.bezelStyle = .rounded
            button.setAccessibilityLabel(button.title)
            button.heightAnchor.constraint(greaterThanOrEqualToConstant:32).isActive=true
        }
        status.font = .systemFont(ofSize:13)
        status.textColor = .secondaryLabelColor
        let tools=NSStackView(views:[showButton,hideButton,status])
        tools.orientation = .horizontal;tools.spacing=12;tools.alignment = .centerY
        tools.translatesAutoresizingMaskIntoConstraints=false;web.translatesAutoresizingMaskIntoConstraints=false
        let content=window.contentView!
        content.addSubview(tools);content.addSubview(web)
        NSLayoutConstraint.activate([
            tools.topAnchor.constraint(equalTo:content.topAnchor,constant:10),
            tools.leadingAnchor.constraint(equalTo:content.leadingAnchor,constant:16),
            tools.trailingAnchor.constraint(lessThanOrEqualTo:content.trailingAnchor,constant:-16),
            web.topAnchor.constraint(equalTo:tools.bottomAnchor,constant:10),
            web.leadingAnchor.constraint(equalTo:content.leadingAnchor),
            web.trailingAnchor.constraint(equalTo:content.trailingAnchor),
            web.bottomAnchor.constraint(equalTo:content.bottomAnchor)
        ])
        setQRVisible(false)
        window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
    }

    @objc private func showQR(){setQRVisible(true)}
    @objc private func hideQR(){setQRVisible(false)}
    private func setQRVisible(_ visible:Bool) {
        showButton.isEnabled = !visible;hideButton.isEnabled=visible
        status.stringValue=visible ? "纯合成网页 · C3 二维码已显示" : "纯合成网页 · 二维码已隐藏"
        let html="""
        <!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; script-src 'none'; connect-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'">
        <style>
        *{box-sizing:border-box}html,body{width:100%;height:100%;margin:0;overflow:hidden}
        body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;background:#d6e3ee;color:#304c67}
        #board{position:absolute;inset:0;background-image:linear-gradient(#adc3d580 1px,transparent 1px),linear-gradient(90deg,#adc3d580 1px,transparent 1px);background-size:48px 48px}
        #copy{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;text-align:center;padding:40px;pointer-events:none}
        h1{font-size:clamp(36px,5vw,76px);margin:0 0 24px;font-weight:650}p{font-size:24px;line-height:1.65;margin:0}
        body.qr #board{background-color:white;background-image:url('data:image/png;base64,\(imageBase64)');background-size:96px 96px;background-repeat:repeat}
        body.qr #copy{display:none}
        </style></head><body class="\(visible ? "qr" : "")"><div id="board"></div><div id="copy"><main>
        <h1>网页扫码验收 · 合成页面</h1><p>拖动手机窗口，观察网页网格的位置与移动。<br>点击上方“显示测试二维码”开始识别验收。<br>此页面离线，不含账号、登录或付款操作。</p>
        </main></div></body></html>
        """
        web.loadHTMLString(html,baseURL:nil)
    }
    func webView(_ webView:WKWebView,decidePolicyFor navigationAction:WKNavigationAction,
                 decisionHandler:@escaping (WKNavigationActionPolicy)->Void) {
        // loadHTMLString uses about:blank. No HTTP, HTTPS, file navigation or new page is allowed.
        decisionHandler(navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool {true}
}

@main struct WebScanBoard {
    @MainActor static func main() {
        let app=NSApplication.shared;app.setActivationPolicy(.regular)
        let controller=WebScanBoardController();app.delegate=controller
        withExtendedLifetime(controller){app.run()}
    }
}
