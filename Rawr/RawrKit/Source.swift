import Foundation
import SwiftUI
import Metal
import CoreImage
import ImageIO
import UniformTypeIdentifiers

public class RawrKit: ObservableObject {
    @Published public var isProcessing = false
    @Published public var logs: [LogEntry] = []
    @Published public var performance: PerformanceMetrics = PerformanceMetrics()
    @Published public var previewImage: CGImage?
    @Published public var processedPreviewImage: CGImage?

    private let device: MTLDevice?
    private let ciContext: CIContext
    private let commandQueue: MTLCommandQueue?

    // Preview resolution settings - all processing uses preview resolution for real-time editing
    public var maxPreviewDimension: CGFloat = 1920 // Default to 1920px for real-time editing
    private var isFullResolutionMode = false // Flag for export mode

    // Graph execution
    private var graphExecutor: GraphExecutor?
    private var executionTask: Task<Void, Never>?
    private var pendingNodeGraph: NodeGraph?

    // Internal storage for full resolution images (legacy support)
    private var currentImage: CGImage?
    private var processedImage: CGImage?

    // Source image cache to avoid reloading
    private var cachedSourceImage: CGImage?
    private var cachedSourceURL: URL?

    public init() {
        self.device = MTLCreateSystemDefaultDevice()

        if let device = device {
            self.ciContext = CIContext(mtlDevice: device)
            self.commandQueue = device.makeCommandQueue()

            // Initialize graph executor
            if let commandQueue = self.commandQueue {
                let context = ProcessingContext(
                    device: device,
                    commandQueue: commandQueue,
                    ciContext: self.ciContext,
                    logger: nil
                )
                self.graphExecutor = GraphExecutor(context: context)
                // Set logger reference after initialization
                context.logger = self
            }
        } else {
            self.ciContext = CIContext()
            self.commandQueue = nil
        }

        log("RawrKit initialized with Metal device: \(device?.name ?? "None")")
    }

    public func log(_ message: String, level: LogLevel = .info) {
        let entry = LogEntry(message: message, level: level, timestamp: Date())
        DispatchQueue.main.async {
            self.logs.append(entry)
        }
    }

