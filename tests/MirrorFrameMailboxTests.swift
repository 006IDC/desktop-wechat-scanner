import Foundation
import CoreGraphics
import Dispatch

@main enum MirrorFrameMailboxTests {
    static func require(_ condition:Bool,_ message:String) {
        if !condition {fatalError(message)}
    }
    static func fixture(_ marker:UInt8) -> CGImage {
        let bytes=Data([marker,255-marker,80,255])
        let provider=CGDataProvider(data:bytes as CFData)!
        return CGImage(width:1,height:1,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:4,
                       space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue),
                       provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
    }
    static func main() {
        let mailbox=MirrorFrameMailbox(),first=fixture(12),last=fixture(240)
        mailbox.publish(first,generation:0)
        require(mailbox.takeLatest()==nil,"Inactive mailbox accepted a frame")
        mailbox.reset(generation:1)
        let before=ProcessInfo.processInfo.systemUptime
        for _ in 0..<10_000 {mailbox.publish(first,generation:1)}
        mailbox.publish(last,generation:1)
        let after=ProcessInfo.processInfo.systemUptime
        let newest=mailbox.takeLatest()
        require(newest?.image === last,"Fast producer left an old frame for its slow consumer")
        require(newest?.generation==1,"Frame generation changed")
        require(newest!.receivedAt>=before && newest!.receivedAt<=after,"Arrival timestamp is outside publication interval")
        require(mailbox.takeLatest()==nil,"Mailbox retained a backlog after taking latest")

        mailbox.publish(first,generation:1);mailbox.reset(generation:2)
        require(mailbox.takeLatest()==nil,"Reset leaked a pending previous-generation frame")
        mailbox.publish(last,generation:1)
        require(mailbox.takeLatest()==nil,"Delayed previous-generation callback was accepted")
        mailbox.publish(first,generation:2);mailbox.stop()
        require(mailbox.takeLatest()==nil,"Stop leaked its pending frame")
        mailbox.publish(last,generation:2)
        require(mailbox.takeLatest()==nil,"Stopped mailbox accepted a delayed current callback")

        // Simulate a producer publishing a burst while its consumer is idle. Each
        // handshake lets the slow consumer observe exactly the last frame, once.
        mailbox.reset(generation:3)
        let available=DispatchSemaphore(value:0),consumed=DispatchSemaphore(value:0),producer=DispatchGroup()
        producer.enter()
        DispatchQueue.global(qos:.userInitiated).async {
            defer{producer.leave()}
            for _ in 0..<30 {
                for _ in 0..<500 {mailbox.publish(first,generation:3)}
                mailbox.publish(last,generation:3);available.signal()
                require(consumed.wait(timeout:.now()+5) == .success,"Slow consumer failed to acknowledge its batch")
            }
        }
        for _ in 0..<30 {
            require(available.wait(timeout:.now()+5) == .success,"Fast producer did not complete its burst")
            Thread.sleep(forTimeInterval:0.001)
            require(mailbox.takeLatest()?.image === last,"Slow consumer received a frame before the newest burst frame")
            require(mailbox.takeLatest()==nil,"Burst left queued historical frames")
            consumed.signal()
        }
        require(producer.wait(timeout:.now()+5) == .success,"Producer did not finish")

        // Multiple producer/consumer threads contend on the same single slot.
        mailbox.reset(generation:7)
        DispatchQueue.concurrentPerform(iterations:8) { worker in
            for _ in 0..<5_000 {
                if worker.isMultiple(of:2) {mailbox.publish(first,generation:7)}
                else if let frame=mailbox.takeLatest() {
                    require(frame.generation==7 && frame.image === first,"Concurrent slot returned corrupt metadata/image")
                }
            }
        }
        mailbox.reset(generation:8)
        // Old callbacks continue racing with new publications after the generation
        // switch; every successful take must belong to the new generation.
        DispatchQueue.concurrentPerform(iterations:8) { worker in
            for _ in 0..<5_000 {
                switch worker%3 {
                case 0:mailbox.publish(first,generation:7)
                case 1:mailbox.publish(last,generation:8)
                default:
                    if let frame=mailbox.takeLatest() {
                        require(frame.generation==8 && frame.image === last,"Old generation crossed the concurrent reset boundary")
                    }
                }
            }
        }
        mailbox.stop()
        DispatchQueue.concurrentPerform(iterations:8) { _ in
            for _ in 0..<500 {mailbox.publish(last,generation:8)}
        }
        require(mailbox.takeLatest()==nil,"Concurrent delayed publishers revived a stopped mailbox")
        mailbox.reset(generation:9)
        mailbox.publish(first,generation:8)
        require(mailbox.takeLatest()==nil,"Restart accepted the previous generation")
        mailbox.publish(last,generation:9)
        require(mailbox.takeLatest()?.image === last,"Current generation failed after stop/reset")
        print("PASS latest-only burst/slow-consumer, monotonic arrival metadata, generation reset/stop isolation, concurrent producers/consumers")
    }
}
