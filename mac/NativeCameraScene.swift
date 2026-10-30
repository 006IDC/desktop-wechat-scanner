import Foundation

/// Remembers a scene probed within one actual camera source lifetime. A result
/// Activity may keep the camera open; it must not automatically restart probing.
/// This is UI policy, never camera ownership or permission evidence.
struct NativeCameraScene {
    enum PreparationRecovery {case stop,retryTransition,showApplication}
    private let stream:Int,owner:Int,display:Int,package:String
    private var component:String
    private(set) var verified=false
    private(set) var startupTransitions=0

    init?(state:PhoneCameraState) {
        guard state.desktopCameraEnabled,let activity=state.captureActivity() else{return nil}
        stream=state.generation;owner=state.ownerGeneration
        display=activity.displayId;package=activity.package;component=activity.component
    }
    func sameSource(in state:PhoneCameraState)->Bool {
        state.desktopCameraEnabled && state.ownerKnown && state.cameraOwner==package && state.activeStreams>0 &&
            state.generation==stream && state.ownerGeneration==owner &&
            state.desktopCameraBindings.contains{$0.displayId==display && $0.packageName==package}
        // Global binding/capture revisions can change because another window
        // changed. Retain the scene while this binding and camera source live.
    }
    func permits(_ activity:PhoneCameraState.Activity,in state:PhoneCameraState)->Bool {
        !sameSource(in:state) || (activity.displayId==display && activity.package==package && activity.component==component)
    }
    mutating func markVerified(in state:PhoneCameraState)->Bool {
        guard sameSource(in:state),let activity=state.captureActivity(),permits(activity,in:state) else{return false}
        verified=true;return true
    }
    /// Camera-open can precede the Activity callback during initial entry. Only
    /// an unverified attempt may follow one such transition, before desktop input.
    mutating func retryStartupTransition(in state:PhoneCameraState)->Bool {
        guard !verified,startupTransitions==0,sameSource(in:state),let activity=state.captureActivity(),
              activity.displayId==display,activity.package==package,activity.component != component else{return false}
        component=activity.component;startupTransitions+=1;return true
    }
    /// Used even when a second state read rejects entry before an overlay exists.
    /// Result suppression must not latch off a later return to the same scanner.
    mutating func recoverPreparation(in state:PhoneCameraState)->PreparationRecovery {
        guard sameSource(in:state) else{return .stop}
        if retryStartupTransition(in:state) {return .retryTransition}
        if verified,let activity=state.captureActivity(),!permits(activity,in:state) {return .showApplication}
        return .stop
    }
}
