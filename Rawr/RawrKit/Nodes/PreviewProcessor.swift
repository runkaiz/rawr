import Foundation
import Metal
import CoreImage

// MARK: - Preview Processor

/// Terminal node that collects processed images for display
public class PreviewProcessor: MetalNodeProcessor {
    public init() {
        super.init(nodeType: .preview)
    }

    override public func process(inputs: [String: ImageData], node: NodeData, context: ProcessingContext) async -> [String: ImageData]? {
        guard let inputData = inputs["Input"] else {
            context.log("No input image for preview", level: .warning)
            return nil
        }

        context.log("Preview node processed: \(inputData.metadata.width)x\(inputData.metadata.height)")

        // A CPU image is created only at this terminal boundary for GPU-only paths.
        let displayMask = context.logger?.isFullResolutionMode == true ? nil : inputData.metadata.dustMaskPreview
        guard inputData.cgImage == nil || displayMask != nil else { return ["Output": inputData] }
        let limit = context.logger.map { $0.isFullResolutionMode ? nil : $0.maxPreviewDimension } ?? nil
        let displayTexture = displayMask ?? inputData.texture
        guard let image = NegativeImageIO.boundaryImage(displayTexture, context: context.linearCIContext, maxDimension: limit) else {
            context.log("Failed to render terminal image", level: .error)
            return nil
        }
        return ["Output": ImageData(texture: inputData.texture, cgImage: image, metadata: inputData.metadata)]
    }
}
