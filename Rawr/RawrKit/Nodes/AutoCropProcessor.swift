import Foundation
import Metal

private struct CropCandidate {
    var bounds: SIMD4<Float>
    var quality: SIMD4<Float>
}

private struct CropTransform {
    var rect: SIMD4<Float>
    var rotation: SIMD4<Float>
    init(_ geometry: CropGeometry) {
        rect = SIMD4(Float(geometry.centerX), Float(geometry.centerY), Float(geometry.width), Float(geometry.height))
        rotation = SIMD4(Float(geometry.degrees * .pi / 180), 0, 0, 0)
    }
}

/// Edge contrasts and line integration stay on Metal. CPU ranks 65 tiny
/// candidates; image pixels never cross to CPU. Cache is bounded to four scans.
actor AutoCropDetector {
    private let context: ProcessingContext
    private let pipelines: [String: MTLComputePipelineState]
    private var cache: [UUID: AutoCropResult] = [:]
    private var order: [UUID] = []

    init(context: ProcessingContext) {
        self.context = context
        var pipelines: [String: MTLComputePipelineState] = [:]
        for name in ["Projections", "Select", "Border"] {
            if let function = context.shaderLibrary?.makeFunction(name: "autoCrop" + name) {
                pipelines[name] = try? context.device.makeComputePipelineState(function: function)
            }
        }
        self.pipelines = pipelines
    }

    func analyze(_ input: ImageData) async -> AutoCropResult? {
        if let cached = cache[input.contentID] { return cached }
        guard pipelines.count == 3, let command = context.commandQueue.makeCommandBuffer(),
              let profiles = context.device.makeBuffer(length: 65 * 2 * 256 * 4, options: .storageModePrivate),
              let candidates = context.device.makeBuffer(length: 65 * MemoryLayout<CropCandidate>.stride, options: .storageModeShared) else { return nil }
        command.label = "Auto Crop: rotated edge projections and frame candidates"
        for name in ["Projections", "Select"] {
            guard let encoder = command.makeComputeCommandEncoder(), let pipeline = pipelines[name] else { return nil }
            encoder.setComputePipelineState(pipeline)
            encoder.setBuffer(profiles, offset: 0, index: 0)
            let size: MTLSize
            if name == "Projections" {
                encoder.setTexture(input.texture, index: 0)
                size = MTLSize(width: 256, height: 2, depth: 65)
            } else {
                encoder.setBuffer(candidates, offset: 0, index: 1)
                size = MTLSize(width: 65, height: 1, depth: 1)
            }
            encoder.dispatchThreads(size, threadsPerThreadgroup: MTLSize(width: pipeline.threadExecutionWidth, height: 1, depth: 1))
            encoder.endEncoding()
        }
        command.commit()
        await command.completed()
        guard command.status == .completed else { return nil }
        let summaries = UnsafeBufferPointer(start: candidates.contents().assumingMemoryBound(to: CropCandidate.self), count: 65)
        let best = summaries.indices.max { summaries[$0].quality.x < summaries[$1].quality.x } ?? 32
        let candidate = summaries[best]
        let degrees = Double(best - 32) * 0.25
        let angle = degrees * .pi / 180
        let bounds = candidate.bounds
        let width = input.texture.width, height = input.texture.height
        let dx = Double((bounds.x + bounds.y) / 2 - 0.5) * Double(width)
        let dy = Double((bounds.z + bounds.w) / 2 - 0.5) * Double(height)
        var geometry = CropGeometry(centerX: 0.5 + (cos(angle) * dx - sin(angle) * dy) / Double(width),
            centerY: 0.5 + (sin(angle) * dx + cos(angle) * dy) / Double(height),
            width: Double(bounds.y - bounds.x), height: Double(bounds.w - bounds.z), degrees: degrees)
        var confidence = Double(candidate.quality.y)
        if !geometry.isValid(width: width, height: height) || abs(degrees) == 8 { confidence = 0 }
        let raw = geometry
        // A small safety inset removes the edge transition and mild light leaks.
        geometry.width = max(0.02, geometry.width - 0.012)
        geometry.height = max(0.02, geometry.height - 0.012)
        var result = AutoCropResult(proposal: geometry, applied: geometry, confidence: confidence,
            source: input.metadata.sourceURL, sourceWidth: width, sourceHeight: height,
            gpuSeconds: command.gpuEndTime - command.gpuStartTime)
        if result.accepted, let border = await borderBase(input, geometry: raw) { result.borderBase = border }
        cache[input.contentID] = result
        order.append(input.contentID)
        if order.count > 4 { cache.removeValue(forKey: order.removeFirst()) }
        return result
    }

    private func borderBase(_ input: ImageData, geometry: CropGeometry) async -> SIMD4<Float>? {
        guard let pipeline = pipelines["Border"], let command = context.commandQueue.makeCommandBuffer(),
              let result = context.device.makeBuffer(length: 16, options: .storageModeShared),
              let encoder = command.makeComputeCommandEncoder() else { return nil }
        var transform = CropTransform(geometry)
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(input.texture, index: 0)
        encoder.setBuffer(result, offset: 0, index: 0)
        encoder.setBytes(&transform, length: MemoryLayout<CropTransform>.stride, index: 1)
        encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        encoder.endEncoding()
        command.commit()
        await command.completed()
        return command.status == .completed ? result.contents().load(as: SIMD4<Float>.self) : nil
    }
}

