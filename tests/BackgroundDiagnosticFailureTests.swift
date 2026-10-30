import Foundation
import ScreenCaptureKit

@main enum BackgroundDiagnosticFailureTests {
    static func main() throws {
        let secret="private arbitrary activity text must never escape"
        let cases:[Error]=[
            ScanError(secret),NSError(domain:secret,code:91,userInfo:[NSLocalizedDescriptionKey:secret]),
            NSError(domain:SCStreamErrorDomain,code:-3801,userInfo:[NSLocalizedDescriptionKey:secret]),
            ScanError("无法排除本 App，请重新打开 App。"),CancellationError(),
            ScanError("此应用与其他应用共享任务容器，无法安全地单独移入窗口。")
        ]
        let values=try cases.map{try JSONSerialization.data(withJSONObject:BackgroundDiagnosticFailure.fields($0),options:.sortedKeys)}
        precondition(values.allSatisfy{!String(decoding:$0,as:UTF8.self).contains(secret)})
        precondition(BackgroundDiagnosticFailure.fields(cases[0])["backendFailureKind"] as? String=="scan_error_other")
        precondition(BackgroundDiagnosticFailure.fields(cases[1])["backendFailureKind"] as? String=="other")
        precondition(BackgroundDiagnosticFailure.fields(cases[2])["screenCaptureErrorCode"] as? Int == -3801)
        precondition(BackgroundDiagnosticFailure.fields(cases[3])["backendFailureKind"] as? String=="own_application_metadata")
        precondition(BackgroundDiagnosticFailure.fields(cases[4])["backendFailureKind"] as? String=="cancelled")
        precondition(BackgroundDiagnosticFailure.fields(cases[5])["backendFailureKind"] as? String=="shared_task_root")
        let motion:[GenericMotionDiagnostic.Failure]=[.scope,.owner,.source,.comparison]
        let categories=["motion_scope","motion_owner","motion_source","motion_comparison"]
        for (failure,category) in zip(motion,categories) {
            precondition(BackgroundDiagnosticFailure.fields(failure)["backendFailureKind"] as? String==category)
        }
        print("PASS fixed diagnostic categories omit arbitrary error messages and userInfo; no screen/device access")
    }
}
