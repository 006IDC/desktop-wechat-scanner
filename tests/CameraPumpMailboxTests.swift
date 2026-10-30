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
        let initial=CameraPumpMailbox()
        initial.prepareRegion(at:10,immediateFirst:true)
        require(initial.captureReady(at:10),"Untouched first generic region kept an unnecessary delay")
        initial.publish(target(1));let firstSelection=initial.selection()!
        initial.prepareRegion(at:10.01,immediateFirst:true)
        require(!initial.captureReady(at:10.18) && initial.captureReady(at:10.20),"A later region skipped settling")
        require(!initial.isCurrent(firstSelection),"A moved region kept an in-flight first frame")
        let zeroClock=CameraPumpMailbox()
        zeroClock.prepareRegion(at:0,immediateFirst:true);zeroClock.publish(target(1))
        zeroClock.invalidateRegion();zeroClock.prepareRegion(at:0.001,immediateFirst:true)
        require(!zeroClock.captureReady(at:0.17) && zeroClock.captureReady(at:0.182),"Invalidation revived the first-frame shortcut at clock zero")
        let publishedBeforePreparation=CameraPumpMailbox()
        publishedBeforePreparation.publish(target(1));publishedBeforePreparation.invalidateRegion()
        publishedBeforePreparation.prepareRegion(at:0,immediateFirst:true)
        require(!publishedBeforePreparation.captureReady(at:0.17),"Published region history was forgotten")
        let moving=CameraPumpMailbox()
        moving.delayCapture(until:11);moving.prepareRegion(at:10,immediateFirst:true)
        require(!moving.captureReady(at:10.99) && moving.captureReady(at:11),"First-frame shortcut erased a pre-existing movement fence")
        let legacy=CameraPumpMailbox();legacy.prepareRegion(at:10,immediateFirst:false)
        require(!legacy.captureReady(at:10.17) && legacy.captureReady(at:10.19),"Compatibility mode lost its original settle gate")
        let continuous=CameraPumpMailbox()
        continuous.prepareRegion(at:10,immediateFirst:true,continuousMovement:true)
        continuous.publish(target(1));let continuousFirst=continuous.selection()!
        continuous.invalidateRegion()
        require(continuous.selection()==nil && !continuous.isCurrent(continuousFirst),"Moved window kept the old ROI until the next tick")
        for step in 1...90 {
            let time=10+Double(step)/30
            continuous.prepareRegion(at:time,immediateFirst:true,continuousMovement:true)
            continuous.publish(target(step+1))
            require(continuous.captureReady(at:time),"Continuous generic motion kept postponing every frame")
        }
        require(!continuous.isCurrent(continuousFirst),"Continuous motion revived an old ROI")
        continuous.delayCapture(until:15)
        continuous.prepareRegion(at:13.1,immediateFirst:true,continuousMovement:true)
        require(!continuous.captureReady(at:14.99) && continuous.captureReady(at:15),"Continuous motion shortened an explicit refresh fence")
        let settlingFirst=CameraPumpMailbox()
        settlingFirst.prepareRegion(at:10,immediateFirst:false,continuousMovement:true)
        require(!settlingFirst.captureReady(at:10.17) && settlingFirst.captureReady(at:10.19),"Continuous movement erased an explicit first-frame experiment")
        continuous.stop();continuous.prepareRegion(at:16,immediateFirst:true,continuousMovement:true)
        require(!continuous.captureReady(at:16),"Continuous movement revived a stopped pump")
        initial.stop();initial.prepareRegion(at:0,immediateFirst:true)
        require(!initial.captureReady(at:100),"Region update revived a stopped pump")
        let pump=CameraPumpMailbox()
        require(pump.latest()==nil,"New mailbox contains a target")
        for index in 0..<10_000 {pump.publish(target(index))}
        require(marker(pump.latest())==9_999,"Fast producer left an old target")
        require(marker(pump.latest())==9_999,"Reading latest consumed the target")
        pump.delayCapture(until:120)
        require(!pump.captureReady(at:119.99),"Moving frame uploaded before settling")
        require(pump.captureReady(at:120),"Settled frame never became eligible")
        pump.delayCapture(until:121)
        require(!pump.captureReady(at:120.5),"A second move failed to defer capture")
        let region=target(71)
        pump.publish(region)
        let old=pump.selection()!
        pump.publish(target(72));pump.publish(region)
        require(!pump.isCurrent(old),"A to B to A revived a stale capture")
        let beforeRetry=pump.selection()!
        pump.delayCapture(until:125)
        require(!pump.isCurrent(beforeRetry),"Retry did not invalidate an in-flight image")
        let stable=pump.selection()!
        pump.publish(target(971))
        require(pump.isCurrent(stable),"A routine timestamp refresh invalidated unchanged geometry")
        var ack=CameraPumpMailbox.Statistics()
        ack.localQRSubmitted=true;ack.localSubmission=stable
        pump.update(ack)
        require(pump.canHandoff(at:126),"A current settled ACK could not hand off")
        pump.delayCapture(until:127)
        require(!pump.canHandoff(at:128),"Retry after ACK handed off the old submission")
        let duringACK=pump.selection()!
        pump.publish(target(72));pump.publish(target(971))
        ack.localSubmission=duringACK;pump.update(ack)
        require(!pump.canHandoff(at:129),"A to B to A during ACK handed off the old frame")

        var stats=CameraPumpMailbox.Statistics()
        require(stats.sendMilliseconds==0 && stats.responseWaitMilliseconds==0 &&
                stats.responseBodyMilliseconds==0,"New transport timings were not zero")
        stats.sent=47;stats.dropped=3;stats.fps=28.5;stats.firstFrameAcknowledgedAt=123.25
        stats.captureMilliseconds=7.25;stats.transferMilliseconds=4.5
        stats.sendMilliseconds=1.25;stats.responseWaitMilliseconds=2.5
        stats.responseBodyMilliseconds=0.75
        stats.maximumGapMilliseconds=110
        stats.localQRSubmitted=true
        pump.update(stats)
        let read=pump.snapshot()
        require(read.statistics.firstFrameAcknowledgedAt==123.25 && read.statistics.sent==47 && read.statistics.dropped==3 &&
                read.statistics.fps==28.5 && read.statistics.captureMilliseconds==7.25 &&
                read.statistics.transferMilliseconds==4.5 &&
                read.statistics.sendMilliseconds==1.25 &&
                read.statistics.responseWaitMilliseconds==2.5 &&
                read.statistics.responseBodyMilliseconds==0.75 &&
                read.statistics.maximumGapMilliseconds==110 && read.statistics.localQRSubmitted && read.failure==nil,
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
        let availability=CameraWindowAvailability()
        let fenced=CameraPumpMailbox(sourceIsAvailable:{availability.isAvailable})
        fenced.publish(target(1));let selected=fenced.selection()!
        var handoff=CameraPumpMailbox.Statistics();handoff.localQRSubmitted=true;handoff.localSubmission=selected
        fenced.update(handoff)
        require(fenced.captureReady(at:10) && fenced.isCurrent(selected) && fenced.canHandoff(at:10),"Live attempt did not admit frames")
        DispatchQueue.global().sync{availability.invalidate()}
        require(fenced.selection()==nil && fenced.latest()==nil && !fenced.captureReady(at:10) && !fenced.isCurrent(selected) && !fenced.canHandoff(at:10),"Lost mirror required a main-thread stop before refusing a send")
        fenced.publish(target(2));fenced.prepareRegion(at:10,immediateFirst:true)
        require(fenced.selection()==nil,"Geometry revived an invalidated attempt")
        let newAvailability=CameraWindowAvailability()
        let newAttempt=CameraPumpMailbox(sourceIsAvailable:{newAvailability.isAvailable})
        newAttempt.publish(target(3));availability.invalidate()
        require(newAvailability.isAvailable && newAttempt.selection() != nil,"Old invalidation killed a replacement")
        print("PASS latest drag target, concurrent snapshots, metrics, stop isolation and off-main attempt invalidation")
    }
}
