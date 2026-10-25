import Foundation

@main enum MirrorInputSchedulingTests {
    typealias Event = MirrorInputScheduler.Event
    static func require(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
    static func drain(_ scheduler: MirrorInputScheduler, epoch: Int) -> [Event] {
        var events: [Event] = []
        while let event = scheduler.next(epoch: epoch) { events.append(event) }
        return events
    }
    static func main() {
        let scheduler = MirrorInputScheduler()
        scheduler.reset(epoch: 1, enabled: true)
        require(scheduler.submit(.touch(0, 0.1, 0.2), epoch: 1).wake, "DOWN must schedule a drain")
        for i in 0..<50_000 {
            require(!scheduler.submit(.touch(2, Double(i) / 50_000, 0.5), epoch: 1).wake, "Moves scheduled unbounded drains")
        }
        require(scheduler.pendingCount == 2, "Moves accumulated rather than coalescing")
        _ = scheduler.submit(.touch(1, 0.9, 0.8), epoch: 1)
        require(drain(scheduler, epoch: 1) == [.touch(0, 0.1, 0.2), .touch(2, 49_999.0 / 50_000, 0.5), .touch(1, 0.9, 0.8)], "DOWN/latest MOVE/UP ordering lost")

        _ = scheduler.submit(.touch(0, 0, 0), epoch: 1)
        _ = scheduler.submit(.key(4), epoch: 1)
        _ = scheduler.submit(.tap(0.5, 0.5), epoch: 1)
        _ = scheduler.submit(.swipe(0, 0, 1, 1), epoch: 1)
        _ = scheduler.submit(.touch(2, 0.4, 0.4), epoch: 1)
        _ = scheduler.submit(.touch(1, 0.4, 0.4), epoch: 1)
        require(drain(scheduler, epoch: 1) == [.touch(0, 0, 0), .touch(2, 0.4, 0.4), .touch(1, 0.4, 0.4), .key(4), .tap(0.5, 0.5), .swipe(0, 0, 1, 1)], "Discrete input overlapped a live finger")

        // The worker may become idle while a physical gesture stays down.
        _ = scheduler.submit(.touch(0, 0, 0), epoch: 1)
        require(drain(scheduler, epoch: 1) == [.touch(0, 0, 0)], "Live DOWN missing")
        require(!scheduler.submit(.key(3), epoch: 1).wake, "Deferred key woke a worker without runnable work")
        require(scheduler.submit(.touch(1, 1, 1), epoch: 1).wake, "UP did not wake the idle worker")
        require(drain(scheduler, epoch: 1) == [.touch(1, 1, 1), .key(3)], "Key did not wait for UP")

        // At most one pending legacy swipe, even while another is animating.
        for i in 0..<50_000 { _ = scheduler.submit(.swipe(0, 0, Double(i), 1), epoch: 1) }
        require(scheduler.pendingCount == 1, "Wheel swipes accumulated")
        require(scheduler.next(epoch: 1) == .swipe(0, 0, 49_999, 1), "Latest wheel intent lost")
        _ = scheduler.submit(.touch(0, 0.1, 0.1), epoch: 1)
        require(scheduler.hasPending(epoch: 1), "Live input cannot interrupt legacy animation")
        _ = scheduler.submit(.touch(1, 0.1, 0.1), epoch: 1)
        _ = drain(scheduler, epoch: 1)

        let bounded = MirrorInputScheduler(capacity: 8)
        bounded.reset(epoch: 3, enabled: true)
        for _ in 0..<6 { _ = bounded.submit(.tap(0, 0), epoch: 3) }
        require(bounded.submit(.touch(0, 0, 0), epoch: 3).accepted, "Available gesture reservation refused")
        require(bounded.submit(.key(4), epoch: 3).overflow, "Discrete queue did not enforce capacity")
        require(bounded.submit(.touch(1, 1, 1), epoch: 3).accepted, "Accepted DOWN lost its reserved UP")
        require(bounded.pendingCount == 8, "Bounded queue exceeded capacity")
        require(!bounded.submit(.touch(0, 0, 0), epoch: 3).accepted, "Full queue accepted unpaired DOWN")
        let events = drain(bounded, epoch: 3)
        require(Array(events.suffix(2)) == [.touch(0, 0, 0), .touch(1, 1, 1)], "Capacity pressure dropped gesture edges")

        scheduler.reset(epoch: 2, enabled: true)
        _ = scheduler.submit(.tap(1, 1), epoch: 2)
        scheduler.cancel(epoch: 1) // Late failure from a previous socket.
        require(!scheduler.submit(.key(4), epoch: 1).accepted && scheduler.next(epoch: 1) == nil, "Stale generation accepted work")
        require(scheduler.next(epoch: 2) == .tap(1, 1), "Old failure erased a newer session")
        scheduler.cancel(epoch: 2)
        require(scheduler.pendingCount == 0 && !scheduler.submit(.tap(0, 0), epoch: 2).accepted, "Stop did not clear and disable input")

        scheduler.reset(epoch: 4, enabled: true)
        _ = scheduler.submit(.touch(0, 0, 0), epoch: 4)
        DispatchQueue.concurrentPerform(iterations: 10_000) { i in
            _ = scheduler.submit(.touch(2, Double(i), 0), epoch: 4)
        }
        _ = scheduler.submit(.touch(2, 0.75, 0.25), epoch: 4)
        _ = scheduler.submit(.touch(1, 0.75, 0.25), epoch: 4)
        require(drain(scheduler, epoch: 4) == [.touch(0, 0, 0), .touch(2, 0.75, 0.25), .touch(1, 0.75, 0.25)], "Concurrent producers lost edges or latest move")
        print("PASS bounded input scheduling, 50k move/swipe coalescing, gesture edges, discrete exclusion, reserved UP, idle wakeup, concurrent producers and generation cleanup")
    }
}
