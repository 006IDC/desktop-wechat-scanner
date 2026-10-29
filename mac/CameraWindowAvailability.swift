import Foundation

/// One-way lifetime fence for one detached mirror attempt. The decoder may
/// invalidate it without waiting for AppKit; a retry always gets a new instance.
final class CameraWindowAvailability:@unchecked Sendable {
    private let lock=NSLock()
    private var available=true
    var isAvailable:Bool {lock.withLock{available}}
    func invalidate(){lock.withLock{available=false}}
}
