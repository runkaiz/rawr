import Foundation
import SwiftUI
import Metal
import MetalKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

public class RawrKit: ObservableObject {
    @Published public var isProcessing = false
    @Published public var logs: [LogEntry] = []
    @Published public var performance: PerformanceMetrics = PerformanceMetrics()
    @Published public var currentImage: CGImage?
    @Published public var processedImage: CGImage?
    @Published public var previewImage: CGImage?
    @Published public var processedPreviewImage: CGImage?

    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private let ciContext: CIContext
    private var pipelineState: MTLComputePipelineState?
    private let maxPreviewDimension: CGFloat = 2048

    public init() {
        self.device = MTLCreateSystemDefaultDevice()
        self.commandQueue = device?.makeCommandQueue()

        if let device = device {
            self.ciContext = CIContext(mtlDevice: device)
        } else {
            self.ciContext = CIContext()
        }

        log("RawrKit initialized with Metal device: \(device?.name ?? "None")")
        setupMetalPipeline()
    }

    public func log(_ message: String, level: LogLevel = .info) {
        let entry = LogEntry(message: message, level: level, timestamp: Date())
        DispatchQueue.main.async {
            self.logs.append(entry)
        }
    }

    private func setupMetalPipeline() {
        guard let device = device else {
            log("No Metal device available", level: .error)
            return
        }

        let library = device.makeDefaultLibrary()
        guard let kernelFunction = library?.makeFunction(name: "invertColors") else {
            log("Failed to create kernel function", level: .warning)
            return
        }

        do {
            pipelineState = try device.makeComputePipelineState(function: kernelFunction)
            log("Metal pipeline initialized successfully")
        } catch {
            log("Failed to create pipeline state: \(error)", level: .error)
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

    public func exportImage(to url: URL) async -> Bool {
        guard let image = processedImage ?? currentImage else {
            log("No image to export", level: .error)
            return false
        }

        log("Exporting image to: \(url.lastPathComponent)")

        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            log("Failed to create image destination", level: .error)
            return false
        }

        // Set properties to maintain orientation
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: CGImagePropertyOrientation.up.rawValue
        ]

        CGImageDestinationAddImage(destination, image, properties as CFDictionary)

        if CGImageDestinationFinalize(destination) {
            log("Image exported successfully")
            return true
        } else {
            log("Failed to finalize image export", level: .error)
            return false
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
}

public struct PerformanceMetrics {
    public var startTime: Date?
    public var endTime: Date?

    public var duration: TimeInterval? {
        guard let start = startTime, let end = endTime else { return nil }
        return end.timeIntervalSince(start)
    }
}

public struct ProcessingResult {
    public let success: Bool
    public let outputData: Data
    public let error: Error?

    public init(success: Bool, outputData: Data, error: Error? = nil) {
        self.success = success
        self.outputData = outputData
        self.error = error
    }
}