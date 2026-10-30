import Foundation
import CoreGraphics

@main enum WechatDiagnosticNavigationTests {
    static func word(_ value:String,_ x:CGFloat,_ y:CGFloat)->ScannerNavigationOCR.Text {
        .init(value:value,rect:CGRect(x:x,y:y,width:72,height:28))
    }
    static func main() {
        let tabs=[word("微信",20,1170),word("通讯录",200,1170),word("发现",390,1170),word("我",600,1170)]
        let home=tabs+[word("微信（2）",30,40)]
        precondition(WechatDiagnosticNavigation.discoverTab(in:home) != nil)
        precondition(WechatDiagnosticNavigation.discoverTab(in:tabs)==nil)
        precondition(WechatDiagnosticNavigation.scanRow(in:home+[word("扫一扫",20,500)])==nil,"Home/chat text passed as Discover menu")
        let discover=tabs+[word("发现",30,40),word("朋友圈",30,200),word("扫一扫",30,430)]
        let scan=WechatDiagnosticNavigation.scanRow(in:discover)
        precondition(scan != nil && scan!.y>0.3 && scan!.y<0.4)
        precondition(WechatDiagnosticNavigation.scanRow(in:discover.filter{$0.value != "朋友圈"})==nil)
        precondition(WechatDiagnosticNavigation.scanRow(in:discover.filter{$0.rect.midY<1000})==nil)
        precondition(WechatDiagnosticNavigation.scanRow(in:discover.map{$0.value=="扫一扫" ? word("扫一扫",30,1100):$0})==nil)
        precondition(WechatDiagnosticNavigation.homeTabFromDiscover(in:discover.filter{$0.value != "扫一扫"}) != nil)
        precondition(WechatDiagnosticNavigation.homeTabFromDiscover(in:home)==nil)
        precondition(WechatDiagnosticNavigation.homeTabFromDiscover(in:tabs)==nil)
        precondition(WechatDiagnosticNavigation.homeTabFromDiscover(in:discover.filter{$0.rect.midY<1000})==nil)
        precondition(WechatDiagnosticNavigation.homeTabFromDiscover(in:discover.filter{$0.value != "朋友圈"})==nil)
        print("PASS guarded native Discover fallback; rejects absent Home/title/menu/tabs and wrong scan region; no device/UI")
    }
}
