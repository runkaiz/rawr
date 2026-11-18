import Foundation
import SwiftUI
import Metal
import CoreImage
import ImageIO
import UniformTypeIdentifiers

public class RawrKit: ObservableObject {
    @Published var cropResults: [UUID: AutoCropResult] = [:]
    @Published var negativeStatistics: [UUID: NegativeMeteringResult] = [:]
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
    internal var isFullResolutionMode = false // Flag for export mode (internal so processors can access it)

    // Graph execution
    private var graphExecutor: GraphExecutor?
    var processingContext: ProcessingContext?
    @MainActor private var operationTask: Task<Void, Never>?
    @MainActor private var operations: [(operation: @MainActor () async -> Bool, completion: CheckedContinuation<Bool, Never>)] = []

    // Internal storage for full resolution images (legacy support)
    private var currentImage: CGImage?
    private var processedImage: CGImage?

    // Source image cache to avoid reloading
    private var cachedSourceImage: CGImage?
    private var cachedSourceURL: URL?
    private var negativeSourceTexture: MTLTexture?
    private struct NegativeSourceKey: Equatable {
        let url: URL
        let modified: Date?
        let size: UInt64?
        let inode: UInt64?
    }
    private var negativeSourceCache: (key: NegativeSourceKey, image: ImageData)?

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
                self.processingContext = context
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

