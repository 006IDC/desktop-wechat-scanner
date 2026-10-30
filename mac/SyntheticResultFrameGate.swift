import Foundation

/// Local diagnostic provenance only: never evidence of Android paint time.
/// A static result may stop producing frames, so do not age out a valid frame
/// that arrived after this QR was enabled on the same live mirror incarnation.
enum SyntheticResultFrameGate {
    static func admits(currentRoute:Bool,frameGeneration:Int,currentGeneration:Int,
                       receivedAt:TimeInterval,shownAt:TimeInterval,now:TimeInterval)->Bool {
        currentRoute && currentGeneration>0 && frameGeneration==currentGeneration &&
            [receivedAt,shownAt,now].allSatisfy{$0.isFinite && $0>=0} &&
            shownAt<=receivedAt && receivedAt<=now
    }
}
