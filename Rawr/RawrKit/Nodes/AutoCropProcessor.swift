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
        // Core Image's Metal textures have a bottom-left origin. Documents and
        // the crop controls use top-left coordinates and clockwise degrees.
        rect = SIMD4(Float(geometry.centerX), Float(1 - geometry.centerY), Float(geometry.width), Float(geometry.height))
        rotation = SIMD4(Float(-geometry.degrees * .pi / 180), 0, 0, 0)
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
            pipelines[name] = context.resources.pipeline("autoCrop" + name)
        }
        self.pipelines = pipelines
    }

    func analyze(_ input: ImageData) async -> AutoCropResult? {
        let start = ProcessInfo.processInfo.systemUptime
        if let cached = cache[input.contentID] {
            context.trace.record("crop-detection-cache", since: start, device: context.device, cached: true)
            return cached
        }
        guard pipelines.count == 3, let command = context.commandQueue.makeCommandBuffer(),
              let profilesLease = context.resources.buffer(length: 65 * 2 * 256 * 4),
              let candidatesLease = context.resources.buffer(length: 65 * MemoryLayout<CropCandidate>.stride, options: .storageModeShared) else { return nil }
        let profiles = profilesLease.buffer, candidates = candidatesLease.buffer
        defer { withExtendedLifetime([profilesLease, candidatesLease]) {} }
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
        context.trace.record("crop-detection", since: start, device: context.device, command: command)
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
            centerY: 0.5 - (sin(angle) * dx + cos(angle) * dy) / Double(height),
            width: Double(bounds.y - bounds.x), height: Double(bounds.w - bounds.z), degrees: -degrees)
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
        let start = ProcessInfo.processInfo.systemUptime
        guard let pipeline = pipelines["Border"], let command = context.commandQueue.makeCommandBuffer(),
              let resultLease = context.resources.buffer(length: 16, options: .storageModeShared),
              let encoder = command.makeComputeCommandEncoder() else { return nil }
        let result = resultLease.buffer
        defer { withExtendedLifetime(resultLease) {} }
        var transform = CropTransform(geometry)
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(input.texture, index: 0)
        encoder.setBuffer(result, offset: 0, index: 0)
        encoder.setBytes(&transform, length: MemoryLayout<CropTransform>.stride, index: 1)
        encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        encoder.endEncoding()
        command.commit()
        await command.completed()
        context.trace.record("crop-border", since: start, device: context.device, command: command)
        return command.status == .completed ? result.contents().load(as: SIMD4<Float>.self) : nil
    }
}

public final class AutoCropProcessor: MetalNodeProcessor {
    private let detector: AutoCropDetector
    private let pipeline: MTLComputePipelineState?
    private struct Key: Equatable {
        let source: UUID
        let node: NodeData
    }
    private var cached: (key: Key, image: ImageData)?

    func clearCache() { cached = nil }

    public init(context: ProcessingContext) {
        detector = AutoCropDetector(context: context)
        pipeline = context.resources.pipeline("autoCropResample")
        super.init(nodeType: .autoCrop)
    }

    override public func process(inputs: [String: ImageData], node: NodeData, context: ProcessingContext) async -> [String: ImageData]? {
        let start = ProcessInfo.processInfo.systemUptime
        guard let input = inputs["Input"], input.metadata.domain == .linearTransmittance,
              input.texture.pixelFormat == .rgba32Float, let pipeline,
              var result = await detector.analyze(input) else {
            context.log("Auto Crop requires linear source data before development/effects", level: .error)
            return nil
        }
        let settings = node.autoCrop ?? AutoCropSettings()
        if settings.rollSize != nil && !result.accepted {
            let report = result
            await MainActor.run { context.logger?.cropResults[node.id] = report }
            context.log("Auto Crop: uncertain roll frame; review its borders before batch export", level: .error)
            return nil
        }
        let proposal = result.accepted ? result.proposal : CropGeometry()
        let geometry = settings.geometry(proposal: proposal, source: result.source, sourceWidth: result.sourceWidth, sourceHeight: result.sourceHeight)
        result.applied = geometry
        let report = result
        await MainActor.run { context.logger?.cropResults[node.id] = report }
        guard geometry.isValid(width: input.texture.width, height: input.texture.height) else {
            context.log("Auto Crop: rectangle extends outside the scan; adjust size, center or rotation", level: .error)
            return nil
        }
        if geometry == CropGeometry() {
            context.log("Auto Crop: low confidence; image retained intact", level: .warning)
            return ["Output": input]
        }
        var configuration = node
        configuration.position = .zero
        let key = Key(source: input.contentID, node: configuration)
        if let cached, cached.key == key {
            context.trace.record("crop-cache", since: start, device: context.device, cached: true)
            return ["Output": cached.image]
        }
        cached = nil
        // Derive roll dimensions from the reference once, avoiding a one-pixel
        // difference from normalize/denormalize rounding on different scans.
        let pixelWidth = settings.rollSize.map { $0.width * Double(settings.rollSourceWidth ?? input.texture.width) }
            ?? geometry.width * Double(input.texture.width)
        let pixelHeight = settings.rollSize.map { $0.height * Double(settings.rollSourceHeight ?? input.texture.height) }
            ?? geometry.height * Double(input.texture.height)
        let width = max(1, Int(pixelWidth.rounded(.down)))
        let height = max(1, Int(pixelHeight.rounded(.down)))
        guard let command = context.commandQueue.makeCommandBuffer() else { return nil }
        command.label = "Auto Crop: straighten and crop (RGB + registered IR)"
        var transform = CropTransform(geometry)
        func resample(_ source: MTLTexture) -> TextureLease? {
            guard let lease = context.resources.texture(format: source.pixelFormat, width: width, height: height),
                  let encoder = command.makeComputeCommandEncoder() else { return nil }
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(source, index: 0)
            encoder.setTexture(lease.texture, index: 1)
            encoder.setBytes(&transform, length: MemoryLayout<CropTransform>.stride, index: 0)
            encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                threadsPerThreadgroup: MTLSize(width: pipeline.threadExecutionWidth, height: 4, depth: 1))
            encoder.endEncoding()
            return lease
        }
        guard let output = resample(input.texture) else { return nil }
        var infrared: TextureLease?
        if let source = input.infraredTexture {
            guard source.width == input.texture.width, source.height == input.texture.height,
                  let cropped = resample(source) else { return nil }
            infrared = cropped
        }
        command.commit()
        await command.completed()
        context.trace.record("crop", since: start, device: context.device, command: command)
        guard command.status == .completed else { return nil }
        var metadata = input.metadata
        metadata.width = width
        metadata.height = height
        metadata.dustMaskPreview = nil
        metadata.dustMaskLease = nil
        metadata.legacyFloatOutput = false
        metadata.cropFilmBase = settings.useBorderForBase && result.accepted && result.borderBase.w > 0 ? result.borderBase : nil
        context.log("Auto Crop: \(width)×\(height), \(geometry.degrees)°, confidence \(Int(result.confidence * 100))%")
        let image = ImageData(lease: output, metadata: metadata, infraredLease: infrared)
        let bytes = output.texture.allocatedSize + (infrared?.texture.allocatedSize ?? 0)
        if bytes <= min(768 * 1024 * 1024, Int(context.device.recommendedMaxWorkingSetSize / 2)),
           context.logger?.isFullResolutionMode != true {
            cached = (key, image)
        }
        return ["Output": image]
    }
}
