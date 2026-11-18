import Foundation
import Metal
import CoreImage
import ImageIO
import UniformTypeIdentifiers

// MARK: - Folder Input Processor

/// Loads images from a folder, allowing selection of a specific image for preview
public class FolderInputProcessor: MetalNodeProcessor {
    public init() {
        super.init(nodeType: .folderInput)
    }

    override public func canProcess(inputs: [String: ImageData], node: NodeData) -> Bool {
        // Folder input nodes don't need inputs, but they do need a folder URL
        return node.imageURL != nil || node.imageBookmark != nil
    }

    override public func process(inputs: [String: ImageData], node: NodeData, context: ProcessingContext) async -> [String: ImageData]? {
        context.log("Loading image from Folder Input node")

        // Determine folder URL to load from
        let folderURL: URL?
        if let bookmarkData = node.imageBookmark {
            // Resolve bookmark
            folderURL = resolveBookmark(bookmarkData, context: context)
        } else {
            folderURL = node.imageURL
        }

        guard let folder = folderURL else {
            context.log("No folder URL or bookmark available for Folder Input node", level: .error)
            return nil
        }

        // Start security-scoped access to the folder and maintain it throughout
        let gotAccess = folder.startAccessingSecurityScopedResource()
        defer {
            if gotAccess {
                folder.stopAccessingSecurityScopedResource()
            }
        }

        // Get selected image index from parameters
        let selectedIndex = Int(node.parameters["selectedIndex"] ?? 0.0)

        // Get image URLs from folder via RawrKit
        guard let imageURLs = await context.logger?.scanFolderForImages(folderURL: folder) else {
            context.log("Failed to scan folder for images", level: .error)
            return nil
        }

        guard !imageURLs.isEmpty else {
            context.log("No images found in folder", level: .error)
            return nil
        }

        // Clamp selected index to valid range
        let validIndex = min(max(0, selectedIndex), imageURLs.count - 1)
        let selectedImageURL = imageURLs[validIndex]

        context.log("Loading image \(validIndex + 1) of \(imageURLs.count) from folder")

        if context.negativeInputIDs.contains(node.id) {
            guard let image = context.logger?.loadNegativeSource(at: selectedImageURL, context: context) else { return nil }
            return ["Image": image]
        }

        // Load the image directly here while we have folder access, rather than using getCachedSourceImage
        // which would try to access the file independently
        guard let cgImage = context.logger?.decodeSourceImage(at: selectedImageURL) else {
            context.log("Failed to load image from folder", level: .error)
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
                context.log("Security bookmark is stale, folder may have moved", level: .warning)
            }
            return resolvedURL
        } catch {
            context.log("Failed to resolve bookmark: \(error.localizedDescription)", level: .error)
            return nil
        }
    }
}
