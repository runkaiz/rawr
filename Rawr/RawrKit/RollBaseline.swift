import Foundation
import Metal

/// Document-owned calibration. Version is the algorithm/schema version, revision
/// identifies a particular measurement. Re-measure explicitly after source edits.
public struct RollBaseline: Codable, Equatable, Hashable, Sendable {
    public var version = 1
    public var revision = UUID()
    public var folder: URL
    public var calibration: [String: Double]
    public var confidence: Float
    public var frames: [RollFrame]

    /// Present saved GPU results using the same controls/locking path as a
    /// single frame. This only unpacks serialized values; it does not re-meter.
    var statistics: NegativeMeteringResult? {
        guard isSupported, let p = NegativeDevelopParameters(calibration) else { return nil }
        var r = NegativeMeteringResult()
        r.base = p.base; r.base.w = confidence
        r.low = p.low; r.low.w = confidence
        r.high = p.high; r.high.w = confidence
        r.offset = p.balance; r.offset.w = calibration["autoBalance"] == 1 ? 0 : confidence
        r.slope = p.slope
        return r
    }

    /// Groups without shared evidence continue to display the current frame's
    /// estimate and confidence, matching the parameters used by development.
    func displayStatistics(frame: NegativeMeteringResult?) -> NegativeMeteringResult? {
        guard var result = statistics else { return frame }
        guard let frame else { return result }
        if calibration["autoBase"] == 1 { result.base = frame.base }
        if calibration["autoEndpoints"] == 1 { result.low = frame.low; result.high = frame.high }
        if calibration["autoBalance"] == 1 { result.offset = frame.offset; result.slope = frame.slope }
        return result
    }

    var isSupported: Bool {
        version == 1 && confidence.isFinite && (0...1).contains(confidence) &&
        NegativeDevelopParameters(calibration) != nil &&
        Set(frames.map(\.name)).count == frames.count &&
        frames.allSatisfy { $0.densityShift.isFinite && $0.exposure.isFinite && (-8...8).contains($0.exposure) }
    }

    /// Manual group switches retain priority. A frame override is a sparse set
    /// of manual values; setting any group disables its automatic switch.
    func parameters(for url: URL, node: [String: Double]) -> [String: Double]? {
        guard isSupported, url.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path,
              let frame = frames.first(where: { $0.name == url.lastPathComponent }), frame.matches(url) else { return nil }
        var result = node
        result["rollRelativeDensity"] = frame.optOut ? 0 : 1
        if !frame.optOut {
            for group in ["Base", "Endpoints", "Balance"] where node["auto" + group] == 1 {
                guard calibration["auto" + group] != 1 else { continue }
                for key in Self.keys(group) { result[key] = calibration[key] }
                result["auto" + group] = 0
                if group == "Base" { result["meterBaseConfidence"] = Double(confidence) }
            }
            // Density alignment precedes print exposure. Excluded frames receive
            // the baseline without an unreliable automatic alignment.
            result["rollDensityShift"] = Double(frame.densityShift)
        }
        result["exposure"] = (node["exposure"] ?? 0) + frame.exposure
        for group in ["Base", "Endpoints", "Balance"] where Self.keys(group).contains(where: { frame.overrides[$0] != nil }) {
            result["auto" + group] = 0
        }
        result.merge(frame.overrides) { _, value in value }
        return NegativeDevelopParameters(result) == nil ? nil : result
    }

    static func keys(_ group: String) -> [String] {
        switch group {
        case "Base": return ["baseR", "baseG", "baseB"]
        case "Endpoints": return ["lowR", "lowG", "lowB", "highR", "highG", "highB"]
        default: return ["balanceR", "balanceG", "balanceB", "slopeR", "slopeG", "slopeB"]
        }
    }
}

public struct RollFrame: Codable, Equatable, Hashable, Sendable {
    public var name: String
    public var size: Int64
    public var modified: Double
    public var included: Bool
    public var densityShift: Float
    public var exposure: Double = 0
    public var optOut = false
    public var overrides: [String: Double] = [:]

