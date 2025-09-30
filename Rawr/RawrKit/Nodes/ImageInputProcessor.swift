import Foundation
import Metal
import CoreImage
import ImageIO
import UniformTypeIdentifiers

// MARK: - Image Input Processor

/// Loads images from disk
public class ImageInputProcessor: MetalNodeProcessor {
    public init() {
        super.init(nodeType: .imageInput)
    }

    override public func canProcess(inputs: [String: ImageData], node: NodeData) -> Bool {
        // Image input nodes don't need inputs, but they do need a URL
        return node.imageURL != nil || node.imageBookmark != nil
    }

    override public func process(inputs: [String: ImageData], node: NodeData, context: ProcessingContext) async -> [String: ImageData]? {
        context.log("Loading image from Image Input node")

        // Determine URL to load from
        let urlToLoad: URL?
        if let bookmarkData = node.imageBookmark {
            // Resolve bookmark
            urlToLoad = resolveBookmark(bookmarkData, context: context)
        } else {
            urlToLoad = node.imageURL
        }

        guard let url = urlToLoad else {
            context.log("No URL or bookmark available for Image Input node", level: .error)
            return nil
        }

        // Use RawrKit's cached source image loading which handles preview scaling
        guard let cgImage = await context.logger?.getCachedSourceImage(for: url) else {
            context.log("Failed to load image from URL", level: .error)
            return nil
        }

        // Convert to Metal texture
        guard let texture = createTexture(from: cgImage, device: context.device) else {
            context.log("Failed to create Metal texture from image", level: .error)
            return nil
        }

        let metadata = ImageMetadata(
            width: cgImage.width,
            height: cgImage.height,
            colorSpace: cgImage.colorSpace
        )

        let imageData = ImageData(texture: texture, cgImage: cgImage, metadata: metadata)
        context.log("Image loaded successfully: \(cgImage.width)x\(cgImage.height)")

        return ["Image": imageData]
    }

    private func resolveBookmark(_ bookmarkData: Data, context: ProcessingContext) -> URL? {
        do {
            var isStale = false
            let resolvedURL = try URL(resolvingBookmarkData: bookmarkData, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
            if isStale {
                context.log("Security bookmark is stale, file may have moved", level: .warning)
            }
            return resolvedURL
        } catch {
            context.log("Failed to resolve bookmark: \(error.localizedDescription)", level: .error)
            return nil
        }
    }
}