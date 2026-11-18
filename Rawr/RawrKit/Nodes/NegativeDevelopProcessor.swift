import Foundation
import Metal

/// Fused density, per-layer normalization and positive print response.
/// The only image output is a GPU texture; Preview/Export owns readback.
public final class NegativeDevelopProcessor: MetalNodeProcessor {
    private let meter: NegativeMetering
    private let pipeline: MTLComputePipelineState?

    public init(context: ProcessingContext) {
        meter = NegativeMetering(context: context)
        if let function = context.shaderLibrary?.makeFunction(name: "negativeDevelop") {
            pipeline = try? context.device.makeComputePipelineState(function: function)
        } else {
            pipeline = nil
        }
        super.init(nodeType: .negativeDevelop)
    }

    override public func process(inputs: [String: ImageData], node: NodeData, context: ProcessingContext) async -> [String: ImageData]? {
        guard let input = inputs["Input"], input.metadata.domain == .linearTransmittance,
              input.texture.pixelFormat == .rgba32Float,
              var parameters = NegativeDevelopParameters(node.parameters), let pipeline else {
            context.log("Negative Develop requires float32 linear input and valid manual calibration", level: .error)
            return nil
        }
        guard let statistics = await meter.analyze(input, parameters: node.parameters) else {
            context.log("Negative metering unavailable", level: .error)
            return nil
        }
        await MainActor.run { context.logger?.negativeStatistics[node.id] = statistics.result }
        var automatic = SIMD4<UInt32>(node.parameters["autoBase"] == 1 ? 1 : 0,
            node.parameters["autoEndpoints"] == 1 ? 1 : 0, node.parameters["autoBalance"] == 1 ? 1 : 0, 0)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float,
            width: input.texture.width, height: input.texture.height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let texture = context.device.makeTexture(descriptor: descriptor),
              let command = context.commandQueue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder() else { return nil }
        command.label = "Negative Develop: density, normalize, print"
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(input.texture, index: 0)
        encoder.setTexture(texture, index: 1)
        encoder.setBytes(&parameters, length: MemoryLayout<NegativeDevelopParameters>.stride, index: 0)
        encoder.setBuffer(statistics.buffer, offset: 0, index: 1)
        encoder.setBytes(&automatic, length: MemoryLayout<SIMD4<UInt32>>.stride, index: 2)
        let width = pipeline.threadExecutionWidth
        let height = min(8, pipeline.maxTotalThreadsPerThreadgroup / width)
        encoder.dispatchThreads(MTLSize(width: texture.width, height: texture.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1))
        encoder.endEncoding()
        command.commit()
        await command.completed()
        guard command.status == .completed else {
            context.log("Negative Develop GPU failed: \(command.error?.localizedDescription ?? "unknown error")", level: .error)
            return nil
        }
        var metadata = input.metadata
        metadata.domain = .positiveLinear
        return ["Output": ImageData(texture: texture, metadata: metadata)]
    }
}