    init(url: URL, included: Bool, densityShift: Float) throws {
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = values[.size] as? NSNumber, let modified = values[.modificationDate] as? Date else { throw CocoaError(.fileReadUnknown) }
        self.name = url.lastPathComponent
        self.size = size.int64Value
        self.modified = modified.timeIntervalSince1970
        self.included = included
        self.densityShift = densityShift
    }

    func matches(_ url: URL) -> Bool {
        guard let values = try? FileManager.default.attributesOfItem(atPath: url.path) else { return false }
        return (values[.size] as? NSNumber)?.int64Value == size &&
            (values[.modificationDate] as? Date)?.timeIntervalSince1970 == modified
    }
}

/// Only compact summaries cross the CPU boundary. Selection, robust rejection,
/// medians and density alignment execute on Metal, including across frames.
struct RollReduction {
    let statistics: NegativeMeteringResult
    let frames: [SIMD4<Float>]
    let gpuSeconds: Double

    /// Base is a roll-wide calibration group. A validated strip may live in a
    /// different frame from the three or more scenes supporting the endpoints.
    static func baseReference(_ summaries: [NegativeMeteringResult], context: ProcessingContext) async -> SIMD4<Float>? {
        guard !summaries.isEmpty, summaries.count <= 4096,
              let pipeline = context.resources.pipeline("negativeRollBase"),
              let input = summaries.withUnsafeBytes({ bytes in
                  context.device.makeBuffer(bytes:bytes.baseAddress!,length:bytes.count,options:.storageModeShared)
              }),
              let scratch = context.device.makeBuffer(length:summaries.count*4,options:.storageModePrivate),
              let flags = context.device.makeBuffer(length:summaries.count*4,options:.storageModePrivate),
              let output = context.device.makeBuffer(length:16,options:.storageModeShared),
              let command = context.commandQueue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder() else { return nil }
        var count = UInt32(summaries.count)
        encoder.setComputePipelineState(pipeline)
        for (i,b) in [input,scratch,flags,output].enumerated() { encoder.setBuffer(b,offset:0,index:i) }
        encoder.setBytes(&count,length:4,index:4)
        encoder.dispatchThreads(MTLSize(width:1,height:1,depth:1),threadsPerThreadgroup:MTLSize(width:1,height:1,depth:1))
        encoder.endEncoding();command.commit();await command.completed()
        guard command.status == .completed else { return nil }
        return output.contents().load(as:SIMD4<Float>.self)
    }

    static func reduce(_ summaries: [NegativeMeteringResult], context: ProcessingContext) async -> RollReduction? {
        let start = ProcessInfo.processInfo.systemUptime
        guard !summaries.isEmpty, summaries.count <= 4096,
              let pipeline = context.resources.pipeline("negativeRollReduce") else { return nil }
        let device = context.device, count = summaries.count
        guard let input = summaries.withUnsafeBytes({ bytes in
                  device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
              }),
              let scratch = device.makeBuffer(length: count * 4, options: .storageModePrivate),
              let flags = device.makeBuffer(length: count * 16, options: .storageModeShared),
              let output = device.makeBuffer(length: MemoryLayout<NegativeMeteringResult>.stride, options: .storageModeShared),
              let command = context.commandQueue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder() else { return nil }
        var n = UInt32(count)
        encoder.setComputePipelineState(pipeline)
        for (i, buffer) in [input, scratch, flags, output].enumerated() { encoder.setBuffer(buffer, offset: 0, index: i) }
        encoder.setBytes(&n, length: 4, index: 4)
        encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        encoder.endEncoding()
        command.commit()
        await command.completed()
        context.trace.record("roll-reduction", since: start, device: context.device, command: command)
        guard command.status == .completed else { return nil }
        return RollReduction(statistics: output.contents().load(as: NegativeMeteringResult.self),
            frames: Array(UnsafeBufferPointer(start: flags.contents().assumingMemoryBound(to: SIMD4<Float>.self), count: count)),
            gpuSeconds: command.gpuEndTime - command.gpuStartTime)
    }
}
