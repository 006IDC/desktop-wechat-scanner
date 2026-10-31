import Foundation
@main enum NativeGeometryClockTests {
    static func main() {
        var clock=NativeGeometryClock(),count=0,oldCount=0,oldNext=0.0
        for i in 0..<600 {
            let now=1000+Double(i)/60+0.0005*sin(Double(i)*1.3)
            if clock.due(at:now) {count+=1}
            precondition(!clock.due(at:now),"Same timer slot published twice")
            if now>=oldNext {oldCount+=1;oldNext=now+1/30}
        }
        precondition((299...301).contains(count),"Small timer jitter reduced the 30 Hz target")
        precondition(oldCount<270,"Fixture did not reproduce deadline drift")
        precondition(!clock.due(at:.nan) && !clock.due(at:.infinity) && !clock.due(at:-1))
        precondition(!clock.due(at:999),"A backwards clock republished retired geometry")
        precondition(clock.due(at:1020))
        precondition(!clock.due(at:1020),"Missed slots caused a catch-up burst")
        precondition(!clock.due(at:Double.greatestFiniteMagnitude))
        print("PASS fixed geometry phase under 60 Hz jitter: \(count) publications versus prior \(oldCount); invalid times and catch-up rejection")
    }
}
