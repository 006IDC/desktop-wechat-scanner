import CoreVideo

/// A readiness probe, not a matte or permission/owner decision. Requires a
/// fresh frame after the authenticated black input ACK before temporal samples.
enum NativeCalibrationReadiness {
    static func blackVisible(_ pixels:CVPixelBuffer)->Bool {
        guard CVPixelBufferGetPixelFormatType(pixels)==kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(pixels,.readOnly)==kCVReturnSuccess else{return false}
        defer {CVPixelBufferUnlockBaseAddress(pixels,.readOnly)}
        guard let bytes=CVPixelBufferGetBaseAddress(pixels)?.assumingMemoryBound(to:UInt8.self) else{return false}
        let w=CVPixelBufferGetWidth(pixels),h=CVPixelBufferGetHeight(pixels),row=CVPixelBufferGetBytesPerRow(pixels)
        guard w>=32,h>=32 else{return false}
        var dark=0,count=0
        for y in stride(from:h/3,to:h*2/3,by:max(1,h/32)) {
            for x in stride(from:w/3,to:w*2/3,by:max(1,w/24)) {
                let p=y*row+x*4
                if max(bytes[p],max(bytes[p+1],bytes[p+2]))<35 {dark+=1}
                count+=1
            }
        }
        return count>0 && dark*100>=count*70
    }
}
