import Foundation

/// An enable ACK can arrive after its UI owner stopped. Keep the returned
/// resource local until synchronous adoption; otherwise retire that exact lease.
enum NativePreviewLeaseHandoff {
    struct RetirementUnconfirmed:LocalizedError {
        let underlying:Error
        var errorDescription:String? {"手机尚未确认停止透明取景，已保留待清理状态。请重新连接手机。"}
    }
    @MainActor static func acquire<Lease:Sendable>(begin:() async throws ->Lease,
        adopt:(Lease) throws ->Void,retire:(Lease) async throws ->Void) async throws {
        try Task.checkCancellation()
        let lease=try await begin()
        do {try Task.checkCancellation();try adopt(lease)}
        catch {
            let original=error
            do {try await retire(lease)}
            catch {throw RetirementUnconfirmed(underlying:error)}
            throw original
        }
    }
}
