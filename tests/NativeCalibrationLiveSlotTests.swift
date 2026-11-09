import Foundation
import CoreVideo

/// Real latest-only slot, async publication and RPC-like suspension. No phone,
/// screen, Metal renderer or global input is used by this regression.
@main @MainActor enum NativeCalibrationLiveSlotTests {
    final class Source {
        let frames=NativeScannerFrames(),images:[CVPixelBuffer]
        var phase:UInt8=0,paused=false,pauseOnce:Bool,fast:Bool
        var publisher:Task<Void,Never>?,transition:Task<Void,Never>?
        init(fast:Bool,pauseOnce:Bool=false) {
            self.fast=fast;self.pauseOnce=pauseOnce
            images=(0...2).map{phase in
                var value:CVPixelBuffer?;precondition(CVPixelBufferCreate(nil,96,128,kCVPixelFormatType_32BGRA,nil,&value)==kCVReturnSuccess)
                let p=value!;CVPixelBufferLockBaseAddress(p,[])
                let bytes=CVPixelBufferGetBaseAddress(p)!.assumingMemoryBound(to:UInt8.self),row=CVPixelBufferGetBytesPerRow(p)
                for y in 0..<128 {for x in 0..<96 {
                    let i=y*row+x*4;bytes[i]=phase==0 ? 0:255;bytes[i+1]=phase==1 ? 255:0;bytes[i+2]=phase==1 ? 255:0;bytes[i+3]=255
                }}
                CVPixelBufferUnlockBaseAddress(p,[]);return p
            }
        }
        func start() {
            publisher=Task {
                while !Task.isCancelled {
                    if !paused {_ = frames.publish(images[Int(phase)])}
                    try? await Task.sleep(nanoseconds:10_000_000)
                }
            }
        }
        func command(_ phase:UInt8) {
            transition?.cancel()
            if fast {
                self.phase=phase
                // Force the real latest slot to overwrite the old candidate
                // before collection resumes, even under test-runner jitter.
                _ = frames.publish(images[Int(phase)])
            }
            else {
                transition=Task {
                    do {try await Task.sleep(nanoseconds:120_000_000)}catch{return}
                    self.phase=phase
                }
            }
            if phase==1,pauseOnce {pauseOnce=false;paused=true}
        }
        func stop() async {
            frames.stop();publisher?.cancel();transition?.cancel()
            await publisher?.value;await transition?.value
        }
    }
    static func test(fast:Bool,pause:Bool) async throws {
        let source=Source(fast:fast,pauseOnce:pause);source.start()
        var attempts=[Bool](),retries=0,colors=[Int](),statistics=[String:Double]()
        do {
            let samples=try await NativeCalibrationSequence.run(overlap:true,verify:{},retry:{retries+=1;colors=[];source.paused=false},operation:{overlap in
                attempts.append(overlap)
                return try await NativeCalibrationSequence.collect(overlap:overlap,began:ProcessInfo.processInfo.systemUptime,
                    clock:{ProcessInfo.processInfo.systemUptime},latest:{source.frames.latest().0},command:{source.command($0)},
                    read:{revision,notBefore,deadline in
                        let remaining=deadline-ProcessInfo.processInfo.systemUptime
                        guard remaining>0 else{throw NativeScannerFrames.Failure.timedOut}
                        return try await source.frames.wait(after:revision,notBefore:notBefore,timeout:remaining)
                    },verify:{try await Task.sleep(nanoseconds:30_000_000)},ready:{phase,pixels in
                        if phase==0 {return NativeCalibrationReadiness.blackEndpointVisible(pixels)}
                        if phase==1 {return NativeCalibrationReadiness.whiteEndpointVisible(pixels)}
                        return pixels === source.images[2]
                    },hide:{},upload:{_,pixels in colors.append(source.images.firstIndex(where:{$0 === pixels})!)},record:{statistics[$0]=$1})
            })
            precondition(samples.count==9 && colors==[0,0,0,1,1,1,2,2,2])
            for phase in 0...2 {precondition(statistics["phase\(phase)SampleSpanMilliseconds"]!>=79.99)}
            if fast || pause {precondition(retries==1 && attempts==[true,false])}
            else {precondition(retries<=1)}
            await source.stop();precondition(!source.frames.hasWaiter)
        } catch {await source.stop();throw error}
    }
    static func main() async throws {
        try await test(fast:false,pause:false)
        try await test(fast:true,pause:false)
        try await test(fast:false,pause:true)
        print("PASS real latest-only slot across suspended validation; early successor and absent third sample fall back once; nine colors/40ms retained; publisher/waiters stopped")
    }
}
