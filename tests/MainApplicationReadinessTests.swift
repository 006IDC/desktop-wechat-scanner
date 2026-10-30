import Foundation
import CoreVideo

@main @MainActor enum MainApplicationReadinessTests {
    enum Fault:Error {case timeout,launch}
    static func until(_ condition:()->Bool) async throws {
        let deadline=ProcessInfo.processInfo.systemUptime+1
        while !condition() {
            precondition(ProcessInfo.processInfo.systemUptime<deadline)
            try await Task.sleep(nanoseconds:1_000_000)
        }
    }
    static func main() async throws {
        var pixels:CVPixelBuffer?
        precondition(CVPixelBufferCreate(nil,4,4,kCVPixelFormatType_32BGRA,nil,&pixels)==kCVReturnSuccess)
        let slot=MirrorVideoMailbox();slot.reset(generation:4);slot.publish(pixels!,generation:4)
        var presented=slot.takeLatest()!
        let began=presented.receivedAt+0.001
        var ready=false,launched=false,frameWaitStarted=false,validated=0
        let open=Task { @MainActor in
            try await MainApplicationReadiness.open(clock:{began},launch:{launched=true;return true},
                validate:{validated+=1},presentFreshFrame:{since in
                    precondition(since==began);frameWaitStarted=true
                    while presented.generation != 4 || presented.receivedAt<since {
                        try Task.checkCancellation();try await Task.sleep(nanoseconds:1_000_000)
                    }
                },ready:{camera in precondition(camera);ready=true})
        }
        try await until{launched && frameWaitStarted}
        precondition(!ready)
        slot.publish(pixels!,generation:3)
        try await Task.sleep(nanoseconds:5_000_000)
        precondition(slot.takeLatest()==nil && !ready)
        slot.publish(pixels!,generation:4)
        // The renderer already consumed this static frame. The retained
        // presentation still releases the gate; a second frame is unnecessary.
        presented=slot.takeLatest()!
        try await open.value
        precondition(ready && validated==2)

        ready=false
        do {
            try await MainApplicationReadiness.open(launch:{true},validate:{},
                presentFreshFrame:{_ in throw Fault.timeout},ready:{_ in ready=true})
            preconditionFailure()
        }catch Fault.timeout{}
        precondition(!ready)

        var launchContinuation:CheckedContinuation<Bool,Never>?,waitCalled=false
        let cancelled=Task { @MainActor in
            try await MainApplicationReadiness.open(launch:{await withCheckedContinuation{launchContinuation=$0}},
                validate:{},presentFreshFrame:{_ in waitCalled=true},ready:{_ in ready=true})
        }
        try await until{launchContinuation != nil}
        cancelled.cancel();launchContinuation?.resume(returning:true)
        do{try await cancelled.value;preconditionFailure()}catch is CancellationError{}
        precondition(!ready && !waitCalled)

        var live=true,frameContinuation:CheckedContinuation<Void,Never>?
        let retired=Task { @MainActor in
            try await MainApplicationReadiness.open(launch:{true},validate:{if !live{throw CancellationError()}},
                presentFreshFrame:{_ in await withCheckedContinuation{frameContinuation=$0}},ready:{_ in ready=true})
        }
        try await until{frameContinuation != nil}
        live=false;frameContinuation?.resume()
        do{try await retired.value;preconditionFailure()}catch is CancellationError{}
        precondition(!ready)

        var ordinary=false
        try await MainApplicationReadiness.open(launch:{false},validate:{},presentFreshFrame:{_ in},
            ready:{camera in precondition(!camera);ordinary=true})
        precondition(ordinary)
        print("PASS main launch waits for post-launch same-generation frame, consumed static frame, timeout/cancellation/retirement and ordinary app; no windows/device")
    }
}
