import Foundation

private actor Probe {
    var started=false,finished=false
    private var gate:CheckedContinuation<Void,Never>?
    func prepare() async {
        started=true
        await withCheckedContinuation{gate=$0}
        finished=true
    }
    func release(){gate?.resume();gate=nil}
}
@main enum CaptureStartupOverlapTests {
    enum Failure:Error {case synthetic}
    @MainActor static func until(_ condition:() async->Bool) async throws {
        let deadline=ProcessInfo.processInfo.systemUptime+3
        while !(await condition()) {
            precondition(ProcessInfo.processInfo.systemUptime<deadline)
            try await Task.sleep(nanoseconds:1_000_000)
        }
    }
    @MainActor static func main() async throws {
        let probe=Probe();var operationReturned=false,scopeReturned=false
        let scope=Task {
            let result=try await CaptureStartupOverlap.during(prepare:{await probe.prepare()},operation:{
                try await until{await probe.started};operationReturned=true;return 7
            })
            scopeReturned=true;return result
        }
        try await until{operationReturned}
        try await Task.sleep(nanoseconds:10_000_000)
        precondition(!scopeReturned,"Capture actor was released before startup cleanup joined")
        await probe.release();let result=try await scope.value
        precondition(result.value==7 && !result.warmup.completed)
        let finished=await probe.finished;precondition(finished)

        let failed=try await CaptureStartupOverlap.during(prepare:{throw Failure.synthetic},operation:{11})
        precondition(failed.value==11 && !failed.warmup.completed,"Optional warmup changed the main result")
        let failing=Probe();var failureReturned=false
        let failure=Task {
            do {
                _=try await CaptureStartupOverlap.during(prepare:{await failing.prepare()},operation:{()->Int in
                    try await until{await failing.started};throw Failure.synthetic
                })
                fatalError("Operation failure swallowed")
            }catch Failure.synthetic {failureReturned=true}
        }
        try await until{await failing.started}
        try await Task.sleep(nanoseconds:10_000_000)
        precondition(!failureReturned,"Failure returned while startup still owned capture")
        await failing.release();try await failure.value
        let failedFinished=await failing.finished;precondition(failedFinished)

        let cancellation=Probe()
        let cancelled=Task {
            try await CaptureStartupOverlap.during(prepare:{await cancellation.prepare()},operation:{
                try await until{await cancellation.started}
                try await Task.sleep(nanoseconds:60_000_000_000);return 0
            })
        }
        try await until{await cancellation.started};cancelled.cancel();await cancellation.release()
        do {_=try await cancelled.value;fatalError("Parent cancellation was lost")}catch is CancellationError {}
        let cancelFinished=await cancellation.finished;precondition(cancelFinished)
        print("PASS overlapping startup, joined cancellation/failure, optional warmup failure and no late capture owner; no UI/device/capture")
    }
}
