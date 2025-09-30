import Foundation
import Metal

// MARK: - Gamma Processor

/// Applies gamma correction using Metal compute shader
public class GammaProcessor: MetalNodeProcessor {
    private let pipelineState: MTLComputePipelineState
    private weak var context: ProcessingContext?

    public init(context: ProcessingContext) {
        self.context = context

        // Load the Metal shader
        guard let library = context.device.makeDefaultLibrary(),
              let kernelFunction = library.makeFunction(name: "applyGamma"),
              let pipeline = try? context.device.makeComputePipelineState(function: kernelFunction)
        else {
            fatalError("Failed to create gamma compute pipeline")
        }

        pipelineState = pipeline
        super.init(nodeType: .gamma)
    }

    override public func process(inputs: [String: ImageData], node: NodeData, context: ProcessingContext) async -> [String: ImageData]? {
        guard let inputData = inputs["Input"] else {
            context.log("No input image for gamma correction", level: .error)
            return nil
        }

        // Read gamma value from node parameters, with fallback to default
        let gamma: Float = Float(node.parameters["gamma"] ?? 2.2)

        context.log("Applying gamma correction: \(gamma)")

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

        context.log("Gamma correction completed successfully")
        return ["Output": outputData]
    }
}
