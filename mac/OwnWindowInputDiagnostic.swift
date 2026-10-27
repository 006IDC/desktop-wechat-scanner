import AppKit

/// Explicit synthetic-board diagnostic only. Observe mouse events delivered to
/// our own window; no global monitor, keyboard, screen pixels or OS input.
@MainActor final class OwnWindowInputDiagnostic {
    private weak var window:NSWindow?
    private var monitor:Any?
    private var down=0,dragged=0,up=0,titleDown=0
    private var positions=[[Double]]()
    init(window:NSWindow) {
        self.window=window
        monitor=NSEvent.addLocalMonitorForEvents(matching:[.leftMouseDown,.leftMouseDragged,.leftMouseUp]) { [weak self] event in
            guard let self,event.window === self.window else{return event}
            switch event.type {
            case .leftMouseDown:
                self.down+=1
                if event.locationInWindow.y >= window.contentLayoutRect.maxY {self.titleDown+=1}
                if self.positions.count<8 {self.positions.append([event.locationInWindow.x,event.locationInWindow.y])}
            case .leftMouseDragged:self.dragged+=1
            case .leftMouseUp:self.up+=1
            default:break
            }
            return event
        }
    }
    func finish()->[String:Any] {
        if let monitor {NSEvent.removeMonitor(monitor);self.monitor=nil}
        return ["down":down,"dragged":dragged,"up":up,"titleDown":titleDown,"firstDownWindowPoints":positions,
            "windowWidth":window?.frame.width ?? 0,"windowHeight":window?.frame.height ?? 0,
            "contentTopWindowPoints":window?.contentLayoutRect.maxY ?? 0]
    }
}
