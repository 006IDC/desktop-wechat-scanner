import Foundation
import CoreGraphics
import Dispatch

/// Uses only immutable synthetic geometry. No NSScreen, capture permission, or phone.
@main enum CameraPumpMailboxTests {
    private enum TestFailure:Error,Equatable {case first,late}

    private static func require(_ condition:Bool,_ message:String) {
        if !condition {fatalError(message)}
    }
    private static func target(_ marker:Int)->DesktopCaptureTarget {
        DesktopCaptureTarget(rect:CGRect(x:CGFloat(marker%900),y:100,width:50,height:50),
                             displayID:42,screenFrame:CGRect(x:0,y:0,width:1000,height:1000),
                             pixelSize:CGSize(width:1000,height:1000),
                             selectedAt:Double(marker))
    }
    private static func marker(_ value:DesktopCaptureTarget?)->Int? {
        value.map {Int($0.selectedAt)}
    }
    static func main() {
        let pump=CameraPumpMailbox()
        require(pump.latest()==nil,"New mailbox contains a target")
        for index in 0..<10_000 {pump.publish(target(index))}
        require(marker(pump.latest())==9_999,"Fast producer left an old target")
        require(marker(pump.latest())==9_999,"Reading latest consumed the target")

        var stats=CameraPumpMailbox.Statistics()
        require(stats.sendMilliseconds==0 && stats.responseWaitMilliseconds==0 &&
                stats.responseBodyMilliseconds==0,"New transport timings were not zero")
        stats.sent=47;stats.dropped=3;stats.fps=28.5
        stats.captureMilliseconds=7.25;stats.transferMilliseconds=4.5
        stats.sendMilliseconds=1.25;stats.responseWaitMilliseconds=2.5
        stats.responseBodyMilliseconds=0.75
        stats.maximumGapMilliseconds=110
        pump.update(stats)
        let read=pump.snapshot()
        require(read.statistics.sent==47 && read.statistics.dropped==3 &&
                read.statistics.fps==28.5 && read.statistics.captureMilliseconds==7.25 &&
                read.statistics.transferMilliseconds==4.5 &&
                read.statistics.sendMilliseconds==1.25 &&
                read.statistics.responseWaitMilliseconds==2.5 &&
                read.statistics.responseBodyMilliseconds==0.75 &&
                read.statistics.maximumGapMilliseconds==110 && read.failure==nil,
                "Statistics snapshot lost pump metrics")

        // The worker may finish one capture while UI publishes many new positions.
        // At each acknowledgement boundary it must select the final target only.
        let available=DispatchSemaphore(value:0),consumed=DispatchSemaphore(value:0),producer=DispatchGroup()
        producer.enter()
        DispatchQueue.global(qos:.userInitiated).async {
            defer{producer.leave()}
            for batch in 0..<30 {
                for step in 0..<500 {pump.publish(target(batch*500+step))}
                available.signal()
                require(consumed.wait(timeout:.now()+5) == .success,"Consumer missed a batch")
            }
        }
        for batch in 0..<30 {
            require(available.wait(timeout:.now()+5) == .success,"Producer missed a batch")
            require(marker(pump.latest())==batch*500+499,"Pump selected a stale drag rectangle")
            consumed.signal()
        }
        require(producer.wait(timeout:.now()+5) == .success,"Producer did not finish")

        // Concurrent readers and publishers must preserve complete target structs.
        DispatchQueue.concurrentPerform(iterations:8) { worker in
            for index in 0..<3_000 {
                if worker.isMultiple(of:2) {pump.publish(target(index))}
                else if let value=pump.latest() {
                    require(value.displayID==42 && value.screenFrame.width==1000 &&
                            value.pixelSize.width==1000 && value.rect.width==50 &&
                            value.rect.minX==CGFloat(Int(value.selectedAt)%900),
                            "Concurrent target snapshot was torn")
                }
            }
        }

        pump.fail(TestFailure.first)
        require(pump.latest()==nil,"Failed pump retained its target")
        require(pump.snapshot().failure is TestFailure,"Failure was not published")
        var lateStats=stats;lateStats.sent=48
        pump.publish(target(88_888));pump.update(lateStats);pump.fail(TestFailure.late)
        require(pump.latest()==nil,"Late publish revived failed pump")
        require((pump.snapshot().failure as? TestFailure) == .first,
                "Late failure replaced the original failure")
        require(pump.snapshot().statistics.sent==47,"Late metric update changed failed pump")
        pump.stop()
        require(pump.latest()==nil && pump.snapshot().failure==nil,
                "Stop did not clear target and failure")
        pump.publish(target(99_999));pump.update(lateStats);pump.fail(TestFailure.late)
        require(pump.latest()==nil && pump.snapshot().failure==nil,
                "Stopped pump accepted late callbacks")
        require(pump.snapshot().statistics.sent==47,"Late metric update changed stopped pump")

        let replacement=CameraPumpMailbox()
        replacement.publish(target(123))
        require(marker(replacement.latest())==123 && pump.latest()==nil,
                "New pump shared state with stopped pump")

        let stopped=CameraPumpMailbox()
        stopped.publish(target(1));stopped.stop()
        DispatchQueue.concurrentPerform(iterations:8) { worker in
            for index in 0..<2_000 {
                if worker.isMultiple(of:2) {stopped.publish(target(index))}
                else {stopped.fail(TestFailure.late)}
            }
        }
        require(stopped.latest()==nil && stopped.snapshot().failure==nil,
                "Concurrent callbacks revived a stopped pump")
        print("PASS latest drag target, concurrent snapshots, metrics readback, failure and stop isolation")
    }
}
