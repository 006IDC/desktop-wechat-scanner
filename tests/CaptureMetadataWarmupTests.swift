import Foundation

private actor PreparationProbe {
    var loads=0
    private var continuation:CheckedContinuation<Void,Never>?
    func blocked() async {
        loads+=1
        await withCheckedContinuation{continuation=$0}
    }
    func immediate() {loads+=1}
    func release(){continuation?.resume();continuation=nil}
}
@main enum CaptureMetadataWarmupTests {
    enum Failure:Error {case synthetic}
    @MainActor static func until(_ condition:() async -> Bool) async throws {
        let end=Date().addingTimeInterval(3)
        while !(await condition()) {precondition(Date()<end,"Preparation test timed out");try await Task.sleep(nanoseconds:1_000_000)}
    }
    @MainActor static func main() async throws {
        let owner=CaptureMetadataWarmup(),probe=PreparationProbe()
        owner.start(allowed:false){await probe.immediate()}
        let denied=await owner.finish();precondition(!denied)
        let deniedLoads=await probe.loads;precondition(deniedLoads==0,"Denied warmup performed work")
        owner.start(allowed:true){await probe.blocked()}
        owner.start(allowed:true){await probe.immediate()}
        try await until{await probe.loads==1}
        let first=Task{await owner.finish()},second=Task{await owner.finish()}
        // An uncooperative fixture holds cancellation to prove we do not start a
        // second preparation while either foreground finisher is still draining.
        try await Task.sleep(nanoseconds:10_000_000)
        owner.start(allowed:true){await probe.immediate()}
        let during=await probe.loads;precondition(during==1,"Draining allowed concurrent capture preparation")
        await probe.release()
        let a=await first.value,b=await second.value
        precondition(!a && !b,"Canceled preparation was reported warmed")
        owner.start(allowed:true){throw Failure.synthetic}
        try await Task.sleep(nanoseconds:10_000_000)
        let failed=await owner.finish();precondition(!failed,"Failed metadata was reported warmed")
        owner.start(allowed:true){await probe.immediate()}
        try await until{await probe.loads==2}
        try await Task.sleep(nanoseconds:10_000_000)
        let warmed=await owner.finish();precondition(warmed,"Completed metadata was not retained")
        let empty=await owner.finish();precondition(!empty,"Retired metadata job was reused")
        let foregroundProbe=PreparationProbe(),unexpected=PreparationProbe()
        let foreground=Task {await owner.withForeground { _ in await foregroundProbe.blocked()}}
        try await until{await foregroundProbe.loads==1}
        owner.start(allowed:true){await unexpected.immediate()}
        try await Task.sleep(nanoseconds:10_000_000)
        let blockedReady=await unexpected.loads;precondition(blockedReady==0,"Window-ready callback inserted preparation after foreground drain")
        await foregroundProbe.release();await foreground.value
        do {try await owner.withForeground { _ in
            try await owner.withForeground { _ in throw Failure.synthetic }
        };fatalError("Nested error hidden")} catch Failure.synthetic {}
        owner.start(allowed:true){await unexpected.immediate()}
        try await until{await unexpected.loads==1}
        _=await owner.finish()
        print("PASS metadata-only preparation admission, single owner, concurrent drain, cancellation, failure and completed reuse; no capture API or UI")
    }
}
