import Foundation
import CoreVideo

@main @MainActor enum NativeCalibrationSequenceTests {
    enum Fault:Error {case rpc,owner}
    final class Simulator {
        var now=10.0,revision=0,output:UInt8=0,transitions=[(Double,UInt8)]()
        var issued=[UInt8](),uploaded=[Int](),statistics=[String:Double]()
        var retryCount=0,attempts=[Bool](),timeoutOnce=false,cancelCommand=false,rpcError=false
        let latency:Double
        let images:[CVPixelBuffer]
        init(latency:Double) {
            self.latency=latency
            images=(0...2).map {phase in
                var image:CVPixelBuffer?
                precondition(CVPixelBufferCreate(nil,96,128,kCVPixelFormatType_32BGRA,nil,&image)==kCVReturnSuccess)
                let p=image!;CVPixelBufferLockBaseAddress(p,[])
                let b=CVPixelBufferGetBaseAddress(p)!.assumingMemoryBound(to:UInt8.self),row=CVPixelBufferGetBytesPerRow(p)
                for y in 0..<128 {for x in 0..<96 {
                    let i=y*row+x*4;b[i]=phase==0 ? 0:255;b[i+1]=phase==1 ? 255:0;b[i+2]=phase==1 ? 255:0;b[i+3]=255
                }}
                CVPixelBufferUnlockBaseAddress(p,[]);return p
            }
        }
        func set(_ phase:UInt8) throws {
            if phase==1,cancelCommand {throw CancellationError()}
            if phase==1,rpcError {throw Fault.rpc}
            issued.append(phase);transitions.append((now+latency,phase));now+=0.002
        }
        func read(after:Int,notBefore:Double,deadline:Double) throws ->NativeScannerFrames.Sample {
            if timeoutOnce,issued.contains(1) {timeoutOnce=false;throw NativeScannerFrames.Failure.timedOut}
            while true {
                now+=0.02
                guard now<deadline else{throw NativeScannerFrames.Failure.timedOut}
                while let next=transitions.first,next.0<=now {output=next.1;transitions.removeFirst()}
                revision+=1
                if revision>after,now>=notBefore {return .init(revision:revision,pixels:images[Int(output)],receivedAt:now)}
            }
        }
        func collect(_ overlap:Bool) async throws ->[CVPixelBuffer] {
            attempts.append(overlap)
            return try await NativeCalibrationSequence.collect(overlap:overlap,began:now,clock:{self.now},latest:{self.revision},
                command:{try self.set($0)},read:{try self.read(after:$0,notBefore:$1,deadline:$2)},verify:{self.now+=0.002},
                ready:{phase,pixels in
                    if phase==0 {return NativeCalibrationReadiness.blackEndpointVisible(pixels)}
                    if phase==1 {return NativeCalibrationReadiness.whiteEndpointVisible(pixels)}
                    return pixels === self.images[2]
                },hide:{},upload:{_,pixels in self.uploaded.append(self.images.firstIndex(where:{$0 === pixels})!)},record:{self.statistics[$0]=$1})
        }
        func run(_ overlap:Bool) async throws ->[CVPixelBuffer] {
            try await NativeCalibrationSequence.run(overlap:overlap,verify:{self.now+=0.002},retry:{self.retryCount+=1;self.uploaded=[]},operation:{try await self.collect($0)})
        }
    }
    static func main() async throws {
        let serial=Simulator(latency:0.12),pipeline=Simulator(latency:0.12)
        _=try await serial.run(false);_=try await pipeline.run(true)
        let expected=[0,0,0,1,1,1,2,2,2]
        precondition(serial.uploaded==expected && pipeline.uploaded==expected,"A color transition replaced one of the nine actual observations")
        precondition(pipeline.now<serial.now-0.07 && pipeline.retryCount==0)
        for phase in 0...2 {precondition(pipeline.statistics["phase\(phase)SampleSpanMilliseconds"]!>=79.999)}
        precondition(pipeline.statistics["phase1CommandStartedMilliseconds"]!<pipeline.statistics["phase0LastSampleReceivedMilliseconds"]!)
        precondition(pipeline.statistics["phase2CommandStartedMilliseconds"]!<pipeline.statistics["phase1LastSampleReceivedMilliseconds"]!)
        let fast=Simulator(latency:0.005);_=try await fast.run(true)
        precondition(fast.retryCount==1 && fast.attempts==[true,false] && fast.uploaded==expected,"Fast successor did not fall back safely")
        let dropped=Simulator(latency:0.12);dropped.timeoutOnce=true;_=try await dropped.run(true)
        precondition(dropped.retryCount==1 && dropped.attempts==[true,false] && dropped.uploaded==expected,"Missing third frame did not fall back")
        let cancelled=Simulator(latency:0.12);cancelled.cancelCommand=true
        do {_=try await cancelled.run(true);preconditionFailure()}catch is CancellationError {}
        precondition(cancelled.retryCount==0 && cancelled.attempts==[true])
        let rpc=Simulator(latency:0.12);rpc.rpcError=true
        do {_=try await rpc.run(true);preconditionFailure()}catch Fault.rpc {}
        precondition(rpc.retryCount==0 && rpc.attempts==[true])
        var attempts=0,retries=0
        do {
            let _:Int=try await NativeCalibrationSequence.run(overlap:true,verify:{throw Fault.owner},retry:{retries+=1},operation:{_ in attempts+=1;throw NativeCalibrationSequence.RetrySequential()})
            preconditionFailure()
        }catch Fault.owner {}
        precondition(attempts==1 && retries==0,"Changed owner was retried")
        attempts=0;retries=0
        do {
            let _:Int=try await NativeCalibrationSequence.run(overlap:true,verify:{},retry:{retries+=1},operation:{_ in attempts+=1;throw NativeCalibrationSequence.RetrySequential()})
            preconditionFailure()
        }catch is NativeCalibrationSequence.RetrySequential {}
        precondition(attempts==2 && retries==1,"Fallback was unbounded")
        final class Jobs:@unchecked Sendable {
            let lock=NSLock();var started=0,ended=0
            func begin(){lock.withLock{started+=1}}
            func end(){lock.withLock{ended+=1}}
            var drained:Bool {lock.withLock{started==ended && started>0}}
        }
        let jobs=Jobs()
        let value:Int=try await NativeCalibrationSequence.run(overlap:true,verify:{precondition(jobs.drained)},retry:{},operation:{overlap in
            try await withThrowingTaskGroup(of:Void.self) {group in
                defer{group.cancelAll()}
                group.addTask {
                    jobs.begin();defer{jobs.end()}
                    try? await Task.sleep(nanoseconds:1_000_000)
                }
                if overlap {throw NativeCalibrationSequence.RetrySequential()}
                return 42
            }
        })
        precondition(value==42 && jobs.drained,"Upload tasks escaped their attempt before retry/return")
        print("PASS real nine-color sequence and 40ms spacing; overlapping transitions; fast/missing-frame fallback once; cancellation, RPC and owner errors fail without retry")
    }
}
