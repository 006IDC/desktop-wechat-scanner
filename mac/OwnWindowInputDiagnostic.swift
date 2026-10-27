import AppKit

/// Explicit synthetic-board diagnostic only. Observe mouse events delivered to
/// our own window; no global monitor, keyboard, screen pixels or OS input.
@MainActor final class OwnWindowInputDiagnostic {
    private weak var window:NSWindow?
    private var monitor:Any?
    private var down=0,dragged=0,up=0,titleDown=0
    private var positions=[[Double]](),dragPositions=[[Double]]()
    private var firstDownServerBounds:CGRect?,lastUpServerBounds:CGRect?
    private var completedEvidence:[String:Any]?
    private func serverBounds()->CGRect? {
        guard let window,window.windowNumber>0,
              let descriptions=WindowCaptureGeometry.ownWindowDescriptions(for:window) else{return nil}
        return WindowCaptureGeometry.serverBounds(from:descriptions,windowID:CGWindowID(window.windowNumber),
            ownerPID:ProcessInfo.processInfo.processIdentifier)
    }
    init(window:NSWindow) {
        self.window=window
        monitor=NSEvent.addLocalMonitorForEvents(matching:[.leftMouseDown,.leftMouseDragged,.leftMouseUp]) { [weak self] event in
            guard let self,event.window === self.window else{return event}
            switch event.type {
            case .leftMouseDown:
                self.down+=1
                if self.firstDownServerBounds == nil {self.firstDownServerBounds=self.serverBounds()}
                if event.locationInWindow.y >= window.contentLayoutRect.maxY {self.titleDown+=1}
                if self.positions.count<8 {self.positions.append([event.locationInWindow.x,event.locationInWindow.y])}
            case .leftMouseDragged:
                self.dragged+=1
                if self.dragPositions.count<8 {self.dragPositions.append([event.locationInWindow.x,event.locationInWindow.y])}
            case .leftMouseUp:
                self.up+=1;self.lastUpServerBounds=self.serverBounds()
            default:break
            }
            return event
        }
    }
    func finish()->[String:Any] {
        if let completedEvidence {return completedEvidence}
        if let monitor {NSEvent.removeMonitor(monitor);self.monitor=nil}
        var result:[String:Any]=["down":down,"dragged":dragged,"up":up,"titleDown":titleDown,
            "firstDownWindowPoints":positions,"firstDraggedWindowPoints":dragPositions,
            "windowWidth":window?.frame.width ?? 0,"windowHeight":window?.frame.height ?? 0,
            "contentTopWindowPoints":window?.contentLayoutRect.maxY ?? 0]
        func numbers(_ rect:CGRect)->[Double] {[rect.minX,rect.minY,rect.width,rect.height]}
        if let first=firstDownServerBounds {result["firstDownServerBounds"]=numbers(first)}
        if let last=lastUpServerBounds {result["lastUpServerBounds"]=numbers(last)}
        if let first=firstDownServerBounds,let last=lastUpServerBounds {
            result["serverDisplacementBetweenMouseEventsPoints"]=hypot(last.minX-first.minX,last.minY-first.minY)
        }
        completedEvidence=result;return result
    }
}
