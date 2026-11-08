import Foundation

@MainActor private final class Remote {
    var enabled=false,disables=0
    private var ack:CheckedContinuation<Int,Never>?
    func enable() async ->Int {
        enabled=true
        return await withCheckedContinuation{ack=$0}
    }
    func acknowledge(){ack?.resume(returning:42);ack=nil}
    func disable(_ lease:Int){precondition(lease==42);enabled=false;disables+=1}
}
@main enum NativePreviewLeaseHandoffTests {
    enum Failure:Error {case stopped}
    @MainActor static func until(_ condition:()->Bool) async throws {
        let deadline=ProcessInfo.processInfo.systemUptime+2
        while !condition() {
            precondition(ProcessInfo.processInfo.systemUptime<deadline)
            try await Task.sleep(nanoseconds:1_000_000)
        }
    }
    @MainActor static func main() async throws {
        for cancelled in [false,true] {
            let remote=Remote();var stopped=false,adopted=0
            let task=Task {
                try await NativePreviewLeaseHandoff.acquire(begin:{await remote.enable()},adopt:{_ in
                    guard !stopped else{throw Failure.stopped};adopted+=1
                },retire:{remote.disable($0)})
            }
            try await until{remote.enabled}
            stopped=true;if cancelled{task.cancel()};remote.acknowledge()
            do {try await task.value;fatalError("Late enable was adopted after stop/cancel")}
            catch is CancellationError {precondition(cancelled)}
            catch Failure.stopped {precondition(!cancelled)}
            precondition(adopted==0 && remote.disables==1 && !remote.enabled)
        }
        let remote=Remote();var adopted=0
        let valid=Task {try await NativePreviewLeaseHandoff.acquire(begin:{await remote.enable()},adopt:{lease in
            precondition(lease==42);adopted+=1
        },retire:{remote.disable($0)})}
        try await until{remote.enabled};remote.acknowledge();try await valid.value
        precondition(adopted==1 && remote.disables==0 && remote.enabled)
        remote.disable(42)
        let uncertain=Remote();var adoptionAttempted=false,rendererPublished=false
        let failedRetirement=Task {
            try await NativePreviewLeaseHandoff.acquire(begin:{await uncertain.enable()},adopt:{_ in
                adoptionAttempted=true;throw Failure.stopped
            },retire:{_ in throw Failure.stopped})
            rendererPublished=true
        }
        try await until{uncertain.enabled};uncertain.acknowledge()
        do {try await failedRetirement.value;fatalError("Unconfirmed retirement swallowed")}
        catch is NativePreviewLeaseHandoff.RetirementUnconfirmed {}
        // The remote owner still retains the live resource; no success or clean
        // state may be inferred from the UI rejecting adoption.
        precondition(adoptionAttempted && !rendererPublished && uncertain.enabled && uncertain.disables==0)
        uncertain.disable(42);precondition(!uncertain.enabled && uncertain.disables==1)
        print("PASS late enable ACK after stop/cancel retires exact lease once, no adoption; valid handoff retained; no phone/UI")
    }
}
