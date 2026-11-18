import Foundation
import Metal

/// One command buffer, GPU-only intermediate textures, and no image readback.
public final class DustRemovalProcessor: MetalNodeProcessor {
    public private(set) var lastGPUTime: Double?
    private var pipelines: [String: MTLComputePipelineState] = [:]
    private let names = ["dustIRFit", "dustIRCorrect", "dustIRDilateX", "dustIRDilateY",
        "dustMask", "dustRepair"]

    public init(context: ProcessingContext) {
        for name in names {
            if let f = context.shaderLibrary?.makeFunction(name: name) {
                pipelines[name] = try? context.device.makeComputePipelineState(function: f)
            }
        }
        super.init(nodeType: .dustRemoval)
    }

    override public func process(inputs: [String: ImageData], node: NodeData, context: ProcessingContext) async -> [String: ImageData]? {
        lastGPUTime = nil
        guard let input = inputs["Input"], input.metadata.domain == .linearTransmittance,
              input.texture.pixelFormat == .rgba32Float else {
            context.log("Dust Removal requires a linear source before Negative Develop", level: .error)
            return nil
        }
        let useInfrared = node.parameters["useIR"] != 0
        var infrared = useInfrared ? input.infraredTexture : nil
        if useInfrared && (node.infraredURL != nil || node.infraredBookmark != nil) {
            do {
                var stale = false
                let url: URL
                if let bookmark = node.infraredBookmark {
                    url = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope,
                        relativeTo: nil, bookmarkDataIsStale: &stale)
                    guard !stale else { throw ImageDecoder.DecodeError.invalidImage }
                } else { url = node.infraredURL! }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                infrared = try InfraredImageIO.loadFrame(url: url, context: context)
            } catch {
                context.log("Infrared frame failed: \(error.localizedDescription)", level: .error)
                return nil
            }
        }
        guard infrared == nil || (infrared!.width == input.texture.width && infrared!.height == input.texture.height),
              var parameters = DustParameters(node.parameters, infrared: infrared != nil, spots: node.healSpots),
              pipelines.count == names.count else {
            context.log("Invalid dust controls, spots, IR dimensions, or unavailable Metal kernels", level: .error)
            return nil
        }
        let w = input.texture.width, h = input.texture.height
        func texture(_ format: MTLPixelFormat) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
            d.storageMode = .private
            d.usage = [.shaderRead, .shaderWrite]
            return context.device.makeTexture(descriptor: d)
        }
        guard let mask = texture(.r16Float), let output = texture(.rgba32Float),
              let maskImage = texture(.rgba16Float),
              let fit = context.device.makeBuffer(length: 16, options: .storageModePrivate),
              let command = context.commandQueue.makeCommandBuffer() else { return nil }
        var spotValues = node.healSpots.map { SIMD4<Float>(Float($0.x), Float($0.y), Float($0.radius), 0) }
        if spotValues.isEmpty { spotValues = [.zero] }
        guard let spots = spotValues.withUnsafeBytes({ bytes in
            context.device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count)
        }) else { return nil }
        func encode(_ name: String, textures: [MTLTexture], single: Bool = false) -> Bool {
            guard let pipeline = pipelines[name], let encoder = command.makeComputeCommandEncoder() else { return false }
            encoder.label = name
            encoder.setComputePipelineState(pipeline)
            for (index, texture) in textures.enumerated() { encoder.setTexture(texture, index: index) }
            encoder.setBytes(&parameters, length: MemoryLayout<DustParameters>.stride, index: 0)
            encoder.setBuffer(fit, offset: 0, index: 1)
            encoder.setBuffer(spots, offset: 0, index: 2)
            let width = pipeline.threadExecutionWidth
            encoder.dispatchThreads(MTLSize(width: single ? 1 : w, height: single ? 1 : h, depth: 1),
                threadsPerThreadgroup: MTLSize(width: single ? 1 : width, height: single ? 1 : 4, depth: 1))
            encoder.endEncoding()
            return true
        }
        var corrected: MTLTexture = input.texture
        var background: MTLTexture = input.texture
        if parameters.flags.x == 1 {
            guard let ir = infrared, let c = texture(.r32Float), let x = texture(.r32Float), let y = texture(.r32Float),
                  encode("dustIRFit", textures: [input.texture, ir], single: true),
                  encode("dustIRCorrect", textures: [input.texture, ir, c]),
                  encode("dustIRDilateX", textures: [c, x]),
                  encode("dustIRDilateY", textures: [x, y]) else { return nil }
            corrected = c
            background = y
        }
        guard encode("dustMask", textures: [input.texture, corrected, background, mask]),
              encode("dustRepair", textures: [input.texture, mask, output, maskImage]) else { return nil }
        command.label = "Dust Removal: \(parameters.flags.x == 1 ? "infrared" : "optical")"
        command.commit()
        await command.completed()
        guard command.status == .completed else {
            context.log("Dust Removal GPU failed: \(command.error?.localizedDescription ?? "unknown")", level: .error)
            return nil
        }
        lastGPUTime = command.gpuEndTime > command.gpuStartTime ? command.gpuEndTime - command.gpuStartTime : nil
        context.log("Dust Removal: \(parameters.flags.x == 1 ? "infrared ratio" : "RGB fallback"), \(node.healSpots.count) manual spots")
        var metadata = input.metadata
        metadata.dustMaskPreview = parameters.controls.z == 1 ? maskImage : nil
        var maskMetadata = input.metadata
        maskMetadata.domain = .unspecified
        maskMetadata.dustMaskPreview = nil
        return ["Output": ImageData(texture: output, metadata: metadata),
            "Mask": ImageData(texture: maskImage, metadata: maskMetadata)]
    }
}
