import Foundation
import Metal

// MARK: - Combination Processor

/// Combines two images into one using luminance-based blending
public class CombinationProcessor: MetalNodeProcessor {
    private let pipelineState: MTLComputePipelineState

    public init(context: ProcessingContext) {
        // Load the Metal shader
        guard let library = context.device.makeDefaultLibrary(),
              let kernelFunction = library.makeFunction(name: "combineImages"),
              let pipeline = try? context.device.makeComputePipelineState(function: kernelFunction) else {
            fatalError("Failed to create combination compute pipeline")
        }

        self.pipelineState = pipeline
        super.init(nodeType: .combination)
    }

    override public func process(inputs: [String: ImageData], node: NodeData, context: ProcessingContext) async -> [String: ImageData]? {
        guard let inputA = inputs["Input A"] else {
            context.log("No Input A for combination", level: .error)
            return nil
        }

        guard let inputB = inputs["Input B"] else {
            context.log("No Input B for combination", level: .error)
            return nil
        }

        context.log("Combining two images")

        let textureA = inputA.texture
        let textureB = inputB.texture

        // Verify textures have same dimensions
        if textureA.width != textureB.width || textureA.height != textureB.height {
            context.log("Input images must have same dimensions", level: .error)
            return nil
        }

        // Create output texture
        let textureDescriptor = MTLTextureDescriptor()
        textureDescriptor.pixelFormat = textureA.pixelFormat
        textureDescriptor.width = textureA.width
        textureDescriptor.height = textureA.height
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
        computeEncoder.setTexture(textureA, index: 0)
        computeEncoder.setTexture(textureB, index: 1)
        computeEncoder.setTexture(outputTexture, index: 2)

        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(
            width: (textureA.width + threadGroupSize.width - 1) / threadGroupSize.width,
            height: (textureA.height + threadGroupSize.height - 1) / threadGroupSize.height,
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
            metadata: inputA.metadata // Use metadata from first input
        )

        context.log("Combination completed successfully")
        return ["Output": outputData]
    }
}
