import Foundation
import Metal

/// One command buffer, GPU-only intermediate textures, and no image readback.
public final class DustRemovalProcessor: MetalNodeProcessor {
    public private(set) var lastGPUTime: Double?
    private struct CacheKey: Equatable {
        let source: UUID
        let node: NodeData
        let infrared: SourceIdentity?
        let needsMask: Bool
    }
    private var infraredCache: (key: SourceIdentity, texture: MTLTexture)?
    private var cached: (key: CacheKey, outputs: [String: ImageData])?
    private var pipelines: [String: MTLComputePipelineState] = [:]
    private let rowsPerTile: Int
    private let names = ["dustIRFit", "dustIRCorrect", "dustIRDilateX", "dustIRDilateY",
        "dustMask", "dustRepair"]

    func clearCache() { cached = nil; infraredCache = nil }

    public convenience init(context: ProcessingContext) {
        self.init(context: context, rowsPerTile: 512)
    }

    init(context: ProcessingContext, rowsPerTile: Int) {
        self.rowsPerTile = max(1, rowsPerTile)
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
        let needsMask = node.parameters["maskPreview"] == 1 || (context.requestedMasks?.contains(node.id) ?? true)
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
                let key = CacheKey(source: input.contentID, node: node, infrared: infraredIdentity, needsMask: needsMask)
                if let cached, cached.key == key {
                    context.trace.record("dust-cache", since: stageStart, device: context.device, cached: true)
                    return cached.outputs
                }
                if let existing = infraredCache, existing.key == infraredIdentity {
                    infrared = existing.texture
                } else {
                    infraredCache = nil
                    let texture = try InfraredImageIO.loadFrame(url: url, context: context)
                    guard try SourceIdentity(url) == infraredIdentity else { return nil }
                    infrared = texture
                    infraredCache = (try SourceIdentity(url), texture)
                }
            } catch {
                context.log("Infrared frame failed: \(error.localizedDescription)", level: .error)
                return nil
            }
        }
        let cacheKey = CacheKey(source: input.contentID, node: node, infrared: infraredIdentity, needsMask: needsMask)
        if let cached, cached.key == cacheKey {
            context.trace.record("dust-cache", since: stageStart, device: context.device, cached: true)
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
        parameters.flags.z = needsMask ? 1 : 0
        var scratch: [TextureLease] = []
        defer { withExtendedLifetime(scratch) {} }
        func texture(_ format: MTLPixelFormat, height: Int? = nil) -> MTLTexture? {
            guard let lease = context.resources.texture(format: format, width: w, height: height ?? h) else { return nil }
            scratch.append(lease)
            return lease.texture
        }
        guard let mask = texture(.r16Float),
              let outputLease = context.resources.texture(format: .rgba32Float, width: w, height: h),
              let maskLease = context.resources.texture(format: .rgba16Float, width: needsMask ? w : 1, height: needsMask ? h : 1),
              let fitLease = context.resources.buffer(length: 16),
              let command = context.commandQueue.makeCommandBuffer() else { return nil }
        defer { withExtendedLifetime(fitLease) {} }
        defer { withExtendedLifetime(maskLease) {} }
        let output = outputLease.texture, maskImage = maskLease.texture, fit = fitLease.buffer
        var spotValues = node.healSpots.map { SIMD4<Float>(Float($0.x), Float($0.y), Float($0.radius), 0) }
        if spotValues.isEmpty { spotValues = [.zero] }
        func encode(_ name: String, textures: [MTLTexture], single: Bool = false,
                    rows: Int? = nil, tile: SIMD4<UInt32>? = nil) -> Bool {
            guard let pipeline = pipelines[name], let encoder = command.makeComputeCommandEncoder() else { return false }
            encoder.label = name
            encoder.setComputePipelineState(pipeline)
            for (index, texture) in textures.enumerated() { encoder.setTexture(texture, index: index) }
            encoder.setBytes(&parameters, length: MemoryLayout<DustParameters>.stride, index: 0)
            encoder.setBuffer(fit, offset: 0, index: 1)
            spotValues.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 2) }
            // Tile ABI: input start Y, output start Y, valid scratch rows, core rows.
            var region = tile ?? SIMD4<UInt32>(0, 0, UInt32(h), UInt32(h))
            encoder.setBytes(&region, length: MemoryLayout<SIMD4<UInt32>>.stride, index: 3)
            let width = pipeline.threadExecutionWidth
            encoder.dispatchThreads(MTLSize(width: single ? 1 : w, height: single ? 1 : (rows ?? h), depth: 1),
                threadsPerThreadgroup: MTLSize(width: single ? 1 : width, height: single ? 1 : 4, depth: 1))
            encoder.endEncoding()
            return true
        }
        if parameters.flags.x == 1 {
            let coreRows = min(h, rowsPerTile)
            let halo = Int(parameters.controls.y) * 2 + 2
            let scratchRows = min(h, coreRows + 2 * halo)
            guard let ir = infrared, let c = texture(.r32Float, height: scratchRows),
                  let x = texture(.r32Float, height: scratchRows), let y = texture(.r32Float, height: scratchRows),
                  encode("dustIRFit", textures: [input.texture, ir], single: true) else { return nil }
            // Reuse the same strips inside one ordered command buffer. Halos
            // preserve the closing support; the full mask is complete before
            // repair reads donors across strip boundaries.
            for start in stride(from: 0, to: h, by: coreRows) {
                let count = min(coreRows, h - start), origin = max(0, start - halo)
                let validRows = min(h, start + count + halo) - origin
                let tile = SIMD4<UInt32>(UInt32(origin), UInt32(start), UInt32(validRows), UInt32(count))
                guard encode("dustIRCorrect", textures: [input.texture, ir, c], rows: validRows, tile: tile),
                      encode("dustIRDilateX", textures: [c, x], rows: validRows, tile: tile),
                      encode("dustIRDilateY", textures: [x, y], rows: validRows, tile: tile),
                      encode("dustMask", textures: [input.texture, c, y, mask], rows: count, tile: tile) else { return nil }
            }
        } else {
            guard encode("dustMask", textures: [input.texture, input.texture, input.texture, mask]) else { return nil }
        }
        guard encode("dustRepair", textures: [input.texture, mask, output, maskImage]) else { return nil }
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
        metadata.legacyFloatOutput = false
        metadata.dustMaskLease = parameters.controls.z == 1 ? maskLease : nil
        metadata.dustMaskPreview = parameters.controls.z == 1 ? maskImage : nil
        var maskMetadata = input.metadata
        maskMetadata.domain = .unspecified
        maskMetadata.legacyFloatOutput = false
        maskMetadata.dustMaskPreview = nil
        maskMetadata.dustMaskLease = nil
        var outputs = ["Output": ImageData(lease: outputLease, metadata: metadata)]
        if needsMask { outputs["Mask"] = ImageData(lease: maskLease, metadata: maskMetadata) }
        let bytes = output.allocatedSize + (needsMask ? maskImage.allocatedSize : 0)
        if bytes <= min(768 * 1024 * 1024, Int(context.device.recommendedMaxWorkingSetSize / 2)),
           context.logger?.isFullResolutionMode != true {
            cached = (cacheKey, outputs)
        }
        return outputs
    }
}
