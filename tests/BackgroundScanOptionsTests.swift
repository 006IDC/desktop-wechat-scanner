import Foundation

@main enum BackgroundScanOptionsTests {
    @MainActor static func main() {
        // Contract table: ordinary all-app scope; one selected app with/without
        // ABBA. Both only flags and an unscoped ABBA are always invalid.
        let allowedScopes:Set<Int>=[0,2,3,4,5]
        for alipay in [false,true] {
            for wechat in [false,true] {
                for abba in [false,true] {
                    let key=(alipay ? 4:0)+(wechat ? 2:0)+(abba ? 1:0)
                    let expected=allowedScopes.contains(key)
                    precondition(BackgroundScanDiagnostic.validScope(alipay:alipay,wechat:wechat,abba:abba)==expected,"Invalid background scan scope accepted")
                }
            }
        }
        // stream/snapshot singles; fault only on a single snapshot; either
        // ABBA family separately (snapshot may be fixed during supply ABBA).
        let allowedExperiments:Set<Int>=[0,2,3,4,8,10]
        for supply in [false,true] {
            for snapshotABBA in [false,true] {
                for snapshot in [false,true] {
                    for expire in [false,true] {
                        let key=(supply ? 8:0)+(snapshotABBA ? 4:0)+(snapshot ? 2:0)+(expire ? 1:0)
                        let expected=allowedExperiments.contains(key)
                        precondition(BackgroundScanDiagnostic.validExperiments(supplyABBA:supply,snapshotABBA:snapshotABBA,snapshot:snapshot,expire:expire)==expected,"Conflicting capture experiments accepted")
                    }
                }
            }
        }
        print("PASS diagnostic scope and mutually exclusive experiment combinations; no window or phone")
    }
}
