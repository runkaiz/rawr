import Foundation
import Metal

// MARK: - Sharpening Processor

/// Applies advanced sharpening with multiple algorithms using Metal compute shader
public class SharpeningProcessor: MetalNodeProcessor {
    private let pipelineState: MTLComputePipelineState

    public init(context: ProcessingContext) {
        // Load the Metal shader
        guard let library = context.device.makeDefaultLibrary(),
              let kernelFunction = library.makeFunction(name: "advancedSharpening"),
              let pipeline = try? context.device.makeComputePipelineState(function: kernelFunction) else {
            fatalError("Failed to create sharpening compute pipeline")
        }

        self.pipelineState = pipeline
        super.init(nodeType: .sharpening)
    }

    override public func process(inputs: [String: ImageData], node: NodeData, context: ProcessingContext) async -> [String: ImageData]? {
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

        guard let outputTexture = context.device.makeTexture(descriptor: textureDescriptor) else {
            context.log("Failed to create output texture", level: .error)
            return nil
        }

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

        // Convert output texture to CGImage
        guard let cgImage = createCGImage(from: outputTexture) else {
            context.log("Failed to create CGImage from output texture", level: .error)
            return nil
        }

        let outputData = ImageData(
            texture: outputTexture,
            cgImage: cgImage,
            metadata: inputData.metadata
        )

        context.log("Sharpening completed successfully")
        return ["Output": outputData]
    }
}
