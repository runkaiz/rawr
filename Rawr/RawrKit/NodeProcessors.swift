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

        // Load the image
        guard let cgImage = await loadImage(from: url, context: context) else {
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

    private func loadImage(from url: URL, context: ProcessingContext) async -> CGImage? {
        let gotAccess = url.startAccessingSecurityScopedResource()
        defer {
            if gotAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let imageData = try Data(contentsOf: url)
            context.log("Loaded file data: \(imageData.count) bytes")

            guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil) else {
                context.log("Failed to create image source from data", level: .error)
                return nil
            }

            let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
            let orientation = properties?[kCGImagePropertyOrientation] as? UInt32 ?? CGImagePropertyOrientation.up.rawValue

            let options: [CFString: Any] = [
                kCGImageSourceShouldAllowFloat: true,
                kCGImageSourceShouldCache: false,
                kCGImageSourceCreateThumbnailFromImageAlways: false
            ]

            if let rawCGImage = CGImageSourceCreateImageAtIndex(imageSource, 0, options as CFDictionary) {
                // Apply orientation if needed
                if orientation != CGImagePropertyOrientation.up.rawValue {
                    context.log("Applying orientation correction")
                    let ciImage = CIImage(cgImage: rawCGImage)
                    let orientedCIImage = ciImage.oriented(forExifOrientation: Int32(orientation))

                    if let correctedCGImage = context.ciContext.createCGImage(orientedCIImage, from: orientedCIImage.extent) {
                        return correctedCGImage
                    }
                }
                return rawCGImage
            } else {
                // Try Core Image as fallback
                guard let ciImage = CIImage(data: imageData, options: [.applyOrientationProperty: true]) else {
                    context.log("Failed to create CIImage from data", level: .error)
                    return nil
                }

                return context.ciContext.createCGImage(ciImage, from: ciImage.extent)
            }
        } catch {
            context.log("Failed to read file: \(error.localizedDescription)", level: .error)
            return nil
        }
    }
}

// MARK: - Inversion Processor

/// Inverts image colors using Metal compute shader
public class InversionProcessor: MetalNodeProcessor {
    private let pipelineState: MTLComputePipelineState
    private weak var context: ProcessingContext?

    public init(context: ProcessingContext) {
        self.context = context

        // Load the Metal shader
        guard let library = context.device.makeDefaultLibrary(),
              let kernelFunction = library.makeFunction(name: "invertImage"),
              let pipeline = try? context.device.makeComputePipelineState(function: kernelFunction) else {
            fatalError("Failed to create inversion compute pipeline")
        }

        self.pipelineState = pipeline
        super.init(nodeType: .inversion)
    }

    override public func process(inputs: [String: ImageData], node: NodeData, context: ProcessingContext) async -> [String: ImageData]? {
        guard let inputData = inputs["Input"] else {
            context.log("No input image for inversion", level: .error)
            return nil
        }

        context.log("Applying inversion (film negative processing)")

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

        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(
            width: (inputTexture.width + threadGroupSize.width - 1) / threadGroupSize.width,
            height: (inputTexture.height + threadGroupSize.height - 1) / threadGroupSize.height,
            depth: 1
        )

        computeEncoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        computeEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

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

        context.log("Inversion completed successfully")
        return ["Output": outputData]
    }
}

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