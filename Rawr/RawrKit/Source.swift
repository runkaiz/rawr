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
    private let maxPreviewDimension: CGFloat = 2048

    // Graph execution
    private var graphExecutor: GraphExecutor?

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
        guard let executor = graphExecutor else {
            log("Graph executor not initialized (Metal device required)", level: .error)
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

        log("Executing node graph...")

        // Execute the graph
        let previewOutputs = await executor.execute(nodeGraph: nodeGraph)

        guard !previewOutputs.isEmpty else {
            log("No preview outputs generated", level: .warning)
            return false
        }

        // Get the first preview node's output (we only allow one preview node)
        if let (_, outputs) = previewOutputs.first,
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
            }

            log("Graph execution completed successfully")
            return true
        }

        log("Failed to extract preview output", level: .error)
        return false
    }

    /// Extract the source image from the graph's Image Input node
    private func getSourceImage(from nodeGraph: NodeGraph) async -> CGImage? {
        guard let imageInputNode = nodeGraph.nodes.first(where: { $0.type == .imageInput }) else {
            return nil
        }

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

    /// Clear the graph execution cache (call when graph structure changes)
    public func clearGraphCache() async {
        await graphExecutor?.clearCache()
        log("Graph cache cleared")
    }

    // MARK: - Source Image Cache Management

    /// Get the cached source image for a given URL, or load it if not cached
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

            let options: [CFString: Any] = [
                kCGImageSourceShouldAllowFloat: true,
                kCGImageSourceShouldCache: false
            ]

            guard let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, options as CFDictionary) else {
                return nil
            }

            // Update cache
            cachedSourceImage = cgImage
            cachedSourceURL = url
            log("Cached source image: \(cgImage.width)x\(cgImage.height)")

            return cgImage
        } catch {
            log("Failed to load source image: \(error.localizedDescription)", level: .error)
            return nil
        }
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