        do {
            let image = try ImageDecoder(context: ciContext).decode(url: url)
            await MainActor.run {
                self.currentImage = image
                self.previewImage = self.createPreview(from: image)
            }
            log("Successfully loaded image: \(image.width)x\(image.height) pixels")
            return true
        } catch {
            log("Failed to load image: \(error.localizedDescription)", level: .error)
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

    /// Returns the result of this request after processing and preview publication.
    /// Preview and export requests share a FIFO so resolution/cache state cannot overlap.
    @MainActor
    public func executeGraph(_ nodeGraph: NodeGraph) async -> Bool {
        await enqueue { await self.executePreview(nodeGraph) }
    }

    @MainActor
    func enqueue(_ operation: @escaping @MainActor () async -> Bool) async -> Bool {
        await withCheckedContinuation { completion in
            operations.append((operation, completion))
            guard operationTask == nil else { return }
            operationTask = Task { @MainActor in
                while !operations.isEmpty {
                    let request = operations.removeFirst()
                    isProcessing = true
                    performance.startTime = Date()
                    let success = await request.operation()
                    negativeSourceTexture = nil
                    performance.endTime = Date()
                    isProcessing = false
                    request.completion.resume(returning: success)
                }
                operationTask = nil
            }
        }
    }

    @MainActor
    private func executePreview(_ graph: NodeGraph) async -> Bool {
        guard let executor = graphExecutor else {
            log("Graph executor not initialized (Metal device required)", level: .error)
            return false
        }
        let result = await executor.execute(nodeGraph: graph)
        guard let output = result.first?.value["Output"], let after = output.cgImage else {
            processedPreviewImage = nil
            log("No preview outputs generated", level: .warning)
            return false
        }
        if graph.nodes.contains(where: { $0.type == .negativeDevelop || $0.type == .dustRemoval || $0.type == .autoCrop }), let texture = negativeSourceTexture {
            previewImage = NegativeImageIO.boundaryImage(texture, context: processingContext?.linearCIContext ?? ciContext, maxDimension: maxPreviewDimension)
        } else if let before = await getSourceImage(from: graph) {
            previewImage = createPreview(from: before)
        }
        processedPreviewImage = createPreview(from: after)
        log("Graph execution completed successfully")
        return true
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

    /// Full-size float decode and GPU upload; no CPU image is made between stages.
    internal func loadNegativeSource(at url: URL, context: ProcessingContext) -> ImageData? {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            // Full-frame decode is shared by preview and export. File replacement,
            // edits, source selection, and explicit cache clearing change identity.
            let key = NegativeSourceKey(url: url.standardizedFileURL,
                modified: attributes[.modificationDate] as? Date,
                size: (attributes[.size] as? NSNumber)?.uint64Value,
                inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
            if let cached = negativeSourceCache, cached.key == key {
                negativeSourceTexture = cached.image.texture
                return cached.image
            }
            let image = try NegativeImageIO.load(url: url, context: context)
            negativeSourceCache = (key, image)
            negativeSourceTexture = image.texture
            return image
        } catch {
            log("Negative input failed: \(error.localizedDescription)", level: .error)
            return nil
        }
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

        guard let image = decodeSourceImage(at: url) else { return nil }
        cachedSourceImage = image
        cachedSourceURL = url
        return image
    }

    /// The caller holds file or parent-folder security access.
    internal func decodeSourceImage(at url: URL) -> CGImage? {
        do {
            let image = try ImageDecoder(context: ciContext).decode(url: url)
            return isFullResolutionMode ? image : scaleToPreviewResolution(image)
        } catch {
            log("Failed to decode \(url.lastPathComponent): \(error.localizedDescription)", level: .error)
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
        negativeSourceCache = nil
        negativeStatistics = [:]
        cropResults = [:]
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
            let supportedExtensions = ImageDecoder.rawExtensions.union(["jpg", "jpeg", "png", "tiff", "tif"])
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

        return decodeSourceImage(at: selectedImageURL)
    }

    // MARK: - Export

    /// Export the processed image at full resolution
    /// - Parameters:
    ///   - nodeGraph: The node graph to execute at full resolution
    ///   - to: The destination URL to save the image
    ///   - format: The image format to export (default: TIFF for lossless quality)
    /// - Returns: True if export succeeded, false otherwise
    @MainActor
    public func exportImage(_ nodeGraph: NodeGraph, to url: URL, format: ExportFormat = .tiff) async -> Bool {
        await enqueue { await self.exportSingle(nodeGraph, to: url, format: format) }
    }

    @MainActor
    private func exportSingle(_ nodeGraph: NodeGraph, to url: URL, format: ExportFormat) async -> Bool {
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

    /// Export all images from a folder input node (batch export)
    /// - Parameters:
    ///   - nodeGraph: The node graph to execute at full resolution
    ///   - outputFolder: The destination folder to save all processed images
    ///   - format: The image format to export (default: TIFF for lossless quality)
    /// - Returns: True if all exports succeeded, false if any failed
    @MainActor
    public func exportFolderBatch(_ nodeGraph: NodeGraph, to outputFolder: URL, format: ExportFormat = .tiff) async -> Bool {
        await enqueue { await self.exportBatch(nodeGraph, to: outputFolder, format: format) }
    }

    @MainActor
    private func exportBatch(_ nodeGraph: NodeGraph, to outputFolder: URL, format: ExportFormat) async -> Bool {
        if let error = nodeGraph.validationError() {
            log(error, level: .error)
            return false
        }
        // Find the folder input node
        guard let folderInputNode = nodeGraph.nodes.first(where: { $0.type == .folderInput }) else {
            log("No folder input node found in graph", level: .error)
            return false
        }

        // Get the folder URL
        let folderURL: URL?
        if let bookmarkData = folderInputNode.imageBookmark {
            folderURL = resolveBookmark(bookmarkData)
        } else {
            folderURL = folderInputNode.imageURL
        }

        guard let folder = folderURL else {
            log("No folder URL available for batch export", level: .error)
            return false
        }

        let gotFolderAccess = folder.startAccessingSecurityScopedResource()
        let gotOutputAccess = outputFolder.startAccessingSecurityScopedResource()
        defer {
            if gotFolderAccess { folder.stopAccessingSecurityScopedResource() }
            if gotOutputAccess { outputFolder.stopAccessingSecurityScopedResource() }
        }
        clearFolderCache()
        // Scan folder for images
        guard let imageURLs = await scanFolderForImages(folderURL: folder) else {
            log("Failed to scan folder for batch export", level: .error)
            return false
        }

        guard !imageURLs.isEmpty else {
            log("No images found in folder for batch export", level: .error)
            return false
        }

        for node in nodeGraph.nodes where node.type == .negativeDevelop {
            if let roll = node.rollBaseline {
                guard roll.isSupported, roll.frames.count == imageURLs.count,
                      imageURLs.allSatisfy({ roll.parameters(for: $0, node: node.parameters) != nil }) else {
                    log("Roll folder changed or baseline is unsupported; measure again before batch export", level: .error)
                    return false
                }
            }
        }
        log("Starting batch export of \(imageURLs.count) images to: \(outputFolder.lastPathComponent)")

        // Switch to full resolution mode
        isFullResolutionMode = true
        clearSourceImageCache()

        defer {
            isFullResolutionMode = false
            clearSourceImageCache()
        }

        guard let executor = graphExecutor else {
            log("Graph executor not initialized", level: .error)
            return false
        }

        var successCount = 0
        var failCount = 0

        let destinations: [URL]
        do {
            destinations = try BatchDestinations.plan(inputs: imageURLs, folder: outputFolder, extension: format.fileExtension)
        } catch {
            log("Failed to plan batch destinations: \(error.localizedDescription)", level: .error)
            return false
        }

        // Process each image
        for (index, imageURL) in imageURLs.enumerated() {
            log("Processing image \(index + 1)/\(imageURLs.count): \(imageURL.lastPathComponent)")

            // Create a modified graph with the current image index
            var modifiedGraph = nodeGraph
            if let nodeIndex = modifiedGraph.nodes.firstIndex(where: { $0.id == folderInputNode.id }) {
                modifiedGraph.nodes[nodeIndex].parameters["selectedIndex"] = Double(index)
            }

            // Clear cache for this image
            await executor.clearCache()
            clearSourceImageCache()

            // Execute graph at full resolution
            let result = await Task.detached {
                await executor.execute(nodeGraph: modifiedGraph)
            }.value

            guard !result.isEmpty else {
                log("No output generated for image \(index + 1)", level: .error)
                failCount += 1
                continue
            }

            // Get the processed image
            guard let (_, outputs) = result.first,
                  let outputData = outputs["Output"],
                  let finalImage = outputData.cgImage else {
                log("Failed to extract processed image for image \(index + 1)", level: .error)
                failCount += 1
                continue
            }

            // The final install refuses to replace a file created after preflight.
            if await saveImage(finalImage, to: destinations[index], format: format, replaceExisting: false) {
                successCount += 1
            } else {
                failCount += 1
            }
        }

        log("Batch export completed: \(successCount) succeeded, \(failCount) failed")
        return failCount == 0
    }

    private func saveImage(_ image: CGImage, to url: URL, format: ExportFormat, replaceExisting: Bool = true) async -> Bool {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".rawr-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let destination = CGImageDestinationCreateWithURL(temporary as CFURL, format.utType.identifier as CFString, 1, nil)
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

        do {
            if replaceExisting {
                if FileManager.default.fileExists(atPath: url.path) {
                    _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
                } else {
                    try FileManager.default.moveItem(at: temporary, to: url)
                }
            } else {
                try BatchDestinations.install(temporary: temporary, destination: url)
            }
        } catch {
            log("Failed to install export: \(error.localizedDescription)", level: .error)
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
