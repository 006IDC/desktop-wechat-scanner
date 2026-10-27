import CoreImage
import Metal
import QuartzCore

/// Research renderer. Samples genuine native scanner observations; never draws
/// or replaces Android controls. Not enabled by the default product path.
final class NativeScannerMatte {
    enum Algorithm { case blackWhite, blueWithNativeColorBias }
    struct Unavailable: Error { let stage: String; init(_ stage: String = "gpu_resource") { self.stage = stage } }
    private let context: CIContext
    private let queue: MTLCommandQueue
    private let composite: MTLComputePipelineState
    private let transmission: MTLTexture
    private let input: MTLTexture
    private let output: MTLTexture
    private let extent: CGRect
    var metalDevice: MTLDevice { queue.device }
    private static let source = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void calibrate(texture2d<float, access::read> b [[texture(0)]],
                              texture2d<float, access::read> w [[texture(1)]],
                              texture2d<float, access::write> out [[texture(2)]],
                              uint2 p [[thread_position_in_grid]]) {
            if (p.x >= out.get_width() || p.y >= out.get_height()) return;
            float3 d = w.read(p).rgb - b.read(p).rgb;
            float t = clamp(max(min(d.r,d.g),min(max(d.r,d.g),d.b)),0.0f,1.0f);
            out.write(float4(t,t,t,1),p);
        }
        kernel void blueCalibrate(texture2d<float, access::read> b [[texture(0)]],
                                  texture2d<float, access::read> w [[texture(1)]],
                                  texture2d<float, access::write> out [[texture(2)]],
                                  uint2 p [[thread_position_in_grid]]) {
            if (p.x >= out.get_width() || p.y >= out.get_height()) return;
            float3 c = b.read(p).rgb;
            out.write(float4(c.b-c.r,0,0,1),p);
        }
        kernel void blueMedianCalibrate(array<texture2d<float, access::read>,9> b [[texture(0)]],
                                  texture2d<float, access::write> out [[texture(9)]],
                                  uint2 p [[thread_position_in_grid]]) {
            if (p.x >= out.get_width() || p.y >= out.get_height()) return;
            float values[9];
            for (uint i=0;i<9;i++) {
                float3 c=b[i].read(p).rgb; values[i]=c.b-c.r;
                for (uint j=i;j>0 && values[j]<values[j-1];j--) {
                    float v=values[j];values[j]=values[j-1];values[j-1]=v;
                }
            }
            out.write(float4(values[4],0,0,1),p);
        }
        kernel void blueComposite(texture2d<float, access::read> b [[texture(0)]],
                                  texture2d<float, access::read> bias [[texture(1)]],
                                  texture2d<float, access::write> out [[texture(2)]],
                                  uint2 p [[thread_position_in_grid]]) {
            if (p.x >= out.get_width() || p.y >= out.get_height()) return;
            float3 c = b.read(p).rgb;
            float t = clamp(c.b-c.r-bias.read(p).r,0.0f,1.0f);
            float a = max(1.0f-t,max(c.r,c.g));
            out.write(float4(min(float3(c.r,c.g,max(0.0f,c.b-(1.0f-a))),float3(a)),a),p);
        }
        kernel void composite(texture2d<float, access::read> b [[texture(0)]],
                              texture2d<float, access::read> t [[texture(1)]],
                              texture2d<float, access::write> out [[texture(2)]],
                              uint2 p [[thread_position_in_grid]]) {
            if (p.x >= out.get_width() || p.y >= out.get_height()) return;
            float3 rgb = b.read(p).rgb;
            float a = max(1.0f-t.read(p).r,max(rgb.r,max(rgb.g,rgb.b)));
            out.write(float4(min(rgb,float3(a)),a),p);
        }
        """
    /// Device, immutable pipelines and CIContext can be shared. Pixel textures
    /// and command queues remain per renderer; calibration never reuses a phone image.
    private struct Resources {
        let device:MTLDevice,context:CIContext
        let blackWhite:MTLComputePipelineState,blue:MTLComputePipelineState,median:MTLComputePipelineState
        let composite:MTLComputePipelineState,blueComposite:MTLComputePipelineState
        init() throws {
            guard let device=MTLCreateSystemDefaultDevice() else{throw Unavailable()}
            self.device=device
            let library=try device.makeLibrary(source:NativeScannerMatte.source,options:nil)
            func pipeline(_ name:String) throws -> MTLComputePipelineState {
                guard let function=library.makeFunction(name:name) else{throw Unavailable()}
                return try device.makeComputePipelineState(function:function)
            }
            blackWhite=try pipeline("calibrate");blue=try pipeline("blueCalibrate")
            median=try pipeline("blueMedianCalibrate");composite=try pipeline("composite")
            blueComposite=try pipeline("blueComposite")
            context=CIContext(mtlDevice:device,options:[.workingColorSpace:NSNull(),
                .outputColorSpace:NSNull(),.cacheIntermediates:false])
            // Compile CI's solid-frame path without any screen/phone input.
            let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:2,height:2,mipmapped:false)
            descriptor.usage=[.shaderRead,.shaderWrite,.renderTarget]
            guard let texture=device.makeTexture(descriptor:descriptor),let queue=device.makeCommandQueue(),
                  let command=queue.makeCommandBuffer() else{throw Unavailable()}
            context.render(CIImage(color:.black).cropped(to:CGRect(x:0,y:0,width:2,height:2)),
                to:texture,commandBuffer:command,bounds:CGRect(x:0,y:0,width:2,height:2),colorSpace:CGColorSpaceCreateDeviceRGB())
            command.commit();command.waitUntilCompleted()
            guard command.status == .completed else{throw Unavailable()}
        }
    }
    private static let resources:Result<Resources,Error>=Result {try Resources()}
    /// Call on a background worker before a scanner opens. No camera/capture access.
    static func prewarm() throws {_=try resources.get()}
    init(black: CIImage, white: CIImage, algorithm: Algorithm = .blackWhite, blueCalibration: [CIImage] = []) throws {
        guard black.extent == white.extent, black.extent.origin == .zero,
              !black.extent.isEmpty, black.extent.width <= 4096, black.extent.height <= 4096 else { throw Unavailable("dimensions") }
        guard blueCalibration.isEmpty || (algorithm == .blueWithNativeColorBias && blueCalibration.count == 9 &&
              blueCalibration.allSatisfy({ $0.extent == black.extent })) else { throw Unavailable("calibration_count") }
        let resources=try Self.resources.get()
        let device=resources.device
        guard let queue=device.makeCommandQueue() else{throw Unavailable()}
        extent = black.extent
        self.queue = queue;context=resources.context
        let calibrate=algorithm == .blackWhite ? resources.blackWhite :
            (blueCalibration.isEmpty ? resources.blue : resources.median)
        composite=algorithm == .blackWhite ? resources.composite : resources.blueComposite
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
            width: Int(extent.width), height: Int(extent.height), mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        let calibrationDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
            width: Int(extent.width), height: Int(extent.height), mipmapped: false)
        calibrationDescriptor.usage = [.shaderRead, .shaderWrite]
        guard let input = device.makeTexture(descriptor: descriptor),
              let transmission = device.makeTexture(descriptor: calibrationDescriptor),
              let output = device.makeTexture(descriptor: descriptor),
              let command = queue.makeCommandBuffer() else { throw Unavailable() }
        self.input = input; self.transmission = transmission; self.output = output
        var retained = [MTLTexture]()
        if blueCalibration.isEmpty {
            guard let whiteInput=device.makeTexture(descriptor:descriptor) else{throw Unavailable()}
            retained.append(whiteInput)
            context.render(black,to:input,commandBuffer:command,bounds:extent,colorSpace:CGColorSpaceCreateDeviceRGB())
            context.render(white,to:whiteInput,commandBuffer:command,bounds:extent,colorSpace:CGColorSpaceCreateDeviceRGB())
            try Self.encode(command, pipeline: calibrate, a: input, b: whiteInput, output: transmission)
        } else {
            for image in blueCalibration {
                guard let texture = device.makeTexture(descriptor: descriptor) else { throw Unavailable() }
                retained.append(texture)
                context.render(image,to: texture,commandBuffer: command,bounds: extent,colorSpace: CGColorSpaceCreateDeviceRGB())
            }
            guard let encoder = command.makeComputeCommandEncoder() else { throw Unavailable() }
            encoder.setComputePipelineState(calibrate)
            for (index,texture) in retained.enumerated() { encoder.setTexture(texture,index: index) }
            encoder.setTexture(transmission,index: 9)
            encoder.dispatchThreads(MTLSize(width:Int(extent.width),height:Int(extent.height),depth:1),
                threadsPerThreadgroup:MTLSize(width:calibrate.threadExecutionWidth,height:4,depth:1))
            encoder.endEncoding()
        }
        command.commit(); command.waitUntilCompleted()
        guard command.status == .completed else { throw Unavailable() }
    }
    private static func encode(_ command: MTLCommandBuffer, pipeline: MTLComputePipelineState,
                               a: MTLTexture, b: MTLTexture, output: MTLTexture) throws {
        guard let encoder = command.makeComputeCommandEncoder() else { throw Unavailable() }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(a, index: 0); encoder.setTexture(b, index: 1); encoder.setTexture(output, index: 2)
        let width = pipeline.threadExecutionWidth
        encoder.dispatchThreads(MTLSize(width: output.width, height: output.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: max(1,min(8,pipeline.maxTotalThreadsPerThreadgroup / width)), depth: 1))
        encoder.endEncoding()
    }
    // Call serially on a worker. Returned CGImages own immutable rendered pixels;
    // the internal textures may be reused on the next observation.
    func render(black: CIImage) throws -> CGImage {
        guard black.extent == extent, let command = queue.makeCommandBuffer() else { throw Unavailable() }
        context.render(black, to: input, commandBuffer: command, bounds: extent, colorSpace: CGColorSpaceCreateDeviceRGB())
        try Self.encode(command, pipeline: composite, a: input, b: transmission, output: output)
        command.commit(); command.waitUntilCompleted()
        guard command.status == .completed,
              let image = CIImage(mtlTexture: output, options: [.colorSpace: NSNull()]),
              let result = context.createCGImage(image, from: extent, format: .RGBA8,
                                                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { throw Unavailable() }
        return result
    }
    /// GPU-only presentation experiment: no CGImage/readback/re-upload per frame.
    /// Call serially on the render worker, including calibration/readback probes.
    func present(black: CIImage, layer: CAMetalLayer, stats: NativeMattePresentationStats) throws -> Bool {
        guard black.extent == extent else { throw Unavailable("dimensions") }
        let drawableBegan=ProcessInfo.processInfo.systemUptime
        let nextDrawable=layer.nextDrawable()
        stats.drawableWait(milliseconds:(ProcessInfo.processInfo.systemUptime-drawableBegan)*1000)
        guard let drawable=nextDrawable else { return false }
        return try present(black:black,drawable:drawable,stats:stats)
    }
    /// CAMetalDisplayLink already supplies its drawable; never acquire another.
    func present(black:CIImage,drawable:CAMetalDrawable,stats:NativeMattePresentationStats) throws -> Bool {
        guard black.extent==extent else{throw Unavailable("dimensions")}
        guard let command=queue.makeCommandBuffer() else { throw Unavailable() }
        context.render(black,to:input,commandBuffer:command,bounds:extent,colorSpace:CGColorSpaceCreateDeviceRGB())
        try Self.encode(command,pipeline:composite,a:input,b:transmission,output:output)
        guard let image=CIImage(mtlTexture:output,options:[.colorSpace:NSNull()]) else { throw Unavailable() }
        let bounds=CGRect(x:0,y:0,width:drawable.texture.width,height:drawable.texture.height)
        let scaled=image.transformed(by:CGAffineTransform(scaleX:bounds.width/extent.width,y:bounds.height/extent.height))
        context.render(scaled,to:drawable.texture,commandBuffer:command,bounds:bounds,colorSpace:CGColorSpaceCreateDeviceRGB())
        drawable.addPresentedHandler { drawable in stats.presented(at:drawable.presentedTime) }
        command.addCompletedHandler { buffer in stats.completed(ok:buffer.status == .completed,
            gpuMilliseconds:max(0,buffer.gpuEndTime-buffer.gpuStartTime)*1000) }
        stats.submitted();command.present(drawable);command.commit()
        return true
    }
}

final class NativeMattePresentationStats: @unchecked Sendable {
    private let lock=NSLock()
    private var submittedCount=0,completedCount=0,failedCount=0,presentedCount=0,presentationCallbacks=0,lastPresentation:Double?
    private var intervals=[Double](),gpu=[Double](),longIntervals=[[Double]]()
    private var firstPresentation:Double?
    private var receivedCount=0,lastReceived:Double?
    private var receiveIntervals=[Double](),drawableWaits=[Double]()
    /// Arrival at the native view, distinct from GPU completion/presentation.
    /// Exclude calibration before the first actual drawable submission.
    func received(at time:Double) {lock.withLock {
        guard submittedCount>0,time.isFinite,time>0 else{return}
        receivedCount+=1
        if let last=lastReceived,time>last,receiveIntervals.count<7200 {receiveIntervals.append((time-last)*1000)}
        lastReceived=max(lastReceived ?? time,time)
    }}
    func drawableWait(milliseconds:Double) {lock.withLock {
        if milliseconds.isFinite,milliseconds>=0,drawableWaits.count<7200 {drawableWaits.append(milliseconds)}
    }}
    func submitted() {lock.withLock {submittedCount += 1}}
    func completed(ok:Bool,gpuMilliseconds:Double) { lock.withLock {
        completedCount += 1;if !ok {failedCount += 1}
        if gpu.count < 7200 && gpuMilliseconds.isFinite {gpu.append(gpuMilliseconds)}
    } }
    func presented(at time:Double) { lock.withLock {
        presentationCallbacks += 1
        guard time.isFinite,time > 0 else {return}
        presentedCount += 1
        if firstPresentation == nil {firstPresentation=time}
        if let last=lastPresentation,time > last,intervals.count < 7200 {
            let interval=(time-last)*1000;intervals.append(interval)
            if interval > 50,longIntervals.count < 128 {longIntervals.append([(time-firstPresentation!)*1000,interval])}
        }
        lastPresentation=max(lastPresentation ?? time,time)
    } }
    func snapshot() -> [String:Any] { lock.withLock {
        let sorted=intervals.sorted(),g=gpu.sorted(),received=receiveIntervals.sorted(),waits=drawableWaits.sorted()
        func p95(_ values:[Double])->Double {values.isEmpty ? -1:values[Int(Double(values.count-1)*0.95)]}
        return ["submitted":submittedCount,"completed":completedCount,"failed":failedCount,"presented":presentedCount,
            "receivedFrames":receivedCount,"receiveIntervalSamples":received.count,
            "receiveIntervalP95Milliseconds":p95(received),"receiveIntervalMaxMilliseconds":received.last ?? -1,
            "drawableWaitSamples":waits.count,"drawableWaitP95Milliseconds":p95(waits),
            "drawableWaitMaxMilliseconds":waits.last ?? -1,
            "pendingGPU":max(0,submittedCount-completedCount),
            "pendingPresentationCallbacks":max(0,submittedCount-presentationCallbacks),
            "presentationCallbacks":presentationCallbacks,
            "complete":submittedCount == completedCount && submittedCount == presentationCallbacks,
            "presentationIntervalP95Milliseconds":sorted.isEmpty ? -1 : sorted[Int(Double(sorted.count-1)*0.95)],
            "presentationIntervalMaxMilliseconds":sorted.last ?? -1,
            "intervalsOver50Milliseconds":longIntervals,
            "gpuMaxMilliseconds":g.last ?? -1,
            "gpuP95Milliseconds":g.isEmpty ? -1 : g[Int(Double(g.count-1)*0.95)]]
    } }
}
