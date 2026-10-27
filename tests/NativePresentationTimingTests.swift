import Foundation
@main enum NativePresentationTimingTests {
 static func main() {
  let stats=NativeMattePresentationStats()
  stats.received(at:1);stats.submitted()
  stats.received(at:2);stats.received(at:2.016);stats.received(at:2.116)
  stats.received(at:.nan);stats.received(at:0)
  stats.drawableWait(milliseconds:2);stats.drawableWait(milliseconds:120)
  stats.drawableWait(milliseconds:-1);stats.drawableWait(milliseconds:.infinity)
  stats.completed(ok:true,gpuMilliseconds:3);stats.presented(at:2)
  let s=stats.snapshot()
  precondition(s["receivedFrames"] as? Int == 3 && s["receiveIntervalSamples"] as? Int == 2)
  precondition(abs((s["receiveIntervalMaxMilliseconds"] as! Double)-100)<0.0001)
  precondition(s["drawableWaitSamples"] as? Int == 2 && s["drawableWaitMaxMilliseconds"] as? Double == 120)
  precondition(s["gpuMaxMilliseconds"] as? Double == 3 && s["complete"] as? Bool == true)
  for i in 0..<10000 {stats.received(at:3+Double(i)*0.016);stats.drawableWait(milliseconds:1)}
  let bounded=stats.snapshot()
  precondition(bounded["receiveIntervalSamples"] as? Int == 7200 && bounded["drawableWaitSamples"] as? Int == 7200)
  print("PASS native timing: calibration excluded, arrival/drawable/GPU clocks separated, invalid values rejected, bounded samples. Synthetic only.")
 }
}
