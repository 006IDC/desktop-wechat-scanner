import Foundation

@main enum PhoneCameraStateTests {
    private static let wechat = "com.tencent.mm/.plugin.scanner.ui.BaseScanUI"
    private static let fullWechat = "com.tencent.mm/com.tencent.mm.plugin.scanner.ui.BaseScanUI"
    private static let alipay = "com.eg.android.AlipayGphone/com.alipay.mobile.scan.as.main.MainCaptureActivity"

    private static func require(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }
    }

    private static func decode(_ fields: [String: Any]) throws -> PhoneCameraState {
        try PhoneCameraState.decode(JSONSerialization.data(withJSONObject: fields))
    }

    private static func activity(_ display: Int, _ component: String) -> [String: Any] {
        ["displayId": display, "component": component]
    }

    private static func basic() -> [String: Any] {
        ["version": 1, "generation": 1, "activeStreams": 1,
         "activities": [activity(7, wechat)], "desktopHome": true,
         "cameraOwner": "com.tencent.mm", "ownerKnown": true, "ownerGeneration": 3]
    }

    private static func rejected(_ fields: [String: Any], _ message: String) {
        do { _ = try decode(fields); fatalError(message) } catch is DecodingError { return }
        catch { return }
    }

    static func main() throws {
        let matched = try decode(basic())
        require(matched.scannerActivity()?.displayId == 7 && matched.ownerGeneration == 3,
                "Known virtual camera owner did not match the verified WeChat scanner")

        require(!matched.solidCalibrationSupported,"Absent capability must preserve the PNG path")
        var capability=basic();capability["solidCalibrationSupported"]=true
        require(try decode(capability).solidCalibrationSupported,"Explicit capability was lost")
        capability["ownerKnown"]=false
        require(try decode(capability).scannerActivity()==nil,"Calibration capability bypassed owner validation")
        capability=basic();capability["solidCalibrationSupported"]=NSNull()
        require(try !decode(capability).solidCalibrationSupported,"Null capability must preserve the PNG path")
        capability["solidCalibrationSupported"]="true"
        rejected(capability,"Non-boolean calibration capability was accepted")

        var fields = basic()
        fields["activities"] = [activity(7, fullWechat)]
        require(try decode(fields).scannerActivity()?.component == fullWechat,
                "Canonical full WeChat scanner component rejected")
        fields = basic()
        fields["activities"] = [activity(9, alipay)]
        fields["cameraOwner"] = "com.eg.android.AlipayGphone"
        require(try decode(fields).scannerActivity()?.component == alipay,
                "True-device Alipay scanner component rejected")

        fields = basic()
        fields.removeValue(forKey: "cameraOwner")
        fields.removeValue(forKey: "ownerKnown")
        fields.removeValue(forKey: "ownerGeneration")
        let legacy = try decode(fields)
        require(!legacy.ownerKnown && legacy.cameraOwner == nil && legacy.ownerGeneration == 0 &&
                legacy.scannerActivity() == nil, "Legacy server was treated as an identified camera owner")

        fields = basic(); fields["ownerKnown"] = false
        require(try decode(fields).scannerActivity() == nil, "Unknown owner triggered desktop capture")
        fields = basic(); fields["cameraOwner"] = NSNull()
        require(try decode(fields).scannerActivity() == nil, "No camera owner triggered desktop capture")
        fields = basic(); fields["activeStreams"] = 0
        require(try decode(fields).scannerActivity() == nil, "Idle camera triggered desktop capture")
        fields = basic(); fields["cameraOwner"] = "org.example.other"
        require(try decode(fields).scannerActivity() == nil, "Another package claimed WeChat's scanner")

        fields = basic()
        fields["activities"] = [activity(7, wechat), activity(8, fullWechat)]
        require(try decode(fields).scannerActivity() == nil,
                "Concurrent verified scanner activities selected a desktop disclosure target")
        fields = basic()
        fields["activities"] = [activity(7, wechat), activity(8, "com.tencent.mm/.ui.LauncherUI")]
        require(try decode(fields).scannerActivity() == nil,
                "A second owned WeChat foreground left camera ownership ambiguous")
        fields = basic()
        fields["activities"] = [activity(7, wechat), activity(8, "org.example.other/.Main")]
        require(try decode(fields).scannerActivity()?.displayId == 7,
                "An unrelated foreground app incorrectly blocked the verified camera owner")
        fields = basic()
        fields["activities"] = [activity(7, "com.tencent.mm/.plugin.scanner.ui.ScannerPreviewUI")]
        require(try decode(fields).scannerActivity() == nil, "Related scanner package guessed as a verified route")
        fields = basic()
        fields["activities"] = [activity(7, "com.tencent.mm/.ui.CameraUI")]
        require(try decode(fields).scannerActivity() == nil, "Photo camera was mistaken for scanner intent")
        fields = basic()
        fields["activities"] = [activity(7, "com.eg.android.AlipayGphone/com.alipay.mobile.scan.as.tool.ToolsCaptureActivity")]
        fields["cameraOwner"] = "com.eg.android.AlipayGphone"
        require(try decode(fields).scannerActivity() == nil, "Unverified Alipay tools route enabled desktop capture")
        fields = basic()
        fields["activities"] = [activity(7, alipay), activity(8, "com.eg.android.AlipayGphone/.AlipayLogin")]
        fields["cameraOwner"] = "com.eg.android.AlipayGphone"
        require(try decode(fields).scannerActivity() == nil,
                "A second owned Alipay foreground left camera ownership ambiguous")

        fields = basic()
        fields["activities"] = [activity(7, wechat), activity(7, "org.example.app/.Main")]
        rejected(fields, "Duplicate display IDs were accepted")
        fields = basic(); fields["cameraOwner"] = "com.tencent.mm;invalid"
        rejected(fields, "Malformed camera owner package was accepted")
        fields = basic(); fields["ownerGeneration"] = -1
        rejected(fields, "Negative ownership generation was accepted")
        fields = basic(); fields["ownerKnown"] = "true"
        rejected(fields, "Non-boolean ownerKnown was accepted")
        fields = basic(); fields["activities"] = (1...9).map { activity($0, wechat) }
        rejected(fields, "Oversized activity list was accepted")
        fields = basic(); fields["padding"] = String(repeating: "x", count: 16_384)
        rejected(fields, "Oversized camera state was accepted")
        print("PASS camera ownership, exact WeChat/Alipay routes, ambiguous-state rejection and strict bounds")
    }
}
