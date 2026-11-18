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
        let stageStart = ProcessInfo.processInfo.systemUptime
        defer { context.trace.record("preview", since: stageStart, device: context.device) }
        guard let inputData = inputs["Input"] else {
            context.log("No input image for preview", level: .warning)
            return nil
        }

        context.log("Preview node processed: \(inputData.metadata.width)x\(inputData.metadata.height)")

        // A CPU image is created only at this terminal boundary for GPU-only paths.
        if context.logger?.isFullResolutionMode == true { return ["Output": inputData] }
        let displayMask = context.logger?.isFullResolutionMode == true ? nil : inputData.metadata.dustMaskPreview
        guard inputData.cgImage == nil || displayMask != nil else { return ["Output": inputData] }
        let limit = context.logger.map { $0.isFullResolutionMode ? nil : $0.maxPreviewDimension } ?? nil
        let displayTexture = displayMask ?? inputData.texture
        guard let image = NegativeImageIO.boundaryImage(displayTexture, context: context.linearCIContext, maxDimension: limit, legacyFloat: displayMask == nil && inputData.metadata.legacyFloatOutput) else {
            context.log("Failed to render terminal image", level: .error)
            return nil
        }
        var output = inputData
        output.cgImage = image
        return ["Output": output]
    }
}
