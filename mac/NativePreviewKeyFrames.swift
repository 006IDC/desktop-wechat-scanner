import Foundation
import CoreVideo

/// A per-lease observation of a spatial camera carrier, learned only after
/// distinct black/white phases. Pixels stay in memory; no View tree is read.
final class NativePreviewKeyReference:@unchecked Sendable {
    struct Point {let x:Int,y:Int,r:Int,g:Int,b:Int}
    private let width:Int,height:Int
    private let points:[Point]
    enum Failure:Error {case dimensions,buffer,insufficientCarrier}
    private static func median(_ a:Int,_ b:Int,_ c:Int)->Int {max(min(a,b),min(max(a,b),c))}
    private static func locked<T>(_ images:[CVPixelBuffer],_ body:([UnsafePointer<UInt8>],[Int])throws->T) throws ->T {
        var acquired=[CVPixelBuffer](),bases=[UnsafePointer<UInt8>](),rows=[Int]()
        defer {for image in acquired {CVPixelBufferUnlockBaseAddress(image,.readOnly)}}
        for image in images {
            guard CVPixelBufferGetPixelFormatType(image)==kCVPixelFormatType_32BGRA,
                  CVPixelBufferLockBaseAddress(image,.readOnly)==kCVReturnSuccess else{throw Failure.buffer}
            acquired.append(image)
            guard let base=CVPixelBufferGetBaseAddress(image)?.assumingMemoryBound(to:UInt8.self) else{throw Failure.buffer}
            bases.append(UnsafePointer(base));rows.append(CVPixelBufferGetBytesPerRow(image))
        }
        return try body(bases,rows)
    }
    init(samples:[CVPixelBuffer]) throws {
        guard samples.count==9,let first=samples.first else{throw Failure.dimensions}
        let w=CVPixelBufferGetWidth(first),h=CVPixelBufferGetHeight(first)
        guard w>=128,h>=128,w<=4096,h<=4096,
              samples.allSatisfy({CVPixelBufferGetWidth($0)==w && CVPixelBufferGetHeight($0)==h}) else{throw Failure.dimensions}
        width=w;height=h
        points=try Self.locked(samples) {bytes,rows in
            var points=[Point](),low=0,high=0
            func channel(_ start:Int,_ x:Int,_ y:Int,_ channel:Int)->Int {
                Self.median(Int(bytes[start][y*rows[start]+x*4+channel]),
                            Int(bytes[start+1][y*rows[start+1]+x*4+channel]),
                            Int(bytes[start+2][y*rows[start+2]+x*4+channel]))
            }
            for row in 0..<32 {for column in 0..<24 {
                let x=(column*2+1)*w/48,y=(row*2+1)*h/64
                let br=channel(0,x,y,2),bg=channel(0,x,y,1),bb=channel(0,x,y,0)
                let t=Self.median(channel(3,x,y,2)-br,channel(3,x,y,1)-bg,channel(3,x,y,0)-bb)
                let kr=channel(6,x,y,2),kg=channel(6,x,y,1),kb=channel(6,x,y,0)
                guard t>=218,abs(kr-br)<24,abs(kg-bg)<24 else{continue}
                let key=Double(kb-kr-bb+br)/Double(t)
                if (0.65...0.84).contains(key) {low+=1}
                else if (0.93...1.08).contains(key) {high+=1}
                else {continue}
                points.append(Point(x:x,y:y,r:kr,g:kg,b:kb))
            }}
            guard points.count>=128,low>=32,high>=32 else{throw Failure.insufficientCarrier}
            return points
        }
    }
    func matches(_ image:CVPixelBuffer)->Bool {matchFraction(image)>=0.9}
    func matchFraction(_ image:CVPixelBuffer)->Double {
        guard CVPixelBufferGetWidth(image)==width,CVPixelBufferGetHeight(image)==height else{return 0}
        return (try? Self.locked([image]) {bytes,rows in
            var matched=0
            for p in points {
                let i=p.y*rows[0]+p.x*4
                if abs(Int(bytes[0][i])-p.b)<=24 && abs(Int(bytes[0][i+1])-p.g)<=24 && abs(Int(bytes[0][i+2])-p.r)<=24 {matched+=1}
            }
            // Native scan lines can temporarily cover two of the 32 rows.
            // Require the random spatial field across the remaining image;
            // uniform blue still disagrees with roughly half the points.
            return Double(matched)/Double(points.count)
        }) ?? 0
    }
}

/// Decoder callbacks evaluate immutable references outside the lock. Stop or
/// replacement fences an evaluation already in progress before publication.
final class NativePreviewKeyGate:@unchecked Sendable {
    private let lock=NSLock()
    private var reference:NativePreviewKeyReference?,stopped=false,lastVerifiedAt:Double?
    private var accepted=0,rejected=0
    var filtering:Bool {lock.withLock{reference != nil}}
    func begin(_ value:NativePreviewKeyReference,verifiedAt:Double) {
        lock.withLock{guard !stopped else{return};reference=value;lastVerifiedAt=verifiedAt;accepted=0;rejected=0}
    }
    func accepts(_ pixels:CVPixelBuffer)->Bool {
        let state=lock.withLock{(reference,stopped)}
        guard !state.1 else{return false}
        guard let current=state.0 else{return true}
        guard current.matches(pixels) else{lock.withLock{if !stopped,reference === current {rejected+=1}};return false}
        return lock.withLock{
            guard !stopped,reference === current else{return false}
            lastVerifiedAt=ProcessInfo.processInfo.systemUptime;accepted+=1;return true
        }
    }
    func current(at now:Double)->Bool {lock.withLock{
        guard !stopped else{return false}
        guard reference != nil else{return true}
        return lastVerifiedAt.map{now >= $0 && now-$0<=0.3} ?? false
    }}
    func statistics()->[String:Int] {lock.withLock{["acceptedCarrierFrames":accepted,"rejectedOtherFrames":rejected]}}
    func stop(){lock.withLock{stopped=true;reference=nil;lastVerifiedAt=nil}}
}
