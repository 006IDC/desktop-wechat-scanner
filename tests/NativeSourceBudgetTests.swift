import Foundation
@main enum NativeSourceBudgetTests {
    static func simulate(adaptive:Bool,slow:Bool)->(acks:Int,heavyACKs:Int,maxGap:Double) {
        var budget=NativeSourceBudget(),clock=NativeGeometryClock(),pacer=NativeCapturePacer()
        var revision=0,published=0.0,lastACK:Double?,acks=0,heavyACKs=0,maxGap=0.0
        var work:(revision:Int,complete:Double,cost:Double)?
        for tick in 0..<600 {
            let now=Double(tick)/60
            if clock.due(at:now,minimumInterval:adaptive ? budget.minimumInterval:0) {revision+=1;published=now}
            if let pending=work,now>=pending.complete {
                if pending.revision==revision {
                    acks+=1;if now>=1.5 && now<3.5 {heavyACKs+=1}
                    if let previous=lastACK {maxGap=max(maxGap,now-previous)};lastACK=now
                    if adaptive {budget.acknowledged(milliseconds:pending.cost*1000)}
                } else if adaptive {budget.retired(milliseconds:pending.cost*1000)}
                work=nil
            }
            if work==nil,pacer.admit(publishedAt:published,now:now) {
                let cost=slow && now>=1.5 && now<3.5 ? 0.06:0.012
                work=(revision,now+cost,cost)
            }
        }
        return (acks,heavyACKs,maxGap)
    }
    static func main() {
        let normal=simulate(adaptive:false,slow:false),normalCandidate=simulate(adaptive:true,slow:false)
        precondition(normal.acks==normalCandidate.acks && normal.maxGap==normalCandidate.maxGap,"Healthy 30Hz work was throttled")
        let stalled=simulate(adaptive:false,slow:true),bounded=simulate(adaptive:true,slow:true)
        precondition(stalled.heavyACKs==0 && stalled.maxGap>1.9,"Fixture did not expose continual current-ROI retirement")
        precondition(bounded.heavyACKs>10 && bounded.maxGap<0.2,"Backpressure did not preserve progress under slow work")
        var b=NativeSourceBudget();b.retired(milliseconds:.nan);b.retired(milliseconds:24);precondition(b.minimumInterval==0)
        b.retired(milliseconds:2000);precondition(b.minimumInterval==0.1)
        b.acknowledged(milliseconds:12);b.acknowledged(milliseconds:12);precondition(b.minimumInterval>0)
        b.acknowledged(milliseconds:30);b.acknowledged(milliseconds:12);b.acknowledged(milliseconds:12);precondition(b.minimumInterval>0)
        b.acknowledged(milliseconds:12);precondition(b.minimumInterval==0)
        var moderate=NativeSourceBudget();moderate.retired(milliseconds:90)
        for _ in 0..<60 {moderate.acknowledged(milliseconds:28)}
        precondition(moderate.minimumInterval>0 && moderate.minimumInterval<0.05,"Moderate recovery remained stuck at an old 100ms budget")
        for _ in 0..<600 {moderate.acknowledged(milliseconds:90)}
        precondition(moderate.minimumInterval<=0.1 && moderate.minimumInterval>0,"Sustained load escaped its bounded pacing")
        let beforeInvalid=moderate.minimumInterval;moderate.acknowledged(milliseconds:.nan);moderate.acknowledged(milliseconds:-1)
        precondition(moderate.minimumInterval==beforeInvalid)
        var c=NativeGeometryClock();precondition(!c.due(at:0,minimumInterval:.nan));precondition(!c.due(at:0,minimumInterval:0.101))
        print("PASS unchanged healthy throughput; same-revision ACKs under 60ms work: old \(stalled.heavyACKs), bounded \(bounded.heavyACKs); max gap \(stalled.maxGap) -> \(bounded.maxGap); bounds and recovery")
    }
}
