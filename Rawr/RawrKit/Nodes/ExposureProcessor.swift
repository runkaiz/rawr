import Foundation
import Metal

// MARK: - Exposure Processor

/// Adjusts image exposure using Metal compute shader
public class ExposureProcessor: MetalNodeProcessor {
    private let pipelineState: MTLComputePipelineState

    public init(context: ProcessingContext) {
        // Load the Metal shader
        guard let pipeline = context.resources.pipeline("adjustExposure") else {
            fatalError("Failed to create exposure compute pipeline")
        }

        self.pipelineState = pipeline
        super.init(nodeType: .exposure)
    }

    override public func process(inputs: [String: ImageData], node: NodeData, context: ProcessingContext) async -> [String: ImageData]? {
        let stageStart = ProcessInfo.processInfo.systemUptime
        guard let inputData = inputs["Input"] else {
            context.log("No input image for exposure adjustment", level: .error)
            return nil
        }

        // Read exposure value from node parameters, with fallback to default
        let exposureStops: Float = Float(node.parameters["stops"] ?? 0.0)

        context.log("Applying exposure adjustment: \(exposureStops) stops")

        let inputTexture = inputData.texture

        // Create output texture
        let textureDescriptor = MTLTextureDescriptor()
        textureDescriptor.pixelFormat = inputTexture.pixelFormat
        textureDescriptor.width = inputTexture.width
        textureDescriptor.height = inputTexture.height
        textureDescriptor.usage = [.shaderRead, .shaderWrite]
        textureDescriptor.storageMode = .private

        guard let outputLease = context.resources.texture(format: textureDescriptor.pixelFormat,
            width: textureDescriptor.width, height: textureDescriptor.height) else {
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

        // Pass exposure stops as buffer parameter
        var exposureValue = exposureStops
        computeEncoder.setBytes(&exposureValue, length: MemoryLayout<Float>.size, index: 0)

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
            context.log("Exposure GPU failed", level: .error)
            return nil
        }
        let outputData = ImageData(lease: outputLease, metadata: inputData.metadata)

        context.log("Exposure adjustment completed successfully")
        return ["Output": outputData]
    }
}
