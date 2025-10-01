import Foundation
import Metal

// MARK: - Denoise Processor

/// Applies bilateral filter denoising using Metal compute shader
public class DenoiseProcessor: MetalNodeProcessor {
    private let pipelineState: MTLComputePipelineState

    public init(context: ProcessingContext) {
        // Load the Metal shader
        guard let library = context.device.makeDefaultLibrary(),
              let kernelFunction = library.makeFunction(name: "bilateralDenoise"),
              let pipeline = try? context.device.makeComputePipelineState(function: kernelFunction) else {
            fatalError("Failed to create denoise compute pipeline")
        }

        self.pipelineState = pipeline
        super.init(nodeType: .denoise)
    }

    override public func process(inputs: [String: ImageData], node: NodeData, context: ProcessingContext) async -> [String: ImageData]? {
        guard let inputData = inputs["Input"] else {
            context.log("No input image for denoising", level: .error)
            return nil
        }

        // Read parameters from node, with fallback to defaults
        let strength: Float = Float(node.parameters["strength"] ?? 1.0)
        let colorSigma: Float = Float(node.parameters["colorSigma"] ?? 0.2)

        context.log("Applying bilateral denoising: strength=\(strength), colorSigma=\(colorSigma)")

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

        // Pass parameters as buffer
        var strengthValue = strength
        var colorSigmaValue = colorSigma
        computeEncoder.setBytes(&strengthValue, length: MemoryLayout<Float>.size, index: 0)
        computeEncoder.setBytes(&colorSigmaValue, length: MemoryLayout<Float>.size, index: 1)

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

        context.log("Denoising completed successfully")
        return ["Output": outputData]
    }
}
