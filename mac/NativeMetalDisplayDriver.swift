import Foundation
import QuartzCore

/// One native display clock on one dedicated render run loop. AppKit and input
/// remain on the MainActor; render() is called serially only on this thread.
final class NativeMetalDisplayDriver:NSObject,CAMetalDisplayLinkDelegate,@unchecked Sendable {
    private let layer:CAMetalLayer
    private let active:@Sendable ()->Bool
    private let render:(CAMetalDrawable)throws->Void
    private let failure:@Sendable ()->Void
    private let lock=NSLock(),finished=DispatchGroup()
    private var started=false,stopped=false,runLoop:CFRunLoop?

    init(layer:CAMetalLayer,active:@escaping @Sendable ()->Bool,
         render:@escaping (CAMetalDrawable)throws->Void,failure:@escaping @Sendable ()->Void) {
        self.layer=layer;self.active=active;self.render=render;self.failure=failure
    }
    func start() {
        let launch=lock.withLock {()->Bool in
            guard !started,!stopped else{return false}
            started=true;finished.enter();return true
        }
        guard launch else{return}
        let thread=Thread { [self] in run() }
        thread.name="Native phone display";thread.qualityOfService = .userInitiated
        thread.start()
    }
    private func run() {
        defer {finished.leave()}
        autoreleasepool {
            let loop=CFRunLoopGetCurrent()!
            let run=lock.withLock {()->Bool in
                guard !stopped else{return false};runLoop=loop;return true
            }
            guard run else{return}
            var context=CFRunLoopSourceContext()
            let keepAlive=CFRunLoopSourceCreate(nil,0,&context)!
            CFRunLoopAddSource(loop,keepAlive,.commonModes)
            defer {CFRunLoopRemoveSource(loop,keepAlive,.commonModes);CFRunLoopSourceInvalidate(keepAlive)}
            let link=CAMetalDisplayLink(metalLayer:layer)
            link.delegate=self
            link.preferredFrameRateRange=CAFrameRateRange(minimum:60,maximum:60,preferred:60)
            link.preferredFrameLatency=1
            link.add(to:RunLoop.current,forMode:.common)
            defer {link.invalidate();lock.withLock {runLoop=nil;stopped=true}}
            while !lock.withLock({stopped}),active() {
                // Also check source invalidation when an occluded window gets
                // no display-link callbacks. No UI-thread polling is needed.
                _=RunLoop.current.run(mode:.default,before:Date(timeIntervalSinceNow:0.1))
            }
        }
    }
    func metalDisplayLink(_ link:CAMetalDisplayLink,needsUpdate update:CAMetalDisplayLink.Update) {
        guard !lock.withLock({stopped}),active() else{stop();return}
        do {try autoreleasepool {try render(update.drawable)}}
        catch {stop();failure()}
    }
    func stop() {
        let loop=lock.withLock {()->CFRunLoop? in stopped=true;return runLoop}
        if let loop {CFRunLoopStop(loop);CFRunLoopWakeUp(loop)}
    }
    func waitUntilStopped() async {
        await withCheckedContinuation { (continuation:CheckedContinuation<Void,Never>) in
            DispatchQueue.global(qos:.utility).async { [self] in
                finished.wait();continuation.resume()
            }
        }
    }
}
