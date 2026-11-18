import Foundation
import Metal

// MARK: - Sharpening Processor

/// Applies advanced sharpening with multiple algorithms using Metal compute shader
public class SharpeningProcessor: MetalNodeProcessor {
    private let pipelineState: MTLComputePipelineState

    public init(context: ProcessingContext) {
        // Load the Metal shader
        guard let pipeline = context.resources.pipeline("advancedSharpening") else {
            fatalError("Failed to create sharpening compute pipeline")
        }

        self.pipelineState = pipeline
        super.init(nodeType: .sharpening)
    }

    override public func process(inputs: [String: ImageData], node: NodeData, context: ProcessingContext) async -> [String: ImageData]? {
        let stageStart = ProcessInfo.processInfo.systemUptime
        guard let inputData = inputs["Input"] else {
            context.log("No input image for sharpening", level: .error)
            return nil
        }

        // Read parameters from node, with fallback to defaults
        let algorithm: Int32 = Int32(node.parameters["algorithm"] ?? 0.0)
        let strength: Float = Float(node.parameters["strength"] ?? 1.0)
        let radius: Float = Float(node.parameters["radius"] ?? 1.0)
        let iterations: Int32 = Int32(node.parameters["iterations"] ?? 3.0)

        let algorithmName = algorithm == 0 ? "Default" : "Detail-max"
        context.log("Applying \(algorithmName) sharpening: strength=\(strength), radius=\(radius), iterations=\(iterations)")

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

        // Pass parameters as buffers
        var algorithmValue = algorithm
        var strengthValue = strength
        var radiusValue = radius
        var iterationsValue = iterations

        computeEncoder.setBytes(&algorithmValue, length: MemoryLayout<Int32>.size, index: 0)
        computeEncoder.setBytes(&strengthValue, length: MemoryLayout<Float>.size, index: 1)
        computeEncoder.setBytes(&radiusValue, length: MemoryLayout<Float>.size, index: 2)
        computeEncoder.setBytes(&iterationsValue, length: MemoryLayout<Int32>.size, index: 3)

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
            context.log("Sharpening GPU failed", level: .error)
            return nil
        }
        let outputData = ImageData(lease: outputLease, metadata: inputData.metadata)

        context.log("Sharpening completed successfully")
        return ["Output": outputData]
    }
}