    /// Creates a security-scoped bookmark for the given URL
    /// Call this after selecting a file through a file picker
    /// This is a static utility method that can be called without a RawrKit instance
    public static func createSecurityBookmark(for url: URL) -> Data? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let bookmarkData = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            return bookmarkData
        } catch {
            return nil
        }
    }

    /// Resolves a security-scoped bookmark to a URL with logging
    /// Returns nil if the bookmark cannot be resolved
    public func resolveBookmark(_ bookmarkData: Data) -> URL? {
        do {
            var isStale = false
            let resolvedURL = try URL(resolvingBookmarkData: bookmarkData, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
            if isStale {
                log("Security bookmark is stale, file may have moved", level: .warning)
            }
            return resolvedURL
        } catch {
            log("Failed to resolve bookmark: \(error.localizedDescription)", level: .error)
            return nil
        }
    }

    private func createPreview(from image: CGImage) -> CGImage? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)

        // Only create preview if image exceeds max dimension
        guard max(width, height) > maxPreviewDimension else {
            return image
        }

        let scale = maxPreviewDimension / max(width, height)
        let previewWidth = width * scale
        let previewHeight = height * scale

        let ciImage = CIImage(cgImage: image)
        let filter = CIFilter(name: "CILanczosScaleTransform")!
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(scale, forKey: kCIInputScaleKey)
        filter.setValue(1.0, forKey: kCIInputAspectRatioKey)

        guard let outputImage = filter.outputImage,
              let preview = ciContext.createCGImage(outputImage, from: outputImage.extent) else {
            return image
        }

        log("Created preview: \(Int(previewWidth))x\(Int(previewHeight)) from \(image.width)x\(image.height)")
        return preview
    }

    public func loadRawFile(from url: URL) async -> Bool {
        await MainActor.run {
            isProcessing = true
            performance.startTime = Date()
        }

        defer {
            Task { @MainActor in
                isProcessing = false
                performance.endTime = Date()
            }
        }

        log("Loading RAW file from: \(url.lastPathComponent)")

        // Handle security-scoped resource for sandboxed app
        let gotAccess = url.startAccessingSecurityScopedResource()

        // Ensure we stop accessing when done
        defer {
            if gotAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        // Try to load the file data directly first
        do {
            let imageData = try Data(contentsOf: url)
            log("Loaded file data: \(imageData.count) bytes")

            // Create image source from data instead of URL
            guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil) else {
                log("Failed to create image source from data", level: .error)
                return false
            }

            // Check for orientation metadata
            let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
            let orientation = properties?[kCGImagePropertyOrientation] as? UInt32 ?? CGImagePropertyOrientation.up.rawValue
            log("Image orientation from metadata: \(orientation)")

            let options: [CFString: Any] = [
                kCGImageSourceShouldAllowFloat: true,
                kCGImageSourceShouldCache: false,
                kCGImageSourceCreateThumbnailFromImageAlways: false
            ]

            guard let rawCGImage = CGImageSourceCreateImageAtIndex(imageSource, 0, options as CFDictionary) else {
                log("Failed to create CGImage from source", level: .error)

                // Try using Core Image for RAW files - load from data instead of URL
                guard let ciImage = CIImage(data: imageData, options: [.applyOrientationProperty: true]) else {
                    log("Failed to create CIImage from data", level: .error)
                    return false
                }

                log("Loaded as CIImage with orientation, converting to CGImage")
                // CIImage should have orientation baked in with applyOrientationProperty
                if let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) {
                    await MainActor.run {
                        self.currentImage = cgImage
                        self.previewImage = self.createPreview(from: cgImage)
                    }
                    log("Successfully loaded RAW file via CIImage: \(cgImage.width)x\(cgImage.height) pixels")
                    return true
                } else {
                    log("Failed to create CGImage from CIImage", level: .error)
                    return false
                }
            }

            // Apply orientation correction to the loaded CGImage
            let cgImage: CGImage
            if orientation != CGImagePropertyOrientation.up.rawValue {
                log("Applying orientation correction")
                // Convert CGImage to CIImage, apply orientation, then back to CGImage
                let ciImage = CIImage(cgImage: rawCGImage)
                let orientedCIImage = ciImage.oriented(forExifOrientation: Int32(orientation))

                if let correctedCGImage = ciContext.createCGImage(orientedCIImage, from: orientedCIImage.extent) {
                    cgImage = correctedCGImage
                } else {
                    log("Failed to apply orientation correction, using original", level: .warning)
                    cgImage = rawCGImage
                }
            } else {
                cgImage = rawCGImage
            }

            await MainActor.run {
                self.currentImage = cgImage
                self.previewImage = self.createPreview(from: cgImage)
            }

            log("Successfully loaded RAW file: \(cgImage.width)x\(cgImage.height) pixels")
            return true

        } catch {
            log("Failed to read file: \(error.localizedDescription)", level: .error)
            return false
        }
    }

    public func invertImage() async -> Bool {
        guard let inputImage = currentImage else {
            log("No image loaded", level: .error)
            return false
        }

        await MainActor.run {
            isProcessing = true
            performance.startTime = Date()
        }

        defer {
            Task { @MainActor in
                isProcessing = false
                performance.endTime = Date()
            }
        }

        log("Inverting image (film negative processing)...")

        // Create CIImage with proper orientation
        let ciImage = CIImage(cgImage: inputImage).oriented(.up)

        guard let invertFilter = CIFilter(name: "CIColorInvert") else {
            log("Failed to create invert filter", level: .error)
            return false
        }

        invertFilter.setValue(ciImage, forKey: kCIInputImageKey)

        guard let outputImage = invertFilter.outputImage else {
            log("Failed to get output from invert filter", level: .error)
            return false
        }

        let gammaFilter = CIFilter(name: "CIGammaAdjust")
        gammaFilter?.setValue(outputImage, forKey: kCIInputImageKey)
        gammaFilter?.setValue(2.2, forKey: "inputPower")

        let finalImage = gammaFilter?.outputImage ?? outputImage

        guard let cgOutput = ciContext.createCGImage(finalImage, from: finalImage.extent) else {
            log("Failed to create CGImage from CIImage", level: .error)
            return false
        }

        await MainActor.run {
            self.processedImage = cgOutput
            self.processedPreviewImage = self.createPreview(from: cgOutput)
        }

        log("Image inversion completed successfully")
        return true
    }

    // MARK: - Graph Execution API

    /// Execute the node graph and update preview images
    /// This is the main entry point for processing images through the node graph
    public func executeGraph(_ nodeGraph: NodeGraph) async -> Bool {
        // Queue the execution request
        pendingNodeGraph = nodeGraph

        // If there's already an execution running, it will pick up the pending graph
        if executionTask != nil {
            return true
        }

        // Start a new execution task
        executionTask = Task { @MainActor in
            await self.processGraphQueue()
        }

        return true
    }

    private func processGraphQueue() async {
        guard let executor = graphExecutor else {
            log("Graph executor not initialized (Metal device required)", level: .error)
            executionTask = nil
            return
        }

        while let nodeGraph = pendingNodeGraph {
            // Clear pending before execution so new requests can queue
            pendingNodeGraph = nil

            await MainActor.run {
                isProcessing = true
                performance.startTime = Date()
            }

            log("Executing node graph...")

            // Execute the graph on a background actor
            let result = await Task.detached {
                await executor.execute(nodeGraph: nodeGraph)
            }.value

            guard !result.isEmpty else {
                log("No preview outputs generated", level: .warning)
                await MainActor.run {
                    processedPreviewImage = nil
                    isProcessing = false
                    performance.endTime = Date()
                }
                continue
            }

            // Get the first preview node's output (we only allow one preview node)
            if let (_, outputs) = result.first,
               let outputData = outputs["Output"] {

                // Create previews for display
                let beforeImage = await getSourceImage(from: nodeGraph)
                let afterImage = outputData.cgImage

                await MainActor.run {
                    if let beforeImage = beforeImage {
                        self.previewImage = self.createPreview(from: beforeImage)
                    }
                    if let afterImage = afterImage {
                        self.processedPreviewImage = self.createPreview(from: afterImage)
                    }
                    isProcessing = false
                    performance.endTime = Date()
                }

                log("Graph execution completed successfully")
            } else {
                log("Failed to extract preview output", level: .error)
                await MainActor.run {
                    isProcessing = false
                    performance.endTime = Date()
                }
            }
        }

        executionTask = nil
    }

    /// Extract the source image from the graph's Image Input or Folder Input node
    private func getSourceImage(from nodeGraph: NodeGraph) async -> CGImage? {
        // Check for Image Input node first
        if let imageInputNode = nodeGraph.nodes.first(where: { $0.type == .imageInput }) {
            // Determine URL
            let urlToLoad: URL?
            if let bookmarkData = imageInputNode.imageBookmark {
                urlToLoad = resolveBookmark(bookmarkData)
            } else {
                urlToLoad = imageInputNode.imageURL
            }

            guard let url = urlToLoad else {
                return nil
            }

            // Use cached source image if available
            return await getCachedSourceImage(for: url)
        }

        // Check for Folder Input node
        if let folderInputNode = nodeGraph.nodes.first(where: { $0.type == .folderInput }) {
            // Determine folder URL
            let folderURL: URL?
            if let bookmarkData = folderInputNode.imageBookmark {
                folderURL = resolveBookmark(bookmarkData)
            } else {
                folderURL = folderInputNode.imageURL
            }

            guard let folder = folderURL else {
                return nil
            }

            // Get selected image index from parameters
            let selectedIndex = Int(folderInputNode.parameters["selectedIndex"] ?? 0.0)

            // Load image from folder with proper security scoping
            return await loadImageFromFolder(folderURL: folder, selectedIndex: selectedIndex)
        }

        return nil
    }

    /// Clear the graph execution cache (call when graph structure changes)
    public func clearGraphCache() async {
        await graphExecutor?.clearCache()
        log("Graph cache cleared")
    }

    // MARK: - Source Image Cache Management

    /// Get the cached source image for a given URL, or load it if not cached
    /// Automatically scales down to preview resolution unless in full resolution mode
    internal func getCachedSourceImage(for url: URL) async -> CGImage? {
        // Check if we already have this image cached
        if let cachedURL = cachedSourceURL, cachedURL == url, let cached = cachedSourceImage {
            log("Using cached source image for: \(url.lastPathComponent)")
            return cached
        }

        // Cache miss - load the image
        log("Loading source image (cache miss): \(url.lastPathComponent)")
        let gotAccess = url.startAccessingSecurityScopedResource()
        defer {
            if gotAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let imageData = try Data(contentsOf: url)
            guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil) else {
                return nil
            }

            // Check for orientation metadata
            let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
            let orientation = properties?[kCGImagePropertyOrientation] as? UInt32 ?? CGImagePropertyOrientation.up.rawValue
            log("Image orientation from metadata: \(orientation)")

            let options: [CFString: Any] = [
                kCGImageSourceShouldAllowFloat: true,
                kCGImageSourceShouldCache: false
            ]

            guard let rawImage = CGImageSourceCreateImageAtIndex(imageSource, 0, options as CFDictionary) else {
                return nil
            }

            // Apply orientation correction
            let fullResImage: CGImage
            if orientation != CGImagePropertyOrientation.up.rawValue {
                log("Applying orientation correction")
                let ciImage = CIImage(cgImage: rawImage)
                let orientedCIImage = ciImage.oriented(forExifOrientation: Int32(orientation))

                if let correctedImage = ciContext.createCGImage(orientedCIImage, from: orientedCIImage.extent) {
                    fullResImage = correctedImage
                } else {
                    log("Failed to apply orientation correction, using original", level: .warning)
                    fullResImage = rawImage
                }
            } else {
                fullResImage = rawImage
            }

            // Scale to preview resolution unless in full resolution mode
            let cgImage: CGImage
            if isFullResolutionMode {
                cgImage = fullResImage
                log("Loaded full resolution image: \(cgImage.width)x\(cgImage.height)")
            } else {
                cgImage = scaleToPreviewResolution(fullResImage)
                log("Loaded preview resolution image: \(cgImage.width)x\(cgImage.height) (scaled from \(fullResImage.width)x\(fullResImage.height))")
            }

            // Update cache
            cachedSourceImage = cgImage
            cachedSourceURL = url

            return cgImage
        } catch {
            log("Failed to load source image: \(error.localizedDescription)", level: .error)
            return nil
        }
    }

    /// Scale an image to preview resolution
    private func scaleToPreviewResolution(_ image: CGImage) -> CGImage {
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
              let scaledImage = ciContext.createCGImage(outputImage, from: outputImage.extent) else {
            return image
        }

        return scaledImage
    }

    /// Set the cached source image (called by ImageInputProcessor)
    internal func setCachedSourceImage(_ image: CGImage, for url: URL) {
        cachedSourceImage = image
        cachedSourceURL = url
        log("Source image cached: \(url.lastPathComponent)")
    }

    /// Clear the source image cache (call when image URL changes)
    public func clearSourceImageCache() {
        cachedSourceImage = nil
        cachedSourceURL = nil
        log("Source image cache cleared")
    }

    /// Clear the processed preview image (call when preview node is disconnected)
    public func clearProcessedPreview() {
        Task { @MainActor in
            processedPreviewImage = nil
        }
    }

    // MARK: - Folder Scanning

    private var cachedFolderImageURLs: [URL]?
    private var cachedFolderURL: URL?

    /// Scan a folder for supported image files
    /// Returns sorted array of image URLs (alphabetical order)
    internal func scanFolderForImages(folderURL: URL) async -> [URL]? {
        // Check cache first
        if let cachedURL = cachedFolderURL, cachedURL == folderURL, let cached = cachedFolderImageURLs {
            log("Using cached folder scan for: \(folderURL.lastPathComponent)")
            return cached
        }

        log("Scanning folder: \(folderURL.lastPathComponent)")

        let gotAccess = folderURL.startAccessingSecurityScopedResource()
        defer {
            if gotAccess {
                folderURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let fileManager = FileManager.default
            let contents = try fileManager.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: [.isRegularFileKey], options: .skipsHiddenFiles)

            // Filter for supported image types
            let supportedExtensions = ["jpg", "jpeg", "png", "tiff", "tif", "dng", "cr2", "cr3", "nef", "arw", "orf", "rw2", "raf", "raw"]
            let imageURLs = contents.filter { url in
                let ext = url.pathExtension.lowercased()
                return supportedExtensions.contains(ext)
            }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

            log("Found \(imageURLs.count) images in folder")

            // Cache the results
            cachedFolderImageURLs = imageURLs
            cachedFolderURL = folderURL

            return imageURLs
        } catch {
            log("Failed to scan folder: \(error.localizedDescription)", level: .error)
            return nil
        }
    }

    /// Clear the folder scan cache (call when folder URL changes)
    public func clearFolderCache() {
        cachedFolderImageURLs = nil
        cachedFolderURL = nil
        log("Folder cache cleared")
    }

    /// Load an image from a folder at the specified index
    /// Maintains folder security-scoped access throughout the operation
    public func loadImageFromFolder(folderURL: URL, selectedIndex: Int) async -> CGImage? {
        // Start security-scoped access to the folder
        let gotAccess = folderURL.startAccessingSecurityScopedResource()
        defer {
            if gotAccess {
                folderURL.stopAccessingSecurityScopedResource()
            }
        }

        // Get image URLs from folder
        guard let imageURLs = await scanFolderForImages(folderURL: folderURL) else {
            log("Failed to scan folder for images", level: .error)
            return nil
        }

        guard !imageURLs.isEmpty else {
            log("No images found in folder", level: .error)
            return nil
        }

        // Clamp selected index to valid range
        let validIndex = min(max(0, selectedIndex), imageURLs.count - 1)
        let selectedImageURL = imageURLs[validIndex]

        log("Loading image \(validIndex + 1) of \(imageURLs.count) from folder")

        // Load the image while folder access is active
        do {
            let imageData = try Data(contentsOf: selectedImageURL)
            guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil) else {
                log("Failed to create image source from data", level: .error)
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
                log("Failed to create CGImage from source", level: .error)
                return nil
            }

            // Apply orientation correction if needed
            let orientedImage: CGImage
            if orientation != CGImagePropertyOrientation.up.rawValue {
                log("Applying orientation correction")
                let ciImage = CIImage(cgImage: rawImage)
                let orientedCIImage = ciImage.oriented(forExifOrientation: Int32(orientation))

                if let correctedImage = ciContext.createCGImage(orientedCIImage, from: orientedCIImage.extent) {
                    orientedImage = correctedImage
                } else {
                    log("Failed to apply orientation correction, using original", level: .warning)
                    orientedImage = rawImage
                }
            } else {
                orientedImage = rawImage
            }

            // Scale to preview resolution (1920px max dimension) for performance
            let scaledImage = scaleToPreviewResolution(orientedImage)
            log("Loaded and scaled image from folder: \(scaledImage.width)x\(scaledImage.height)")

            return scaledImage
        } catch {
            log("Failed to load image from folder: \(error.localizedDescription)", level: .error)
            return nil
        }
    }

    // MARK: - Export

    /// Export the processed image at full resolution
    /// - Parameters:
    ///   - nodeGraph: The node graph to execute at full resolution
    ///   - to: The destination URL to save the image
    ///   - format: The image format to export (default: TIFF for lossless quality)
    /// - Returns: True if export succeeded, false otherwise
    public func exportImage(_ nodeGraph: NodeGraph, to url: URL, format: ExportFormat = .tiff) async -> Bool {
        await MainActor.run {
            isProcessing = true
            performance.startTime = Date()
        }

        defer {
            Task { @MainActor in
                isProcessing = false
                performance.endTime = Date()
            }
        }

        log("Starting full resolution export to: \(url.lastPathComponent)")

        // Switch to full resolution mode
        isFullResolutionMode = true
        clearSourceImageCache() // Clear cache to force full-res reload

        defer {
            // Switch back to preview mode
            isFullResolutionMode = false
            clearSourceImageCache() // Clear cache to reload preview resolution
        }

        // Execute graph at full resolution
        guard let executor = graphExecutor else {
            log("Graph executor not initialized", level: .error)
            return false
        }

        // Clear cache to ensure full resolution processing
        await executor.clearCache()

        let result = await Task.detached {
            await executor.execute(nodeGraph: nodeGraph)
        }.value

        guard !result.isEmpty else {
            log("No output generated during export", level: .error)
            return false
        }

        // Get the processed image
        guard let (_, outputs) = result.first,
              let outputData = outputs["Output"],
              let finalImage = outputData.cgImage else {
            log("Failed to extract processed image for export", level: .error)
            return false
        }

        log("Processed image at full resolution: \(finalImage.width)x\(finalImage.height)")

        // Save the image
        return await saveImage(finalImage, to: url, format: format)
    }

    private func saveImage(_ image: CGImage, to url: URL, format: ExportFormat) async -> Bool {
        let destination = CGImageDestinationCreateWithURL(url as CFURL, format.utType.identifier as CFString, 1, nil)
        guard let destination = destination else {
            log("Failed to create image destination", level: .error)
            return false
        }

        // Set properties based on format
        var properties: [CFString: Any] = [:]

        switch format {
        case .tiff:
            properties[kCGImagePropertyTIFFCompression] = 1 // No compression for maximum quality
        case .jpeg(let quality):
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        case .png:
            break // PNG is already lossless
        }

        CGImageDestinationAddImage(destination, image, properties as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            log("Failed to write image to disk", level: .error)
            return false
        }

        log("Successfully exported image to: \(url.lastPathComponent)")
        return true
    }
}

/// Export format options
public enum ExportFormat {
    case tiff
    case jpeg(quality: CGFloat) // quality: 0.0 to 1.0
    case png

    var utType: UTType {
        switch self {
        case .tiff:
            return .tiff
        case .jpeg:
            return .jpeg
        case .png:
            return .png
        }
    }

    public var fileExtension: String {
        switch self {
        case .tiff:
            return "tiff"
        case .jpeg:
            return "jpg"
        case .png:
            return "png"
        }
    }
}

public struct LogEntry: Identifiable {
    public let id = UUID()
    public let message: String
    public let level: LogLevel
    public let timestamp: Date
}

public enum LogLevel: String, CaseIterable {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARNING"
    case error = "ERROR"

    public var color: Color {
        switch self {
        case .debug: return .gray
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        }
    }

    public var emoji: String {
        switch self {
        case .debug: return "🔍"
        case .info: return "ℹ️"
        case .warning: return "⚠️"
        case .error: return "❌"
        }
    }
}

public struct PerformanceMetrics {
    public var startTime: Date?
    public var endTime: Date?

    public var duration: TimeInterval? {
        guard let start = startTime, let end = endTime else { return nil }
        return end.timeIntervalSince(start)
    }
}
