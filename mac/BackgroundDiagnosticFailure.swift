import Foundation
import ScreenCaptureKit

/// Fixed technical categories only. Never persist arbitrary service messages,
/// NSError userInfo, OCR output, device identifiers or user content.
enum BackgroundDiagnosticFailure {
    static func fields(_ error:Error)->[String:Any] {
        if error is CancellationError {return ["backendFailureKind":"cancelled"]}
        if let error=error as? GenericMotionDiagnostic.Failure {
            let category:String
            switch error {
            case .scope:category="motion_scope"
            case .owner:category="motion_owner"
            case .source:category="motion_source"
            case .comparison:category="motion_comparison"
            }
            return ["backendFailureKind":category]
        }
        let system=error as NSError
        if system.domain==SCStreamErrorDomain {
            return ["backendFailureKind":"screen_capture","screenCaptureErrorCode":system.code]
        }
        if let error=error as? ScanError {
            let known=[
                "此应用与其他应用共享任务容器，无法安全地单独移入窗口。":"shared_task_root",
                "应用窗口的任务归属尚未完整确认，已保留窗口和恢复记录。":"unconfirmed_restore_tasks",
                "应用任务的归属尚未完整确认，已保留恢复记录。":"unconfirmed_target_tasks",
                "无法排除本 App，请重新打开 App。":"own_application_metadata",
                "合成测试窗口尚未就绪。":"own_board_metadata",
                "显示器已变化，请重新开始扫码。":"display_changed",
                "桌面采集区域尺寸无效。":"capture_region",
                "无法读取扫码区域。":"capture_pixels",
                "无法编码桌面画面。":"capture_encoding",
                "桌面图像编码失败。":"capture_encoding",
                "桌面连续采集启动超时，请重新开始扫码。":"capture_start_timeout",
                "手机图像连接已中断。":"phone_connection_closed",
                "手机图像连接已中断或超时。":"phone_connection_timeout",
                "手机返回了无效的图像处理耗时长度。":"phone_timing_length",
                "手机返回了无效的图像处理耗时。":"phone_timing_value"
            ]
            return ["backendFailureKind":known[error.message] ?? "scan_error_other"]
        }
        return ["backendFailureKind":"other"]
    }
}
