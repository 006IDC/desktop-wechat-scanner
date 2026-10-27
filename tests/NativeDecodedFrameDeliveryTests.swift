import Foundation
import CoreVideo
import Dispatch

@main enum NativeDecodedFrameDeliveryTests {
    @MainActor static func main() throws {
        var created:CVPixelBuffer?
        precondition(CVPixelBufferCreate(kCFAllocatorDefault,2,2,kCVPixelFormatType_32BGRA,nil,&created)==kCVReturnSuccess)
        let pixels=created!,mailbox=MirrorVideoMailbox()
        mailbox.reset(generation:7)
        let overlay=NativeScannerOverlay(display:1,package:"com.tencent.mm")
        try overlay.observeDecodedFrames(in:mailbox,generation:7)
        overlay.statistics.submitted() // Start arrival timing without a GPU drawable.
        let done=DispatchSemaphore(value:0)
        let sample=MirrorVideoMailbox.Frame(pixelBuffer:pixels,generation:7,receivedAt:0)
        DispatchQueue.global(qos:.userInitiated).async { [sample] in
            mailbox.publish(sample.pixelBuffer,generation:sample.generation);done.signal()
        }
        // The MainActor deliberately cannot service timers here. Decoded input
        // must still reach the native renderer's bounded frame slot.
        precondition(done.wait(timeout:.now()+2) == .success,"Decoded video waited for the MainActor")
        precondition(overlay.statistics.snapshot()["receivedFrames"] as? Int == 1)
        _=overlay.receive(pixels)
        precondition(overlay.statistics.snapshot()["receivedFrames"] as? Int == 1,"UI timer double-published native input")

        let next=NativeScannerOverlay(display:1,package:"com.tencent.mm")
        try next.observeDecodedFrames(in:mailbox,generation:7);next.statistics.submitted()
        overlay.freeze() // A late old-overlay cleanup must preserve the new binding.
        mailbox.publish(pixels,generation:7)
        precondition(next.statistics.snapshot()["receivedFrames"] as? Int == 1,"Old overlay detached its replacement")
        precondition(overlay.statistics.snapshot()["receivedFrames"] as? Int == 1,"Frozen overlay accepted decoded input")
        next.freeze();mailbox.publish(pixels,generation:7);_=next.receive(pixels)
        precondition(next.statistics.snapshot()["receivedFrames"] as? Int == 1,"Freeze revived a stopped native slot")
        let stale=NativeScannerOverlay(display:1,package:"com.tencent.mm")
        do {try stale.observeDecodedFrames(in:mailbox,generation:6);fatalError("Stale incarnation bound native input")}
        catch is ScanError {}
        mailbox.stop()
        print("PASS native decoded delivery while MainActor is blocked; no double publish; replacement/freeze/epoch isolation. Synthetic only.")
    }
}
