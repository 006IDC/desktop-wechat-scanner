import CoreVideo
@main enum NativeCalibrationReadinessTests {
    static func image(width:Int=96,height:Int=128,bgra:(Int,Int)->[UInt8]) -> CVPixelBuffer {
        var image:CVPixelBuffer?
        precondition(CVPixelBufferCreate(nil,width,height,kCVPixelFormatType_32BGRA,nil,&image)==kCVReturnSuccess)
        let p=image!;CVPixelBufferLockBaseAddress(p,[])
        let row=CVPixelBufferGetBytesPerRow(p),bytes=CVPixelBufferGetBaseAddress(p)!.assumingMemoryBound(to:UInt8.self)
        for y in 0..<height {for x in 0..<width {let c=bgra(x,y);for i in 0..<4 {bytes[y*row+x*4+i]=c[i]}}}
        CVPixelBufferUnlockBaseAddress(p,[]);return p
    }
    static func main() {
        precondition(NativeCalibrationReadiness.blackVisible(image{_,_ in [8,8,8,255]}))
        precondition(!NativeCalibrationReadiness.blackVisible(image{_,_ in [255,255,255,255]}))
        precondition(!NativeCalibrationReadiness.blackVisible(image{_,_ in [255,0,0,255]}))
        precondition(!NativeCalibrationReadiness.blackVisible(image{_,_ in [80,80,80,255]}))
        // Native white controls outside the camera center and a thin genuine
        // green scanline must not force an unconditional 350ms wait.
        precondition(NativeCalibrationReadiness.blackVisible(image{_,y in
            y<20 || y>110 ? [255,255,255,255] : (y==64 ? [0,200,0,255]:[0,0,0,255])
        }))
        precondition(!NativeCalibrationReadiness.blackVisible(image(width:16,height:16){_,_ in [0,0,0,255]}))
        print("PASS native calibration readiness: black/noise/native controls accepted; white/blue/gray/tiny rejected")
    }
}
