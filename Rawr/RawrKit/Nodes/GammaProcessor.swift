import Foundation
import Metal

// MARK: - Gamma Processor

/// Applies gamma correction using Metal compute shader
public class GammaProcessor: MetalNodeProcessor {
    private let pipelineState: MTLComputePipelineState

    public init(context: ProcessingContext) {
        // Load the Metal shader
        guard let pipeline = context.resources.pipeline("applyGamma")
        else {
            fatalError("Failed to create gamma compute pipeline")
        }

        pipelineState = pipeline
        super.init(nodeType: .gamma)
    }

    override public func process(inputs: [String: ImageData], node: NodeData, context: ProcessingContext) async -> [String: ImageData]? {
        let stageStart = ProcessInfo.processInfo.systemUptime
        guard let inputData = inputs["Input"] else {
            context.log("No input image for gamma correction", level: .error)
            return nil
        }

        // Read gamma value from node parameters, with fallback to default
        let gamma: Float = Float(node.parameters["gamma"] ?? 2.2)

        context.log("Applying gamma correction: \(gamma)")

        let inputTexture = inputData.texture

        guard let outputLease = context.resources.texture(format: inputTexture.pixelFormat,
            width: inputTexture.width, height: inputTexture.height) else {
            context.log("Failed to create output texture", level: .error)
            return nil
        }

        let outputTexture = outputLease.texture

        // Execute Metal compute shader
        guard let commandBuffer = context.commandQueue.makeCommandBuffer(),
              let computeEncoder = commandBuffer.makeComputeCommandEncoder()
        else {
            context.log("Failed to create Metal command buffer/encoder", level: .error)
            return nil
        }

        computeEncoder.setComputePipelineState(pipelineState)
        computeEncoder.setTexture(inputTexture, index: 0)
        computeEncoder.setTexture(outputTexture, index: 1)

        // Pass gamma value as buffer parameter
        var gammaValue = gamma
        computeEncoder.setBytes(&gammaValue, length: MemoryLayout<Float>.size, index: 0)

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
            context.log("Gamma GPU failed", level: .error)
            return nil
        }
        let outputData = ImageData(lease: outputLease, metadata: inputData.metadata)

        context.log("Gamma correction completed successfully")
        return ["Output": outputData]
    }
}
