import Foundation
import Metal

// MARK: - Inversion Processor

/// Inverts image colors using Metal compute shader
public class InversionProcessor: MetalNodeProcessor {
    private let pipelineState: MTLComputePipelineState

    public init(context: ProcessingContext) {
        // Load the Metal shader
        guard let pipeline = context.resources.pipeline("invertImage") else {
            fatalError("Failed to create inversion compute pipeline")
        }

        self.pipelineState = pipeline
        super.init(nodeType: .inversion)
    }

    override public func process(inputs: [String: ImageData], node: NodeData, context: ProcessingContext) async -> [String: ImageData]? {
        let stageStart = ProcessInfo.processInfo.systemUptime
        guard let inputData = inputs["Input"] else {
            context.log("No input image for inversion", level: .error)
            return nil
        }

        context.log("Applying inversion (film negative processing)")

        let inputTexture = inputData.texture

        guard let outputLease = context.resources.texture(format: inputTexture.pixelFormat,
            width: inputTexture.width, height: inputTexture.height) else {
            context.log("Failed to create output texture", level: .error)
            return nil
        }

        let outputTexture = outputLease.texture

        // Execute Metal compute shader
        guard let commandBuffer = context.commandQueue.makeCommandBuffer(),
              let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            context.log("Failed to create Metal command buffer/encoder", level: .error)
            return nil
        }

        computeEncoder.setComputePipelineState(pipelineState)
        computeEncoder.setTexture(inputTexture, index: 0)
        computeEncoder.setTexture(outputTexture, index: 1)

        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(
            width: (inputTexture.width + threadGroupSize.width - 1) / threadGroupSize.width,
            height: (inputTexture.height + threadGroupSize.height - 1) / threadGroupSize.height,
            depth: 1
        )

        computeEncoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        computeEncoder.endEncoding()
        commandBuffer.commit()
        await commandBuffer.completed()
        context.trace.record(node.type.rawValue, since: stageStart, device: context.device, command: commandBuffer)

        guard commandBuffer.status == .completed else {
            context.log("Inversion GPU failed", level: .error)
            return nil
        }
        var metadata = inputData.metadata
        metadata.legacyFloatOutput = true
        let outputData = ImageData(lease: outputLease, metadata: metadata)

        context.log("Inversion completed successfully")
        return ["Output": outputData]
    }
}
