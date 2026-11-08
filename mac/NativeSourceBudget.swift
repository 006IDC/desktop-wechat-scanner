import Foundation

/// Avoid continual retirement when processing outlasts the ordinary ROI slot.
/// This paces new native-camera selections only, never rendering or admission.
struct NativeSourceBudget:Sendable {
    private(set) var minimumInterval:Double=0
    private var quickAcknowledgements=0
    mutating func retired(milliseconds:Double) {
        guard milliseconds.isFinite,milliseconds>=25 else{return}
        minimumInterval=min(0.1,max(minimumInterval,milliseconds*0.0012+0.01))
        quickAcknowledgements=0
    }
    mutating func acknowledged(milliseconds:Double) {
        guard minimumInterval>0,milliseconds.isFinite,milliseconds>=0 else{return}
        if milliseconds<24 {quickAcknowledgements+=1} else {quickAcknowledgements=0}
        if quickAcknowledgements>=3 {minimumInterval=0;quickAcknowledgements=0;return}
        // A recovered but not yet fast path must not remain at an earlier
        // 100ms budget forever. Contract gradually using complete work-to-ACK.
        let needed=min(0.1,max(1.0/30,milliseconds*0.0012+0.01))
        minimumInterval=max(needed,minimumInterval*0.8)
    }
}
