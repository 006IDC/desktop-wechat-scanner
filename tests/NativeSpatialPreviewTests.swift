import Foundation
import CoreImage
import CoreVideo
import Metal

@main enum NativeSpatialPreviewTests {
    static func check(_ condition:Bool,_ message:String="",line:Int=#line) {
        if !condition {FileHandle.standardError.write(Data("FAIL spatial preview at line \(line): \(message)\n".utf8));exit(1)}
    }
    static let width=192,height=320
    static func carrier(_ x:Int,_ y:Int,salt:Int)->Int {
        let column=x*9/width,row=y*16/height
        var value=UInt32(column+row*9+salt*144)
        value=(value ^ (value>>16)) &* 0x7feb352d
        value=(value ^ (value>>15)) &* 0x846ca68b
        value=value ^ (value>>16)
        return value&1==0 ? 192:255
    }
    static func foreground(_ x:Int,_ y:Int)->(Double,[Double]) {
        if x<24 && y<60 {return (1,[0,0.2,0.95])}
        if x>160 && y>260 {return (1,[1,1,1])}
        if y>280 && x<80 {return (0.6,[0.4,0.4,0.4])}
        return (0,[0,0,0])
    }
    static func rgba(_ mode:Int,salt:Int=17,noise:Int=0)->[UInt8] {
        var result=[UInt8]();result.reserveCapacity(width*height*4)
        for y in 0..<height {for x in 0..<width {
            let (a,c)=foreground(x,y)
            let background:[Double]=mode==0 ? [0,0,0]:(mode==1 ? [1,1,1]:[0,0,Double(mode==3 ? 255:carrier(x,y,salt:salt))/255])
            let delta=noise==0 ? 0:((x*7+y*3)%max(1,noise*2+1)-noise)
            result += (0..<3).map{UInt8(clamping:Int(((c[$0]*a+background[$0]*(1-a))*255).rounded())+delta)}+[255]
        }}
        return result
    }
    static func pixels(_ bytes:[UInt8])->CVPixelBuffer {
        var output:CVPixelBuffer?
        check(CVPixelBufferCreate(nil,width,height,kCVPixelFormatType_32BGRA,nil,&output)==kCVReturnSuccess)
        let p=output!;CVPixelBufferLockBaseAddress(p,[])
        let b=CVPixelBufferGetBaseAddress(p)!.assumingMemoryBound(to:UInt8.self),row=CVPixelBufferGetBytesPerRow(p)
        for y in 0..<height {for x in 0..<width {
            let from=(y*width+x)*4,to=y*row+x*4
            b[to]=bytes[from+2];b[to+1]=bytes[from+1];b[to+2]=bytes[from];b[to+3]=255
        }}
        CVPixelBufferUnlockBaseAddress(p,[]);return p
    }
    static func ci(_ data:[UInt8])->CIImage {
        CIImage(bitmapData:Data(data),bytesPerRow:width*4,size:CGSize(width:width,height:height),format:.RGBA8,colorSpace:nil)
    }
    static func main() throws {
        let black=rgba(0),white=rgba(1),key=rgba(2)
        let samples=[black,black,black,white,white,white,key,key,key].map{pixels($0)}
        let reference=try NativePreviewKeyReference(samples:samples)
        check(reference.matches(pixels(key)))
        check(reference.matches(pixels(rgba(2,noise:10))))
        var animated=key
        for y in height/3..<(height/3+height/12) {for x in 0..<width {
            let offset=(y*width+x)*4;animated[offset]=0;animated[offset+1]=204;animated[offset+2]=26
        }}
        check(reference.matches(pixels(animated)),"A moving native scan line covered the carrier")
        check(!reference.matches(pixels(rgba(3)))) // A blue desktop is not the carrier.
        check(!reference.matches(pixels(rgba(2,salt:31))))
        check(!reference.matches(pixels(black)))
        check(!reference.matches(pixels(white)))
        do {
            _=try NativePreviewKeyReference(samples:[black,black,black,white,white,white,rgba(3),rgba(3),rgba(3)].map{pixels($0)})
            check(false,"Uniform blue cannot establish a spatial carrier")
        }catch NativePreviewKeyReference.Failure.insufficientCarrier {}
        let gate=NativePreviewKeyGate();let clock=ProcessInfo.processInfo.systemUptime
        gate.begin(reference,verifiedAt:clock)
        check(gate.accepts(pixels(key)) && !gate.accepts(pixels(rgba(3))))
        check(!gate.current(at:clock+2));gate.stop();check(!gate.accepts(pixels(key)))

        let renderer=try NativeScannerMatte(black:ci(black),white:ci(white),algorithm:.spatialBlue,
            blueCalibration:[black,black,black,white,white,white,key,key,key].map{ci($0)})
        guard let device=MTLCreateSystemDefaultDevice() else{fatalError("Metal required")}
        func texture(_ w:Int,_ h:Int,_ format:MTLPixelFormat)->MTLTexture {
            let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:format,width:w,height:h,mipmapped:false)
            descriptor.usage=[.shaderRead,.shaderWrite,.renderTarget];descriptor.storageMode = .shared
            return device.makeTexture(descriptor:descriptor)!
        }
        func bytes(_ t:MTLTexture)->[UInt8] {
            var data=[UInt8](repeating:0,count:t.width*t.height*4)
            data.withUnsafeMutableBytes{t.getBytes($0.baseAddress!,bytesPerRow:t.width*4,from:MTLRegionMake2D(0,0,t.width,t.height),mipmapLevel:0)}
            return data
        }
        let target=texture(width,height,.rgba8Unorm)
        let command=try renderer.render(black:ci(key),into:target,allowFused:false);command.waitUntilCompleted()
        check(command.status == .completed)
        // Compare canonical CI bitmap rows; raw Metal textures use a different
        // image origin. Fused/reference textures are compared directly below.
        let recovered=CIImage(cgImage:try renderer.render(black:ci(key)),options:[.colorSpace:NSNull()])
        var output=[UInt8](repeating:0,count:width*height*4)
        output.withUnsafeMutableBytes {CIContext(options:[.workingColorSpace:NSNull(),.outputColorSpace:NSNull()]).render(recovered,
            toBitmap:$0.baseAddress!,rowBytes:width*4,bounds:recovered.extent,format:.RGBA8,colorSpace:nil)}
        var maximum=0
        for y in 0..<height {for x in 0..<width {
            let (alpha,color)=foreground(x,y),i=(y*width+x)*4
            let expected=color.map{Int(($0*alpha*255).rounded())}+[Int((alpha*255).rounded())]
            for c in 0..<4 {maximum=max(maximum,abs(Int(output[i+c])-expected[c]))}
        }}
        check(maximum<=4,"Spatial key changed original native pixels: \(maximum)")
        for (w,h) in [(width,height),(width*2,height*2),(width/2,height/2)] {
            let a=texture(w,h,.bgra8Unorm),b=texture(w,h,.bgra8Unorm)
            let ca=try renderer.render(black:ci(key),into:a,allowFused:false);ca.waitUntilCompleted()
            let cb=try renderer.render(black:ci(key),into:b,allowFused:true);cb.waitUntilCompleted()
            check(ca.status == .completed && cb.status == .completed)
            check(zip(bytes(a),bytes(b)).map{abs(Int($0)-Int($1))}.max()!<=2)
        }
        print("PASS spatial carrier identity, blue-desktop rejection, expiry/stop and original native RGBA/fused rendering")
    }
}
