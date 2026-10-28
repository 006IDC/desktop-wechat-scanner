import Foundation
import CoreVideo
import QuartzCore

/// CPU-only synthetic buffers. No app, window, GPU, phone or screen capture.
@main enum NativeScannerFramesTests {
    final class Clock:@unchecked Sendable {
        let lock=NSLock();var value=1.0
        func now()->Double {lock.withLock {value}}
        func set(_ time:Double) {lock.withLock {value=time}}
    }
    static func pixels()->CVPixelBuffer {
        var value:CVPixelBuffer?
        precondition(CVPixelBufferCreate(nil,2,2,kCVPixelFormatType_32BGRA,nil,&value)==kCVReturnSuccess)
        return value!
    }
    static func pending(_ slot:NativeScannerFrames) async throws {
        let until=ProcessInfo.processInfo.systemUptime+2
        while !slot.hasWaiter,ProcessInfo.processInfo.systemUptime<until {
            try await Task.sleep(nanoseconds:1_000_000)
        }
        precondition(slot.hasWaiter,"Waiter did not install")
    }
    static func failure(_ task:Task<NativeScannerFrames.Sample,Error>,
                        _ expected:NativeScannerFrames.Failure?) async {
        do {_=try await task.value;fatalError("Expected wait failure")}
        catch is CancellationError {precondition(expected==nil)}
        catch let error as NativeScannerFrames.Failure {
            switch (error,expected) {
            case (.stopped,.stopped?),(.timedOut,.timedOut?),
                 (.concurrentWait,.concurrentWait?),(.invalidWait,.invalidWait?):break
            default:fatalError("Wrong wait failure")
            }
        } catch {fatalError("Unexpected wait error")}
    }
    static func main() async throws {
        let p=pixels(),clock=Clock(),slot=NativeScannerFrames(clock:{clock.now()})
        let shared=NativeScannerFrames.Sample(revision:0,pixels:p,receivedAt:0)
        slot.publish(p)
        let initial=try await slot.wait(after:0,timeout:1)
        precondition(initial.revision==1 && initial.receivedAt==1 && !slot.hasWaiter)
        let spaced=Task {try await slot.wait(after:1,notBefore:1.04,timeout:1)}
        try await pending(slot)
        clock.set(1.02);slot.publish(p)
        precondition(slot.hasWaiter,"Frame before the spacing boundary woke calibration")
        clock.set(1.05);slot.publish(p)
        let sample=try await spaced.value
        precondition(sample.revision==3 && sample.receivedAt==1.05 && !slot.hasWaiter)

        for i in 0..<100 {clock.set(2+Double(i));slot.publish(p)}
        let latest=try await slot.wait(after:3,timeout:1)
        precondition(latest.revision==103 && latest.receivedAt==101,"Slot queued old frames")
        let first=Task {try await slot.wait(after:103,timeout:1)}
        try await pending(slot)
        await failure(Task {try await slot.wait(after:103,timeout:1)},.concurrentWait)
        precondition(slot.hasWaiter,"Rejected concurrent wait removed the original waiter")
        clock.set(102);slot.publish(p)
        let original=try await first.value;precondition(original.revision==104)

        let stopped=NativeScannerFrames()
        let stopWait=Task {try await stopped.wait(after:0,timeout:1)}
        try await pending(stopped);stopped.stop()
        await failure(stopWait,.stopped)
        precondition(!stopped.hasWaiter && stopped.latest().1==nil && !stopped.publish(p))
        await failure(Task {try await stopped.wait(after:0,timeout:1)},.stopped)

        let timeout=NativeScannerFrames()
        await failure(Task {try await timeout.wait(after:0,timeout:0.01)},.timedOut)
        precondition(!timeout.hasWaiter)
        timeout.publish(p)
        let recovered=try await timeout.wait(after:0,timeout:1)
        precondition(recovered.revision==1,"Timeout invalidated a healthy slot")

        let cancelled=NativeScannerFrames()
        let cancelWait=Task {try await cancelled.wait(after:0,timeout:1)}
        try await pending(cancelled);cancelWait.cancel();await failure(cancelWait,nil)
        precondition(!cancelled.hasWaiter)
        for _ in 0..<100 {
            let empty=NativeScannerFrames()
            let task=Task {try await empty.wait(after:0,timeout:1)}
            task.cancel();await failure(task,nil)
            precondition(!empty.hasWaiter,"Cancellation before install leaked a waiter")
        }
        for _ in 0..<100 {
            let racing=NativeScannerFrames()
            let task=Task {try await racing.wait(after:0,timeout:1)}
            try await pending(racing)
            DispatchQueue.concurrentPerform(iterations:3) {index in
                if index==0 {_=racing.publish(shared.pixels)}
                else if index==1 {task.cancel()}
                else {racing.stop()}
            }
            do {_=try await task.value}
            catch is CancellationError {}
            catch NativeScannerFrames.Failure.stopped {}
            catch {fatalError("Publish/cancel/stop race produced unexpected failure")}
            precondition(!racing.hasWaiter && !racing.publish(p))
        }
        for (revision,time,limit):(Int,Double,Double) in [(-1,0,1),(0,Double.nan,1),
            (0,0,Double.nan),(0,0,0),(0,0,61)] {
            await failure(Task {try await slot.wait(after:revision,notBefore:time,timeout:limit)},.invalidWait)
        }
        print("PASS CPU-only frame waits: latest-only, spacing, stop/timeout, concurrent rejection, cancellation-before-install and 100 publish/cancel/stop races")
        if CommandLine.arguments.contains("--benchmark") {try await benchmark(p)}
    }
    static func benchmark(_ p:CVPixelBuffer) async throws {
        let slot=NativeScannerFrames();var delays=[Double]()
        for i in 0..<100 {
            let task=Task {try await slot.wait(after:i,timeout:1)}
            try await pending(slot);slot.publish(p)
            let value=try await task.value
            delays.append((CACurrentMediaTime()-value.receivedAt)*1000)
        }
        delays.sort();print("Synthetic publish-to-await p95 ms",delays[94],"max ms",delays[99])
        print("No UI/phone timing measured")
    }
}
