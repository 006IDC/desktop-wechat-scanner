import Foundation

/// Observe camera closure after sleeping only the authenticated owned device.
/// Never navigates an application page or injects Back. In-flight transport
/// timeouts remain bounded by CameraSocket, outside this polling budget.
enum OwnedCameraCleanup {
    static func quiesce(read:() throws -> PhoneCameraState,
                        now:()->TimeInterval={ProcessInfo.processInfo.systemUptime},
                        wait:()->Void={Thread.sleep(forTimeInterval:0.05)}) throws {
        func released(_ state:PhoneCameraState)->Bool {
            state.activeStreams==0 && state.ownerKnown && state.cameraOwner==nil
        }
        let deadline=now()+2
        var previous:PhoneCameraState?
        while now()<deadline {
            let current=try read()
            if released(current),let previous,released(previous),
               current.generation==previous.generation,current.ownerGeneration==previous.ownerGeneration {return}
            previous=current
            wait()
        }
        throw ScanError("手机扫码相机尚未确认关闭，已保留会话，未关闭虚拟设备。")
    }
}