public final class AutoCropProcessor: MetalNodeProcessor {
    private let detector: AutoCropDetector
    private let pipeline: MTLComputePipelineState?

    public init(context: ProcessingContext) {
        detector = AutoCropDetector(context: context)
        pipeline = context.shaderLibrary?.makeFunction(name: "autoCropResample").flatMap {
            try? context.device.makeComputePipelineState(function: $0)
        }
        super.init(nodeType: .autoCrop)
    }

    override public func process(inputs: [String: ImageData], node: NodeData, context: ProcessingContext) async -> [String: ImageData]? {
        guard let input = inputs["Input"], input.metadata.domain == .linearTransmittance,
              input.texture.pixelFormat == .rgba32Float, let pipeline,
              var result = await detector.analyze(input) else {
            context.log("Auto Crop requires linear source data before development/effects", level: .error)
            return nil
        }
        let settings = node.autoCrop ?? AutoCropSettings()
        if settings.rollSize != nil && !result.accepted {
            await MainActor.run { context.logger?.cropResults[node.id] = result }
            context.log("Auto Crop: uncertain roll frame; review its borders before batch export", level: .error)
            return nil
        }
        let proposal = result.accepted ? result.proposal : CropGeometry()
        let geometry = settings.geometry(proposal: proposal, source: result.source, sourceWidth: result.sourceWidth, sourceHeight: result.sourceHeight)
        result.applied = geometry
        await MainActor.run { context.logger?.cropResults[node.id] = result }
        guard geometry.isValid(width: input.texture.width, height: input.texture.height) else {
            context.log("Auto Crop: rectangle extends outside the scan; adjust size, center or rotation", level: .error)
            return nil
        }
        if geometry == CropGeometry() {
            context.log("Auto Crop: low confidence; image retained intact", level: .warning)
            return ["Output": input]
        }
        let width = max(1, Int((geometry.width * Double(input.texture.width)).rounded(.down)))
        let height = max(1, Int((geometry.height * Double(input.texture.height)).rounded(.down)))
        guard let command = context.commandQueue.makeCommandBuffer() else { return nil }
        command.label = "Auto Crop: straighten and crop (RGB + registered IR)"
        var transform = CropTransform(geometry)
        func resample(_ source: MTLTexture) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: source.pixelFormat, width: width, height: height, mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = .private
            guard let output = context.device.makeTexture(descriptor: descriptor), let encoder = command.makeComputeCommandEncoder() else { return nil }
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(source, index: 0)
            encoder.setTexture(output, index: 1)
            encoder.setBytes(&transform, length: MemoryLayout<CropTransform>.stride, index: 0)
            encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                threadsPerThreadgroup: MTLSize(width: pipeline.threadExecutionWidth, height: 4, depth: 1))
            encoder.endEncoding()
            return output
        }
        guard let output = resample(input.texture) else { return nil }
        var infrared: MTLTexture?
        if let source = input.infraredTexture {
            guard source.width == input.texture.width, source.height == input.texture.height,
                  let cropped = resample(source) else { return nil }
            infrared = cropped
        }
        command.commit()
        await command.completed()
        guard command.status == .completed else { return nil }
        var metadata = input.metadata
        metadata.width = width
        metadata.height = height
        metadata.dustMaskPreview = nil
        metadata.cropFilmBase = settings.useBorderForBase && result.accepted && result.borderBase.w > 0 ? result.borderBase : nil
        context.log("Auto Crop: \(width)×\(height), \(geometry.degrees)°, confidence \(Int(result.confidence * 100))%")
        return ["Output": ImageData(texture: output, metadata: metadata, infraredTexture: infrared)]
    }
}
