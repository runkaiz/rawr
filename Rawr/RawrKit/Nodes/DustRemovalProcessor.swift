import Foundation
import Metal

/// One command buffer, GPU-only intermediate textures, and no image readback.
public final class DustRemovalProcessor: MetalNodeProcessor {
    public private(set) var lastGPUTime: Double?
    private struct CacheKey: Equatable {
        let source: UUID
        let node: NodeData
        let infrared: SourceIdentity?
    }
    private var infraredCache: (key: SourceIdentity, texture: MTLTexture)?
    private var cached: (key: CacheKey, outputs: [String: ImageData])?
    private var pipelines: [String: MTLComputePipelineState] = [:]
    private let names = ["dustIRFit", "dustIRCorrect", "dustIRDilateX", "dustIRDilateY",
        "dustMask", "dustRepair"]

    func clearCache() { cached = nil; infraredCache = nil }

    public init(context: ProcessingContext) {
        for name in names {
            pipelines[name] = context.resources.pipeline(name)
        }
        super.init(nodeType: .dustRemoval)
    }

    override public func process(inputs: [String: ImageData], node: NodeData, context: ProcessingContext) async -> [String: ImageData]? {
        lastGPUTime = nil
        let stageStart = ProcessInfo.processInfo.systemUptime
        guard let input = inputs["Input"], input.metadata.domain == .linearTransmittance,
              input.texture.pixelFormat == .rgba32Float else {
            context.log("Dust Removal requires a linear source before Negative Develop", level: .error)
            return nil
        }
        var node = node
        node.position = .zero
        var infraredIdentity: SourceIdentity?
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
                infraredIdentity = try SourceIdentity(url)
                let key = CacheKey(source: input.contentID, node: node, infrared: infraredIdentity)
                if let cached, cached.key == key {
                    context.trace.record("dust-cache", since: stageStart, device: context.device)
                    return cached.outputs
                }
                if let existing = infraredCache, existing.key == infraredIdentity {
                    infrared = existing.texture
                } else {
                    infraredCache = nil
                    let texture = try InfraredImageIO.loadFrame(url: url, context: context)
                    infrared = texture
                    infraredCache = (try SourceIdentity(url), texture)
                }
            } catch {
                context.log("Infrared frame failed: \(error.localizedDescription)", level: .error)
                return nil
            }
        }
        let cacheKey = CacheKey(source: input.contentID, node: node, infrared: infraredIdentity)
        if let cached, cached.key == cacheKey {
            context.trace.record("dust-cache", since: stageStart, device: context.device)
            return cached.outputs
        }
        // Release the previous frame before allocating another full-size result.
        cached = nil
        guard infrared == nil || (infrared!.width == input.texture.width && infrared!.height == input.texture.height),
              var parameters = DustParameters(node.parameters, infrared: infrared != nil, spots: node.healSpots),
              pipelines.count == names.count else {
            context.log("Invalid dust controls, spots, IR dimensions, or unavailable Metal kernels", level: .error)
            return nil
        }
        let w = input.texture.width, h = input.texture.height
        var scratch: [TextureLease] = []
        defer { withExtendedLifetime(scratch) {} }
        func texture(_ format: MTLPixelFormat) -> MTLTexture? {
            guard let lease = context.resources.texture(format: format, width: w, height: h) else { return nil }
            scratch.append(lease)
            return lease.texture
        }
        guard let mask = texture(.r16Float),
              let outputLease = context.resources.texture(format: .rgba32Float, width: w, height: h),
              let maskLease = context.resources.texture(format: .rgba16Float, width: w, height: h),
              let fitLease = context.resources.buffer(length: 16),
              let command = context.commandQueue.makeCommandBuffer() else { return nil }
        defer { withExtendedLifetime(fitLease) {} }
        let output = outputLease.texture, maskImage = maskLease.texture, fit = fitLease.buffer
        var spotValues = node.healSpots.map { SIMD4<Float>(Float($0.x), Float($0.y), Float($0.radius), 0) }
        if spotValues.isEmpty { spotValues = [.zero] }
        func encode(_ name: String, textures: [MTLTexture], single: Bool = false) -> Bool {
            guard let pipeline = pipelines[name], let encoder = command.makeComputeCommandEncoder() else { return false }
            encoder.label = name
            encoder.setComputePipelineState(pipeline)
            for (index, texture) in textures.enumerated() { encoder.setTexture(texture, index: index) }
            encoder.setBytes(&parameters, length: MemoryLayout<DustParameters>.stride, index: 0)
            encoder.setBuffer(fit, offset: 0, index: 1)
            spotValues.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 2) }
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
        context.trace.record(node.type.rawValue, since: stageStart, device: context.device, command: command)
        guard command.status == .completed else {
            context.log("Dust Removal GPU failed: \(command.error?.localizedDescription ?? "unknown")", level: .error)
            return nil
        }
        lastGPUTime = command.gpuEndTime > command.gpuStartTime ? command.gpuEndTime - command.gpuStartTime : nil
        context.log("Dust Removal: \(parameters.flags.x == 1 ? "infrared ratio" : "RGB fallback"), \(node.healSpots.count) manual spots")
        var metadata = input.metadata
        metadata.dustMaskLease = parameters.controls.z == 1 ? maskLease : nil
        metadata.dustMaskPreview = parameters.controls.z == 1 ? maskImage : nil
        var maskMetadata = input.metadata
        maskMetadata.domain = .unspecified
        maskMetadata.dustMaskPreview = nil
        maskMetadata.dustMaskLease = nil
        let outputs = ["Output": ImageData(lease: outputLease, metadata: metadata),
            "Mask": ImageData(lease: maskLease, metadata: maskMetadata)]
        let bytes = output.allocatedSize + maskImage.allocatedSize
        if bytes <= min(768 * 1024 * 1024, Int(context.device.recommendedMaxWorkingSetSize / 2)),
           context.logger?.isFullResolutionMode != true {
            cached = (cacheKey, outputs)
        }
        return outputs
    }
}
