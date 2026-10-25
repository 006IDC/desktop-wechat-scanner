import AppKit
import CoreGraphics

/// Public CoreGraphics metadata corrects AppKit's potentially cached origin
/// during native title-bar dragging. This never captures window pixels.
enum WindowCaptureGeometry {
    @MainActor static func correctedCaptureRect(for window:NSWindow,cachedRect:CGRect) -> CGRect {
        let number=window.windowNumber
        guard number>0,UInt64(number)<=UInt64(UInt32.max),
              let primaryTop=NSScreen.screens.first?.frame.maxY else {return cachedRect}
        let id=CGWindowID(number)
        guard let descriptions=ownWindowDescriptions(for:window),
              let bounds=serverBounds(from:descriptions,windowID:id,ownerPID:ProcessInfo.processInfo.processIdentifier) else {
            return cachedRect
        }
        return correctedRect(cachedRect:cachedRect,appKitFrame:window.frame,
                             windowServerBounds:bounds,primaryScreenTop:primaryTop)
    }

    @MainActor static func ownWindowDescriptions(for window:NSWindow) -> [[String:Any]]? {
        let number=window.windowNumber
        guard number>0,UInt64(number)<=UInt64(UInt32.max),
              let ids=windowIDArray(CGWindowID(number)),
              let descriptions=CGWindowListCreateDescriptionFromArray(ids) as? [[String:Any]] else {return nil}
        let id=Double(number),pid=Double(ProcessInfo.processInfo.processIdentifier)
        // An absent/closed window can produce an empty array. Never accept an
        // unexpected window even if the system returned additional metadata.
        guard descriptions.count<=1,descriptions.allSatisfy({
            ($0[kCGWindowNumber as String] as? NSNumber)?.doubleValue==id &&
            ($0[kCGWindowOwnerPID as String] as? NSNumber)?.doubleValue==pid
        }) else {return nil}
        return descriptions
    }

    static func windowIDArray(_ id:CGWindowID) -> CFArray? {
        guard id != kCGNullWindowID else{return nil}
        // Quartz requires raw pointer-sized CGWindowID values, not CFNumber /
        // NSNumber objects. Null callbacks prevent retaining/dereferencing those
        // integer values. Do not bridge this input array through NSArray.
        var rawID:UnsafeRawPointer?=UnsafeRawPointer(bitPattern:UInt(id))
        return CFArrayCreate(kCFAllocatorDefault,&rawID,1,nil)
    }

    static func serverBounds(from descriptions:[[String:Any]],windowID:CGWindowID,ownerPID:pid_t) -> CGRect? {
        guard windowID != kCGNullWindowID,ownerPID>0,
              let own=descriptions.first(where:{
                  ($0[kCGWindowNumber as String] as? NSNumber)?.doubleValue==Double(windowID) &&
                  ($0[kCGWindowOwnerPID as String] as? NSNumber)?.doubleValue==Double(ownerPID)
              }),let dictionary=own[kCGWindowBounds as String] as? [String:Any],
              let bounds=CGRect(dictionaryRepresentation:dictionary as CFDictionary),valid(bounds) else {return nil}
        return bounds
    }

    /// WindowServer bounds use global top-left coordinates in points. Flip using
    /// the primary screen's top, not the screen currently hosting the window.
    /// Both coordinate systems are points: never apply Retina backingScaleFactor.
    static func correctedRect(cachedRect:CGRect,appKitFrame:CGRect,
                              windowServerBounds:CGRect?,primaryScreenTop:CGFloat?) -> CGRect {
        guard valid(cachedRect),valid(appKitFrame),let bounds=windowServerBounds,valid(bounds),
              let top=primaryScreenTop,top.isFinite else {return cachedRect}
        // Translation is reliable for movement only. A size mismatch can mean
        // native resize/layout is in flight; keep the cached layout until AppKit
        // catches up. Allow a point of WindowServer rounding, never scale the ROI.
        guard abs(bounds.width-appKitFrame.width)<=1,abs(bounds.height-appKitFrame.height)<=1 else {
            return cachedRect
        }
        let serverFrame=CGRect(x:bounds.minX,y:top-bounds.maxY,width:bounds.width,height:bounds.height)
        guard valid(serverFrame) else {return cachedRect}
        let result=cachedRect.offsetBy(dx:serverFrame.minX-appKitFrame.minX,
                                       dy:serverFrame.minY-appKitFrame.minY)
        return valid(result) ? result:cachedRect
    }

    private static func valid(_ rect:CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && rect.minX.isFinite && rect.minY.isFinite &&
        rect.width.isFinite && rect.height.isFinite && rect.width>0 && rect.height>0 &&
        rect.maxX.isFinite && rect.maxY.isFinite
    }
}
