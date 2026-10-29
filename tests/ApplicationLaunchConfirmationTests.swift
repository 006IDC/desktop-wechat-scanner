import Foundation

@main enum ApplicationLaunchConfirmationTests {
    static func main() {
        // Simulate a task becoming foreground at different instants. Early
        // checks must retain the old final opportunity and bounded query cost.
        var times=[0.0]
        for index in 0..<ApplicationLaunchConfirmation.maximumChecks-1 {
            guard let delay=ApplicationLaunchConfirmation.delay(afterCheck:index) else{preconditionFailure()}
            precondition(delay>=0.1 && delay<=0.3)
            times.append(times.last!+delay)
        }
        precondition(times.count==8)
        precondition(abs(times.last!-1.4)<0.000_001)
        for (index,time) in times.enumerated() {precondition(time<=Double(index)*0.2+0.000_001)}
        let firstCheckAfterReadiness:(Double)->Double?={ready in times.first{$0+0.000_001>=ready}}
        precondition(firstCheckAfterReadiness(0.08)==0.1)
        precondition(firstCheckAfterReadiness(0.18)==0.2)
        precondition(abs(firstCheckAfterReadiness(1.39)!-1.4)<0.000_001)
        precondition(firstCheckAfterReadiness(1.41)==nil)
        // The sampling grid changes: a transient foreground at 0.8s can be
        // missed. Preserve this limit rather than claiming every old sample is
        // retained; the latency benefit assumes the target remains foreground.
        precondition(!times.contains{(0.79...0.81).contains($0)})
        for index in [-1,7,8,Int.max] {precondition(ApplicationLaunchConfirmation.delay(afterCheck:index)==nil)}
        print("PASS bounded launch checks, earlier observation, retained late opportunity and no final idle wait; no device")
    }
}
