import Foundation

/// Optional stream startup shares the calibration interval, never its lifetime.
/// Join it before admitting a frame or letting cleanup reuse the capture actor.
enum CaptureStartupOverlap {
    struct Warmup:Sendable {let completed:Bool,milliseconds:Double}
    @MainActor static func during<T>(prepare:@escaping @Sendable () async throws ->Void,
                                    operation:() async throws ->T) async throws ->(value:T,warmup:Warmup) {
        let job=Task.detached(priority:.userInitiated) {()->Warmup in
            let began=ProcessInfo.processInfo.systemUptime
            do {
                try Task.checkCancellation();try await prepare();try Task.checkCancellation()
                return Warmup(completed:true,milliseconds:(ProcessInfo.processInfo.systemUptime-began)*1000)
            }catch{return Warmup(completed:false,milliseconds:(ProcessInfo.processInfo.systemUptime-began)*1000)}
        }
        return try await withTaskCancellationHandler(operation:{
            do {
                let result=try await operation()
                // Completed startup remains usable. Unfinished optional work
                // is cancelled and its bounded cleanup is drained before use.
                job.cancel();let warmup=await job.value
                try Task.checkCancellation()
                return (result,warmup)
            }catch {
                job.cancel();_=await job.value
                throw error
            }
        },onCancel:{job.cancel()})
    }
}
