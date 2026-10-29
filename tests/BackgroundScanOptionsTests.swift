import Foundation

@main enum BackgroundScanOptionsTests {
    @MainActor static func main() {
        for alipay in [false,true] {
            for wechat in [false,true] {
                for abba in [false,true] {
                    let expected=abba ? (alipay != wechat):(!(alipay && wechat))
                    precondition(BackgroundScanDiagnostic.validScope(alipay:alipay,wechat:wechat,abba:abba)==expected,"Invalid background scan scope accepted")
                }
            }
        }
        print("PASS all eight background diagnostic scope combinations; no window or phone")
    }
}
