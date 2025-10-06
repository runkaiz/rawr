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

        // Load the image directly here while we have folder access, rather than using getCachedSourceImage
        // which would try to access the file independently
        guard let cgImage = loadImageFromFolder(url: selectedImageURL, context: context) else {
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

    /// Load an image from a file within an already-accessed folder
    /// This assumes the parent folder's security-scoped access is already active
    /// Images are scaled to preview resolution (1920px max dimension) unless in full resolution export mode
    private func loadImageFromFolder(url: URL, context: ProcessingContext) -> CGImage? {
        do {
            // We're relying on the parent folder's security-scoped access
            // Don't call startAccessingSecurityScopedResource on the individual file
            let imageData = try Data(contentsOf: url)
            guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil) else {
                return nil
            }

            // Check for orientation metadata
            let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
            let orientation = properties?[kCGImagePropertyOrientation] as? UInt32 ?? CGImagePropertyOrientation.up.rawValue

            let options: [CFString: Any] = [
                kCGImageSourceShouldAllowFloat: true,
                kCGImageSourceShouldCache: false
            ]

            guard let rawImage = CGImageSourceCreateImageAtIndex(imageSource, 0, options as CFDictionary) else {
                return nil
            }

            // Apply orientation correction if needed
            let orientedImage: CGImage
            if orientation != CGImagePropertyOrientation.up.rawValue {
                let ciImage = CIImage(cgImage: rawImage)
                let orientedCIImage = ciImage.oriented(forExifOrientation: Int32(orientation))

                if let correctedImage = context.ciContext.createCGImage(orientedCIImage, from: orientedCIImage.extent) {
                    orientedImage = correctedImage
                } else {
                    orientedImage = rawImage
                }
            } else {
                orientedImage = rawImage
            }

            // Scale to preview resolution unless in full resolution mode
            let finalImage: CGImage
            if context.logger?.isFullResolutionMode == true {
                finalImage = orientedImage
                context.log("Loaded full resolution image from folder: \(finalImage.width)x\(finalImage.height)")
            } else {
                finalImage = scaleToPreviewResolution(orientedImage, context: context)
                context.log("Loaded preview resolution image from folder: \(finalImage.width)x\(finalImage.height) (scaled from \(orientedImage.width)x\(orientedImage.height))")
            }

            return finalImage
        } catch {
            context.log("Failed to load image from folder: \(error.localizedDescription)", level: .error)
            return nil
        }
    }

    /// Scale an image to preview resolution (1920px max dimension)
    private func scaleToPreviewResolution(_ image: CGImage, context: ProcessingContext) -> CGImage {
        let maxPreviewDimension: CGFloat = 1920
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)

        // Only scale if image exceeds max dimension
        guard max(width, height) > maxPreviewDimension else {
            return image
        }

        let scale = maxPreviewDimension / max(width, height)
        let ciImage = CIImage(cgImage: image)
        let filter = CIFilter(name: "CILanczosScaleTransform")!
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(scale, forKey: kCIInputScaleKey)
        filter.setValue(1.0, forKey: kCIInputAspectRatioKey)

        guard let outputImage = filter.outputImage,
              let scaledImage = context.ciContext.createCGImage(outputImage, from: outputImage.extent) else {
            return image
        }

        return scaledImage
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
