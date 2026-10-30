import Foundation

/// Only authenticated source retirement may request an early state refresh.
struct CameraFrameExpiredError: LocalizedError {
    let sourceInvalidated:Bool
    init(sourceInvalidated:Bool=false) {self.sourceInvalidated=sourceInvalidated}
    static func serverRejection(_ message:String)->Self? {
        switch message {
        case "Desktop camera has no verified scanner owner", "Desktop camera state changed while decoding frame", "Native source lease is no longer active":
            return Self(sourceInvalidated:true)
        default:return nil
        }
    }
    var errorDescription:String? {sourceInvalidated ? "手机相机画面已变化。":"本次桌面坐标已过时。"}
}
