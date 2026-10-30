import Foundation

/// A fast Android launch reply is not permission to show or control old pixels.
@MainActor enum MainApplicationReadiness {
    static func open(clock:()->TimeInterval={ProcessInfo.processInfo.systemUptime},
                     launch:() async throws ->Bool,validate:() throws ->Void,
                     presentFreshFrame:(_ since:TimeInterval) async throws ->Void,
                     ready:(_ cameraReady:Bool)->Void) async throws {
        try Task.checkCancellation()
        let began=clock()
        let cameraReady=try await launch()
        try Task.checkCancellation();try validate()
        try await presentFreshFrame(began)
        try Task.checkCancellation();try validate()
        ready(cameraReady)
    }
}
