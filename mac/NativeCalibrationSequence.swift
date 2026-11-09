import Foundation
import CoreVideo

/// Coordinates observations only. No source admission, rendering or phone
/// ownership is granted by this schedule; callers retain those checks.
@MainActor enum NativeCalibrationSequence {
    struct RetrySequential:Error {}
    private struct Command {let before:Int,began:Double}

    /// The caller's operation owns and joins its upload tasks before it throws.
    /// Only a timing mismatch may retry; cancellation/ownership/RPC errors escape.
    static func run<T>(overlap:Bool,verify:()async throws->Void,
                       retry:()->Void,operation:(Bool)async throws->T) async throws->T {
        do {return try await operation(overlap)}
        catch is RetrySequential where overlap {
            try Task.checkCancellation()
            try await verify()
            try Task.checkCancellation()
            retry()
            return try await operation(false)
        }
    }

    static func collect(overlap:Bool,began:Double,clock:()->Double,latest:()->Int,
                        command:(UInt8)async throws->Void,
                        read:(Int,Double,Double)async throws->NativeScannerFrames.Sample,
                        verify:()async throws->Void,ready:(UInt8,CVPixelBuffer)->Bool,
                        hide:()->Void,upload:(Int,CVPixelBuffer)->Void,
                        record:(String,Double)->Void) async throws->[CVPixelBuffer] {
        var samples=[CVPixelBuffer](),prestarted=[UInt8:Command]()
        for phase:UInt8 in 0...2 {
            try Task.checkCancellation()
            if phase>0 {hide()}
            let prior=prestarted[phase]
            let before=prior?.before ?? latest(),phaseBegan=prior?.began ?? clock()
            if prior==nil {
                try await command(phase)
                record("phase\(phase)CommandMilliseconds",(clock()-phaseBegan)*1000)
            }
            record("phase\(phase)Prestarted",prior == nil ? 0:1)
            record("phase\(phase)CommandStartedMilliseconds",(phaseBegan-began)*1000)
            let deadline=clock()+2
            var observed=before,lastAccepted=0.0,firstAccepted:Double?,accepted=0,rejected=0
            var nextStateCheck=clock()+0.08,ownershipMilliseconds=0.0
            while accepted<3 {
                try Task.checkCancellation()
                let pending=prestarted[phase+1] != nil
                let sample:NativeScannerFrames.Sample
                do {
                    sample=try await read(observed,lastAccepted>0 ? lastAccepted+0.04:0,
                                          pending ? min(deadline,clock()+0.25):deadline)
                } catch NativeScannerFrames.Failure.timedOut where pending {throw RetrySequential()}
                observed=sample.revision
                if clock()>=nextStateCheck {
                    let check=clock();try await verify();ownershipMilliseconds+=(clock()-check)*1000
                    nextStateCheck=clock()+0.08
                }
                guard ready(phase,sample.pixels) else {
                    rejected+=1
                    if pending,(ready(phase+1,sample.pixels) || (lastAccepted>0 && sample.receivedAt-lastAccepted>0.25)) {
                        throw RetrySequential()
                    }
                    continue
                }
                if firstAccepted==nil {
                    firstAccepted=sample.receivedAt
                    record("phase\(phase)FirstMatchMilliseconds",(clock()-phaseBegan)*1000)
                }
                let index=samples.count;samples.append(sample.pixels);upload(index,sample.pixels)
                lastAccepted=sample.receivedAt;accepted+=1
                if overlap,phase<2,accepted==2 {
                    // Third original-color observation stays mandatory. If the
                    // new color outruns it, the caller retries serially once.
                    hide();let next=phase+1,before=latest(),start=clock()
                    try await command(next)
                    prestarted[next]=Command(before:before,began:start)
                    record("phase\(next)CommandMilliseconds",(clock()-start)*1000)
                }
            }
            try await verify()
            record("phase\(phase)ReadyMilliseconds",(clock()-began)*1000)
            record("phase\(phase)SampleSpanMilliseconds",(lastAccepted-(firstAccepted ?? lastAccepted))*1000)
            record("phase\(phase)LastSampleReceivedMilliseconds",(lastAccepted-began)*1000)
            record("phase\(phase)RejectedFrames",Double(rejected))
            record("phase\(phase)OwnershipCheckMilliseconds",ownershipMilliseconds)
        }
        return samples
    }
}
