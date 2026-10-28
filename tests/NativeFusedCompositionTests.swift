import Foundation
import CoreImage
import Metal

/// Synthetic GPU textures only. Never creates an app, window, drawable or camera.
@main enum NativeFusedCompositionTests {
    static func images(_ w:Int,_ h:Int)->(CIImage,CIImage) {
        var black=[UInt8](),blue=[UInt8]()
        black.reserveCapacity(w*h*4);blue.reserveCapacity(w*h*4)
        for y in 0..<h {for x in 0..<w {
            let phase=(x/2+y/3)%4,a=[0.0,0.25,0.6,1.0][phase]
            let rgb=[Double((x*37+y*13)%256)/255,Double((x*17+y*31)%256)/255,
                     Double((x*11+y*47)%256)/255]
            let native=rgb.map{$0*a}
            black += native.map{UInt8(($0*255).rounded())}+[255]
            // A moving green foreground absent from the calibration observations.
            blue += phase==0 && y%3==1 ? [0,179,76,255] :
                [native[0],native[1],native[2]+1-a].map{UInt8(($0*255).rounded())}+[255]
        }}
        let size=CGSize(width:w,height:h)
        return (CIImage(bitmapData:Data(black),bytesPerRow:w*4,size:size,format:.RGBA8,colorSpace:nil),
                CIImage(bitmapData:Data(blue),bytesPerRow:w*4,size:size,format:.RGBA8,colorSpace:nil))
    }
    static func texture(_ device:MTLDevice,_ w:Int,_ h:Int,
                        format:MTLPixelFormat = .bgra8Unorm,
                        usage:MTLTextureUsage = [.shaderRead,.shaderWrite,.renderTarget])->MTLTexture {
        let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:format,width:w,height:h,mipmapped:false)
        d.usage=usage;d.storageMode = .shared
        return device.makeTexture(descriptor:d)!
    }
    static func bytes(_ t:MTLTexture)->[UInt8] {
        var a=[UInt8](repeating:0,count:t.width*t.height*4)
        a.withUnsafeMutableBytes {
            t.getBytes($0.baseAddress!,bytesPerRow:t.width*4,
                       from:MTLRegionMake2D(0,0,t.width,t.height),mipmapLevel:0)
        }
        return a
    }
    static func compare(_ renderer:NativeScannerMatte,_ live:CIImage,
                        _ device:MTLDevice,_ w:Int,_ h:Int,
                        format:MTLPixelFormat = .bgra8Unorm) throws {
        let reference=texture(device,w,h,format:format),candidate=texture(device,w,h,format:format)
        for (target,allowed) in [(reference,false),(candidate,true)] {
            let command=try renderer.render(black:live,into:target,allowFused:allowed)
            command.waitUntilCompleted();precondition(command.status == .completed)
        }
        let expected=bytes(reference),actual=bytes(candidate)
        let difference=zip(expected,actual).map{abs(Int($0)-Int($1))}.max()!
        precondition(difference<=2,"Fused composition changed pixels at \(w)×\(h): \(difference)")
        for i in stride(from:0,to:actual.count,by:4) {
            precondition(max(actual[i],max(actual[i+1],actual[i+2]))<=actual[i+3],
                         "Composition produced non-premultiplied foreground")
        }
    }
    static func main() throws {
        guard let device=MTLCreateSystemDefaultDevice() else{fatalError("Metal device required")}
        try NativeScannerMatte.prewarm()
        for (w,h) in [(1,1),(2,3),(8,11),(17,19),(64,96)] {
            let (black,live)=images(w,h)
            let renderer=try NativeScannerMatte(black:black,white:black,
                algorithm:.blueWithNativeColorBias,blueCalibration:Array(repeating:black,count:9))
            for (dw,dh) in [(w,h),(w*2,h*2),(max(1,w/2),max(1,h/2)),
                            (max(1,w*2/5),max(1,h*2/5)),(w+1,h+4),(1,1),(1,h+2),(w+3,1)] {
                let target=texture(device,dw,dh)
                let eligible=dw*2>=w && dh*2>=h
                precondition(renderer.compositionPath(for:target) == (eligible ? .fusedBlue:.reference))
                try compare(renderer,live,device,dw,dh)
            }
            try compare(renderer,live,device,w+2,h+1,format:.rgba8Unorm)
            precondition(renderer.compositionPath(for:texture(device,w,h,usage:[.renderTarget])) == .reference)
        }
        let (black,live)=images(8,11)
        let referenceOnly=try NativeScannerMatte(black:black,white:black)
        precondition(referenceOnly.compositionPath(for:texture(device,8,11)) == .reference)
        try compare(referenceOnly,live,device,13,17)
        do {
            _=try referenceOnly.render(black:live.cropped(to:CGRect(x:0,y:0,width:2,height:3)),
                                      into:texture(device,8,11))
            fatalError("Mismatched source extent accepted")
        } catch is NativeScannerMatte.Unavailable {}
        print("PASS headless composition: colors/alpha/orientation, magnification, minification, thin targets and reference fallbacks")
        if CommandLine.arguments.contains("--benchmark") {try benchmark(device)}
    }
    static func benchmark(_ device:MTLDevice) throws {
        let (black,live)=images(720,1565)
        let renderer=try NativeScannerMatte(black:black,white:black,
            algorithm:.blueWithNativeColorBias,blueCalibration:Array(repeating:black,count:9))
        let target=texture(device,646,1404)
        precondition(renderer.compositionPath(for:target) == .fusedBlue)
        try compare(renderer,live,device,646,1404)
        var cpu=[[Double](),[Double]()],gpu=[[Double](),[Double]()]
        for i in 0..<45 {
            for index in (i%2==0 ? [0,1]:[1,0]) {
                let began=ProcessInfo.processInfo.systemUptime
                let command=try renderer.render(black:live,into:target,allowFused:index==1)
                let encoded=(ProcessInfo.processInfo.systemUptime-began)*1000
                command.waitUntilCompleted();precondition(command.status == .completed)
                if i>=5 {cpu[index].append(encoded);gpu[index].append((command.gpuEndTime-command.gpuStartTime)*1000)}
            }
        }
        for i in 0..<2 {
            cpu[i].sort();gpu[i].sort()
            print(i==0 ? "reference":"fused", "CPU p95 ms",cpu[i][37],
                  "GPU p95 ms",gpu[i][37],"GPU median ms",gpu[i][20])
        }
        print("Synthetic stages only; no window/phone or end-to-end latency measurement")
    }
}
