import Foundation
import CoreGraphics

/// The selected source decides delivery; the Mac never interprets code payloads.
enum DesktopCameraInput {
    enum Delivery:Equatable {case waitForCode,continuous,thenReturn}
    static func delivery(generic:Bool,codePresence:() throws -> Bool) rethrows -> Delivery {
        if generic {return .continuous}
        return try codePresence() ? .thenReturn:.waitForCode
    }
    /// Keep the original app visible beside the camera aperture whenever space permits.
    static func framePlacement(size:CGSize,owner:CGRect,screen:CGRect)->CGRect {
        let gap:CGFloat=20
        let origins=[CGPoint(x:owner.maxX+gap,y:owner.maxY-size.height),
                     CGPoint(x:owner.minX-gap-size.width,y:owner.maxY-size.height),
                     CGPoint(x:owner.minX,y:owner.maxY+gap),
                     CGPoint(x:owner.minX,y:owner.minY-gap-size.height),
                     CGPoint(x:screen.minX,y:screen.minY),CGPoint(x:screen.maxX-size.width,y:screen.minY)]
        let candidates=origins.map {point in
            CGRect(x:max(screen.minX,min(point.x,screen.maxX-size.width)),
                   y:max(screen.minY,min(point.y,screen.maxY-size.height)),width:size.width,height:size.height)
        }
        func overlap(_ rect:CGRect)->CGFloat {let i=rect.intersection(owner);return i.isNull ? 0:i.width*i.height}
        return candidates.enumerated().min {a,b in
            let x=overlap(a.element),y=overlap(b.element)
            return x==y ? a.offset<b.offset:x<y
        }!.element
    }
}

struct DesktopCameraLaunchFailure:LocalizedError {
    let original:Error
    var errorDescription:String? {original.localizedDescription+"\n桌面相机绑定清理未确认，连接将安全断开。"}
}
enum DesktopCameraLaunch {
    /// Includes uncertain bind replies: compensation runs even when bind itself throws.
    static func perform(bind:() throws -> Bool,launch:() throws -> Void,clear:() throws -> Void) throws -> Bool {
        do {let ready=try bind();try launch();return ready}
        catch {
            let original=error
            do {try clear()} catch {throw DesktopCameraLaunchFailure(original:original)}
            throw original
        }
    }
    static func accepted(_ response:Data,clearing:Bool) throws -> Bool {
        if clearing,response==Data([0]) {return false}
        if !clearing,response==Data([1]) {return true}
        if !clearing,response==Data([2]) {return false} // Explicitly not a camera-declaring app.
        throw ScanError("手机未确认相机窗口绑定。")
    }
}
