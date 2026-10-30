import Foundation

enum CameraFramePreparation {
    struct ClearFailure:LocalizedError {
        let underlying:Error
        var errorDescription:String? {underlying.localizedDescription}
    }
    /// The image is never returned until the old-frame clear is acknowledged.
    /// Structured children are joined/cancelled before errors leave this scope.
    static func run(image:@escaping @Sendable () async throws ->Data,
                    clear:@escaping @Sendable () async throws ->Double) async throws ->(image:Data,clearMilliseconds:Double) {
        async let pendingImage=image()
        async let pendingClear=clear()
        let cleared:Double
        do {cleared=try await pendingClear}
        catch {throw ClearFailure(underlying:error)}
        return (try await pendingImage,cleared)
    }
}
