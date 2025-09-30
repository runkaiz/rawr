import Foundation
import Metal

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

        // Preview just passes through the input
        return ["Output": inputData]
    }
}