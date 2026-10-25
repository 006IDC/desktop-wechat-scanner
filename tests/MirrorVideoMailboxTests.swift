import Foundation
import CoreVideo
import Dispatch

@main enum MirrorVideoMailboxTests {
    static func require(_ condition:Bool,_ message:String) {
        if !condition {fatalError(message)}
    }
    static func fixture() -> CVPixelBuffer {
        var buffer:CVPixelBuffer?
        let status=CVPixelBufferCreate(kCFAllocatorDefault,2,2,kCVPixelFormatType_32BGRA,nil,&buffer)
        require(status==kCVReturnSuccess && buffer != nil,"Could not create test pixel buffer")
        return buffer!
    }
    static func main() {
        let mailbox=MirrorVideoMailbox(),first=fixture(),last=fixture()
        mailbox.publish(first,generation:0)
        require(mailbox.takeLatest()==nil,"Inactive mailbox accepted a frame")
        mailbox.reset(generation:1)
        let before=ProcessInfo.processInfo.systemUptime
        for _ in 0..<10_000 {mailbox.publish(first,generation:1)}
        mailbox.publish(last,generation:1)
        let after=ProcessInfo.processInfo.systemUptime
        let newest=mailbox.takeLatest()
        require(newest?.pixelBuffer === last,"Fast producer left an old frame")
        require(newest?.generation==1,"Frame generation changed")
        require(newest!.receivedAt>=before && newest!.receivedAt<=after,"Arrival timestamp invalid")
        require(mailbox.takeLatest()==nil,"Mailbox retained a backlog")

        mailbox.publish(first,generation:1);mailbox.reset(generation:2)
        require(mailbox.takeLatest()==nil,"Reset leaked an old frame")
        mailbox.publish(last,generation:1)
        require(mailbox.takeLatest()==nil,"Delayed old generation was accepted")
        mailbox.publish(first,generation:2);mailbox.stop()
        require(mailbox.takeLatest()==nil,"Stop leaked a frame")
        mailbox.publish(last,generation:2)
        require(mailbox.takeLatest()==nil,"Stopped mailbox accepted a callback")

        mailbox.reset(generation:3)
        let available=DispatchSemaphore(value:0),consumed=DispatchSemaphore(value:0),producer=DispatchGroup()
        producer.enter()
        DispatchQueue.global(qos:.userInitiated).async {
            defer{producer.leave()}
            for _ in 0..<30 {
                for _ in 0..<500 {mailbox.publish(first,generation:3)}
                mailbox.publish(last,generation:3);available.signal()
                require(consumed.wait(timeout:.now()+5) == .success,"Slow consumer failed")
            }
        }
        for _ in 0..<30 {
            require(available.wait(timeout:.now()+5) == .success,"Fast producer failed")
            Thread.sleep(forTimeInterval:0.001)
            require(mailbox.takeLatest()?.pixelBuffer === last,"Slow consumer received stale frame")
            require(mailbox.takeLatest()==nil,"Burst left queued frames")
            consumed.signal()
        }
        require(producer.wait(timeout:.now()+5) == .success,"Producer did not finish")

        mailbox.reset(generation:7)
        DispatchQueue.concurrentPerform(iterations:8) { worker in
            for _ in 0..<5_000 {
                if worker.isMultiple(of:2) {mailbox.publish(first,generation:7)}
                else if let frame=mailbox.takeLatest() {
                    require(frame.generation==7 && frame.pixelBuffer === first,"Concurrent slot corrupted")
                }
            }
        }
        mailbox.reset(generation:8)
        DispatchQueue.concurrentPerform(iterations:8) { worker in
            for _ in 0..<5_000 {
                switch worker%3 {
                case 0:mailbox.publish(first,generation:7)
                case 1:mailbox.publish(last,generation:8)
                default:
                    if let frame=mailbox.takeLatest() {
                        require(frame.generation==8 && frame.pixelBuffer === last,"Old generation crossed reset")
                    }
                }
            }
        }
        mailbox.stop()
        DispatchQueue.concurrentPerform(iterations:8) { _ in
            for _ in 0..<500 {mailbox.publish(last,generation:8)}
        }
        require(mailbox.takeLatest()==nil,"Concurrent publishers revived stopped mailbox")
        print("PASS CVPixelBuffer latest-only mailbox, generation isolation, concurrency")
    }
}
