import Foundation
import Metal

/// GPU ABI: keep in sync with MeterResult in NegativeMetering.metal.
struct NegativeMeteringResult: Equatable, Sendable {
    var base = SIMD4<Float>(1, 1, 1, 0)
    var low = SIMD4<Float>(repeating: 0)
    var high = SIMD4<Float>(2, 2, 2, 0)
    var offset = SIMD4<Float>(repeating: 0)
    var slope = SIMD4<Float>(1, 1, 1, 0)
    var quality = SIMD4<Float>(repeating: 0)

    /// Freeze an estimate into document-owned manual values. No runtime estimate
    /// is serialized until the user explicitly locks it.
    func locking(_ group: String, in values: [String: Double]) -> [String: Double] {
        var values = values
        values["auto" + group] = 0
        for (c, name) in ["R", "G", "B"].enumerated() {
            switch group {
            case "Base": values["base" + name] = Double(base[c])
            case "Endpoints":
                values["low" + name] = Double(low[c])
                values["high" + name] = Double(high[c])
            case "Balance":
                values["balance" + name] = Double(offset[c])
                values["slope" + name] = Double(slope[c])
            default: break
            }
        }
        // With automatic balance, the print uses the green density coordinate.
        if group == "Endpoints", values["autoBalance"] == 1 {
            for name in ["R", "B"] {
                values["low" + name] = Double(low.y)
                values["high" + name] = Double(high.y)
            }
        }
        return values
    }
}

struct NegativeMeteringOutput {
    let lease: BufferLease
    var buffer: MTLBuffer { lease.buffer }
    let result: NegativeMeteringResult
    let gpuSeconds: Double
}

