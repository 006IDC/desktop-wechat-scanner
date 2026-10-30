import Foundation

@main enum CameraFrameInvalidationTests {
    static func main() {
        // Local geometry expiry cannot request a route change on each drag tick.
        precondition(!CameraFrameExpiredError().sourceInvalidated)
        for message in ["Desktop camera has no verified scanner owner",
                        "Desktop camera state changed while decoding frame",
                        "Native source lease is no longer active"] {
            precondition(CameraFrameExpiredError.serverRejection(message)?.sourceInvalidated==true)
        }
        // Authentication, transport and unknown errors retain their normal path.
        for message in ["Permission denied","连接响应超时。","Native source lease is no longer activeX",""] {
            precondition(CameraFrameExpiredError.serverRejection(message)==nil)
        }
        print("PASS server camera invalidation is distinct from geometry expiry and transport failures")
    }
}
