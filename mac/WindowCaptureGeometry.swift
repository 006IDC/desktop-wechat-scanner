import AppKit
import CoreGraphics

/// Public CoreGraphics metadata corrects AppKit's potentially cached origin
/// during native title-bar dragging. This never captures window pixels.
enum WindowCaptureGeometry {
    private struct QueryKey: Equatable {
        let object: ObjectIdentifier
        let id: CGWindowID
        let pid: pid_t
        let display: UInt32
        let primaryTop: CGFloat
        let scale: CGFloat
        let originX: CGFloat
        let originY: CGFloat
        let width: CGFloat
        let height: CGFloat
    }

    private struct Query {
        let key: QueryKey
        let id: CGWindowID
        let appKitFrame: CGRect
    }

    /// Keep the AppKit frame observed when the WindowServer query was requested.
    /// A late result from an earlier drag position must never shift a new ROI.
    struct BoundsSnapshot {
        let serverBounds: CGRect
        let queriedAppKitFrame: CGRect

        func bounds(for currentAppKitFrame: CGRect) -> CGRect? {
            queriedAppKitFrame == currentAppKitFrame ? serverBounds : nil
        }
    }

    private struct CachedBounds {
        let key: QueryKey
        let snapshot: BoundsSnapshot
        let time: TimeInterval
    }

    private static let queue = DispatchQueue(label: "006idc.window-geometry", qos: .userInitiated)
    private static let lock = NSLock()
    private static var cached: [CGWindowID: CachedBounds] = [:]
    private static var pending: [CGWindowID: Query] = [:]
    private static var workerScheduled = false
    private static var lastSubmission: [CGWindowID: TimeInterval] = [:]

    @MainActor static func correctedCaptureRect(for window:NSWindow,cachedRect:CGRect) -> CGRect {
        let number=window.windowNumber
        guard number>0,UInt64(number)<=UInt64(UInt32.max),
              let primaryTop=NSScreen.screens.first?.frame.maxY else {return cachedRect}
        let frame = window.frame
        let key = QueryKey(object: ObjectIdentifier(window), id: CGWindowID(number),
                           pid: ProcessInfo.processInfo.processIdentifier,
                           display: (window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0,
                           primaryTop: primaryTop,
                           scale: window.backingScaleFactor,
                           originX: frame.minX, originY: frame.minY,
                           width: frame.width, height: frame.height)
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        if cached[key.id]?.key != key { cached.removeValue(forKey: key.id) }
        let bounds = cached[key.id].flatMap {
            now - $0.time <= 0.15 ? $0.snapshot.bounds(for: frame) : nil
        }
        if now - (lastSubmission[key.id] ?? 0) >= 1.0 / 60.0 {
            lastSubmission[key.id] = now
            pending[key.id] = Query(key: key, id: key.id, appKitFrame: frame)
            if !workerScheduled {
                workerScheduled = true
                queue.async { drainQueries() }
            }
        }
        // The app normally owns only a few windows. Remove closed-window state
        // so identifiers and cached results cannot accumulate indefinitely.
        if lastSubmission.count > 16 {
            let recent = lastSubmission.filter { now - $0.value < 1 }
            lastSubmission = recent
            cached = cached.filter { recent[$0.key] != nil }
            pending = pending.filter { recent[$0.key] != nil }
        }
        lock.unlock()
        return correctedRect(cachedRect:cachedRect,appKitFrame:frame,
                             windowServerBounds:bounds,primaryScreenTop:primaryTop)
    }

    private static func drainQueries() {
        while true {
            lock.lock()
            guard let (id, query) = pending.first else {
                workerScheduled = false
                lock.unlock()
                return
            }
            pending.removeValue(forKey: id)
            lock.unlock()
            let descriptions = ownWindowDescriptions(id: query.id)
            let bounds = descriptions.flatMap { serverBounds(from: $0, windowID: query.id, ownerPID: query.key.pid) }
            lock.lock()
            if let bounds {
                cached[id] = CachedBounds(key: query.key,
                                          snapshot: BoundsSnapshot(serverBounds: bounds,
                                                                   queriedAppKitFrame: query.appKitFrame),
                                          time: ProcessInfo.processInfo.systemUptime)
            }
            lock.unlock()
        }
    }

    @MainActor static func ownWindowDescriptions(for window:NSWindow) -> [[String:Any]]? {
        let number=window.windowNumber
        guard number>0,UInt64(number)<=UInt64(UInt32.max) else { return nil }
        return ownWindowDescriptions(id: CGWindowID(number))
    }

    private static func ownWindowDescriptions(id: CGWindowID) -> [[String:Any]]? {
        guard let ids=windowIDArray(id),
              let descriptions=CGWindowListCreateDescriptionFromArray(ids) as? [[String:Any]] else {return nil}
        let expectedID=Double(id),pid=Double(ProcessInfo.processInfo.processIdentifier)
        // An absent/closed window can produce an empty array. Never accept an
        // unexpected window even if the system returned additional metadata.
        guard descriptions.count<=1,descriptions.allSatisfy({
            ($0[kCGWindowNumber as String] as? NSNumber)?.doubleValue==expectedID &&
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
