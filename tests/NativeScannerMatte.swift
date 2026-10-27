import CoreImage
import Metal

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
    init(black: CIImage, white: CIImage, algorithm: Algorithm = .blackWhite) throws {
        guard black.extent == white.extent, black.extent.origin == .zero,
              !black.extent.isEmpty, black.extent.width <= 4096, black.extent.height <= 4096 else { throw Unavailable("dimensions") }
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw Unavailable() }
        extent = black.extent
        self.queue = queue
        let library = try device.makeLibrary(source: Self.source, options: nil)
        guard let calibrateFunction = library.makeFunction(name: algorithm == .blackWhite ? "calibrate" : "blueCalibrate"),
              let compositeFunction = library.makeFunction(name: algorithm == .blackWhite ? "composite" : "blueComposite") else { throw Unavailable() }
        let calibrate = try device.makeComputePipelineState(function: calibrateFunction)
        composite = try device.makeComputePipelineState(function: compositeFunction)
        context = CIContext(mtlDevice: device, options: [.workingColorSpace: NSNull(),
                    .outputColorSpace: NSNull(), .cacheIntermediates: false])
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
            width: Int(extent.width), height: Int(extent.height), mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        let calibrationDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
            width: Int(extent.width), height: Int(extent.height), mipmapped: false)
        calibrationDescriptor.usage = [.shaderRead, .shaderWrite]
        guard let input = device.makeTexture(descriptor: descriptor),
              let whiteInput = device.makeTexture(descriptor: descriptor),
              let transmission = device.makeTexture(descriptor: calibrationDescriptor),
              let output = device.makeTexture(descriptor: descriptor),
              let command = queue.makeCommandBuffer() else { throw Unavailable() }
        self.input = input; self.transmission = transmission; self.output = output
        context.render(black, to: input, commandBuffer: command, bounds: extent, colorSpace: CGColorSpaceCreateDeviceRGB())
        context.render(white, to: whiteInput, commandBuffer: command, bounds: extent, colorSpace: CGColorSpaceCreateDeviceRGB())
        try Self.encode(command, pipeline: calibrate, a: input, b: whiteInput, output: transmission)
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
}