/// Immutable summaries cached by immutable source identity and effective base.
/// Curve edits, endpoint locks, and balance overrides reuse the same analysis.
/// Four summaries bound memory; temporary private buffers die after completion.
actor NegativeMetering {
    private struct Key: Hashable {
        let source: UUID
        let base: SIMD4<Float>
    }
    private struct Config {
        var grid: SIMD4<UInt32>
        var base: SIMD4<Float>
    }
    private let context: ProcessingContext
    private let pipelines: [String: MTLComputePipelineState]
    private var cache: [Key: NegativeMeteringOutput] = [:]
    private var order: [Key] = []
    private(set) var computationCount = 0

    init(context: ProcessingContext) {
        self.context = context
        var pipelines: [String: MTLComputePipelineState] = [:]
        for name in ["BaseCandidates", "BaseSelect", "Sample", "Histogram", "Merge", "Select", "Moments", "Fit"] {
            pipelines[name] = context.resources.pipeline("negativeMeter" + name)
        }
        self.pipelines = pipelines
    }

    func analyze(_ input: ImageData, parameters: [String: Double]) async -> NegativeMeteringOutput? {
        let stageStart = ProcessInfo.processInfo.systemUptime
        guard let manual = NegativeDevelopParameters(parameters), pipelines.count == 8 else { return nil }
        let detectedBase = parameters["autoBase"] == 1 ? input.metadata.cropFilmBase : nil
        let effectiveBase = detectedBase ?? manual.base
        let autoBase = parameters["autoBase"] == 1 && detectedBase == nil
        let key = Key(source: input.contentID, base: autoBase ? .zero : effectiveBase)
        if let cached = cache[key] {
            context.trace.record("meter-cache", since: stageStart, device: context.device, cached: true)
            return cached
        }
        let width = min(512, input.texture.width), height = min(512, input.texture.height)
        let count = width * height, groups = (count + 1023) / 1024
        var cfg = Config(grid: SIMD4(UInt32(width), UInt32(height), UInt32(count), autoBase ? 1 : 0), base: effectiveBase)
        guard let candidatesLease = context.resources.buffer(length: 2560 * 32),
              let samplesLease = context.resources.buffer(length: count * 16),
              let partialLease = context.resources.buffer(length: groups * 3 * 4096 * 4),
              let histogramLease = context.resources.buffer(length: 3 * 4096 * 4),
              let momentsLease = context.resources.buffer(length: groups * 3 * 16),
              let summaryLease = context.resources.buffer(length: MemoryLayout<NegativeMeteringResult>.stride, options: .storageModeShared),
              let command = context.commandQueue.makeCommandBuffer() else { return nil }
        let samples = samplesLease.buffer, partial = partialLease.buffer
        let histogram = histogramLease.buffer, moments = momentsLease.buffer, summary = summaryLease.buffer
        defer { withExtendedLifetime([candidatesLease, samplesLease, partialLease, histogramLease, momentsLease]) {} }
        var initial = NegativeMeteringResult()
        withUnsafeBytes(of: &initial) { summary.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        command.label = "Negative metering: grid, histograms, CDF, neutral axis"
        func encode(_ name: String, size: MTLSize, grouped: Bool = false, _ setup: (MTLComputeCommandEncoder) -> Void) -> Bool {
            guard let encoder = command.makeComputeCommandEncoder(), let pipeline = pipelines[name] else { return false }
            encoder.label = "Negative metering " + name
            encoder.setComputePipelineState(pipeline)
            setup(encoder)
            let threads = MTLSize(width: grouped ? 256 : min(256, pipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1)
            if grouped { encoder.dispatchThreadgroups(size, threadsPerThreadgroup: threads) }
            else { encoder.dispatchThreads(size, threadsPerThreadgroup: threads) }
            encoder.endEncoding()
            return true
        }
        if autoBase {
            guard encode("BaseCandidates", size: MTLSize(width: 2560, height: 1, depth: 1), {
                $0.setTexture(input.texture,index:0)
                $0.setBuffer(candidatesLease.buffer,offset:0,index:0)
            }), encode("BaseSelect", size: MTLSize(width:1,height:1,depth:1), {
                $0.setTexture(input.texture,index:0)
                $0.setBuffer(candidatesLease.buffer,offset:0,index:0)
                $0.setBuffer(summary,offset:0,index:1)
            }) else { return nil }
        }
        guard encode("Sample", size: MTLSize(width: count, height: 1, depth: 1), {
            $0.setTexture(input.texture, index: 0)
            $0.setBuffer(samples, offset: 0, index: 0)
            $0.setBytes(&cfg, length: MemoryLayout<Config>.stride, index: 1)
        }) else { return nil }
        for value in 0...2 {
            var phase = UInt32(value)
            guard encode("Histogram", size: MTLSize(width: groups, height: 3, depth: 1), grouped: true, {
                $0.setBuffer(samples, offset: 0, index: 0)
                $0.setBuffer(partial, offset: 0, index: 1)
                $0.setBuffer(summary, offset: 0, index: 2)
                $0.setBytes(&cfg, length: MemoryLayout<Config>.stride, index: 3)
                $0.setBytes(&phase, length: 4, index: 4)
            }), encode("Merge", size: MTLSize(width: 4096, height: 3, depth: 1), {
                $0.setBuffer(partial, offset: 0, index: 0)
                $0.setBuffer(histogram, offset: 0, index: 1)
                $0.setBytes(&cfg, length: MemoryLayout<Config>.stride, index: 2)
            }), encode("Select", size: MTLSize(width: 1, height: 1, depth: 1), {
                $0.setBuffer(histogram, offset: 0, index: 0)
                $0.setBuffer(summary, offset: 0, index: 1)
                $0.setBytes(&cfg, length: MemoryLayout<Config>.stride, index: 2)
                $0.setBytes(&phase, length: 4, index: 3)
            }) else { return nil }
        }
        guard encode("Moments", size: MTLSize(width: groups, height: 1, depth: 1), {
            $0.setBuffer(samples, offset: 0, index: 0)
            $0.setBuffer(moments, offset: 0, index: 1)
            $0.setBuffer(summary, offset: 0, index: 2)
            $0.setBytes(&cfg, length: MemoryLayout<Config>.stride, index: 3)
        }), encode("Fit", size: MTLSize(width: 1, height: 1, depth: 1), {
            $0.setBuffer(moments, offset: 0, index: 0)
            $0.setBuffer(summary, offset: 0, index: 1)
            $0.setBytes(&cfg, length: MemoryLayout<Config>.stride, index: 2)
        }) else { return nil }
        command.commit()
        await command.completed()
        context.trace.record("metering", since: stageStart, device: context.device, command: command)
        guard command.status == .completed else {
            context.log("Negative metering GPU failed: \(command.error?.localizedDescription ?? "unknown")", level: .error)
            return nil
        }
        var result = summary.contents().load(as: NegativeMeteringResult.self)
        if let detectedBase {
            result.base = detectedBase
        } else if !autoBase {
            result.base = manual.base
            result.base.w = 1
        }
        withUnsafeBytes(of: &result) { summary.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        let output = NegativeMeteringOutput(lease: summaryLease, result: result, gpuSeconds: command.gpuEndTime - command.gpuStartTime)
        computationCount += 1
        if cache[key] == nil { order.append(key) }
        cache[key] = output
        if order.count > 4 { cache.removeValue(forKey: order.removeFirst()) }
        return output
    }
}
