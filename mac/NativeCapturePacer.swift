import Foundation

/// Capture immediately after the existing <=30Hz geometry publisher, rather
/// than starting near the end of its interval and repeatedly retiring work.
/// Does not authorize images: all ROI, camera and lease checks still apply.
struct NativeCapturePacer {
    private var lastPublication:TimeInterval?
    mutating func admit(publishedAt time:TimeInterval,now:TimeInterval)->Bool {
        guard time.isFinite,time>=0,now.isFinite,now>=time,now-time<=0.012,
              lastPublication.map({time>$0}) ?? true else{return false}
        lastPublication=time;return true
    }
}
