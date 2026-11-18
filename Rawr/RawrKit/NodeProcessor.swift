import Foundation
import Metal
import CoreImage

/// Runtime representation of image data flowing through the graph
public struct ImageData {
    var textureLeases: [TextureLease] = []
    public let contentID: UUID
    public let texture: MTLTexture
    public let infraredTexture: MTLTexture?
    public var cgImage: CGImage?
    public let metadata: ImageMetadata

    public init(texture: MTLTexture, cgImage: CGImage? = nil, metadata: ImageMetadata = ImageMetadata(), contentID: UUID = UUID(), infraredTexture: MTLTexture? = nil) {
        self.infraredTexture = infraredTexture
        self.contentID = contentID
        self.texture = texture
        self.cgImage = cgImage
        self.metadata = metadata
    }
    init(lease: TextureLease, metadata: ImageMetadata) {
        self.init(texture: lease.texture, metadata: metadata)
        textureLeases = [lease]
    }

}

/// Metadata about an image as it flows through the pipeline
public struct ImageMetadata {
    public var width: Int = 0
    public var height: Int = 0
    public var colorSpace: CGColorSpace?
    public var orientation: UInt32 = 1
    public var domain: ImageDomain = .unspecified
    var sourceURL: URL?
    var legacyFloatOutput = false
    var dustMaskLease: TextureLease?
    var dustMaskPreview: MTLTexture?

    public init(width: Int = 0, height: Int = 0, colorSpace: CGColorSpace? = nil, orientation: UInt32 = 1) {
        self.width = width
        self.height = height
        self.colorSpace = colorSpace
        self.orientation = orientation
    }
}

/// Negative development uses decoded linear sRGB, rather than sensor-native dye space.
public enum ImageDomain {
    case unspecified, linearTransmittance, positiveLinear
}

/// Protocol that all node processors must conform to
public protocol NodeProcessor: AnyObject {
    /// The type of node this processor handles
    var nodeType: NodeType { get }

    /// Process inputs and produce outputs
    /// - Parameters:
    ///   - inputs: Dictionary of input name -> ImageData
    ///   - node: The node configuration data
    ///   - context: Processing context with Metal resources
    /// - Returns: Dictionary of output name -> ImageData, or nil if processing fails
    func process(inputs: [String: ImageData], node: NodeData, context: ProcessingContext) async -> [String: ImageData]?

    /// Validate that this node can be processed with given inputs
    func canProcess(inputs: [String: ImageData], node: NodeData) -> Bool
}

/// Context passed to node processors containing shared resources
public class ProcessingContext {
    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    public let ciContext: CIContext
    public let linearCIContext: CIContext
    public let shaderLibrary: MTLLibrary?
    public weak var logger: RawrKit?
    let resources: MetalResources
    let trace: PipelineTrace
    var negativeInputIDs: Set<UUID> = []

    public convenience init(device: MTLDevice, commandQueue: MTLCommandQueue, ciContext: CIContext, logger: RawrKit? = nil) {
        self.init(device: device, commandQueue: commandQueue, ciContext: ciContext,
            logger: logger, resources: MetalResources(device: device), trace: PipelineTrace())
    }

    init(device: MTLDevice, commandQueue: MTLCommandQueue, ciContext: CIContext,
         logger: RawrKit?, resources: MetalResources, trace: PipelineTrace) {
        self.device = device
        self.commandQueue = commandQueue
        self.ciContext = ciContext
        self.linearCIContext = CIContext(mtlDevice: device, options: [
            .cacheIntermediates: false,
            .workingFormat: CIFormat.RGBAf,
            .workingColorSpace: NegativeImageIO.colorSpace
        ])
        self.resources = resources
        self.trace = trace
        self.shaderLibrary = resources.library
        self.logger = logger
    }

    public func log(_ message: String, level: LogLevel = .info) {
        logger?.log(message, level: level)
    }
}

/// Base class providing common Metal utilities for node processors
open class MetalNodeProcessor: NodeProcessor {
    public let nodeType: NodeType

    public init(nodeType: NodeType) {
        self.nodeType = nodeType
    }

    open func process(inputs: [String: ImageData], node: NodeData, context: ProcessingContext) async -> [String: ImageData]? {
        fatalError("Subclasses must implement process()")
    }

    open func canProcess(inputs: [String: ImageData], node: NodeData) -> Bool {
        // Default: check that all required inputs are present
        return node.inputs.allSatisfy { inputs[$0] != nil }
    }

    // MARK: - Utility Methods

    /// Create a Metal texture from a CGImage
    public func createTexture(from cgImage: CGImage, device: MTLDevice) -> MTLTexture? {
        let width = cgImage.width
        let height = cgImage.height

        let textureDescriptor = MTLTextureDescriptor()
        textureDescriptor.pixelFormat = .rgba16Float
        textureDescriptor.width = width
        textureDescriptor.height = height
        textureDescriptor.usage = [.shaderRead, .shaderWrite]

        guard let texture = device.makeTexture(descriptor: textureDescriptor) else {
            return nil
        }

        // Convert CGImage to texture data
        guard let colorSpace = CGColorSpace(name: CGColorSpace.linearSRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 16,
                bytesPerRow: width * 8,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
              ) else {
            return nil
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let data = context.data else {
            return nil
        }

        let bytesPerRow = width * 8
        let region = MTLRegionMake2D(0, 0, width, height)
        texture.replace(region: region, mipmapLevel: 0, withBytes: data, bytesPerRow: bytesPerRow)

        return texture
    }

    /// Explicit CPU boundary for callers outside graph execution. Core Image
    /// supports private textures and both float formats without reinterpreting
    /// float32 bytes as half floats. Pass a reusable context when calling often.
    public func createCGImage(from texture: MTLTexture, context: CIContext? = nil) -> CGImage? {
        let colorSpace = NegativeImageIO.colorSpace
        guard let image = CIImage(mtlTexture: texture, options: [.colorSpace: colorSpace]) else { return nil }
        let renderer = context ?? CIContext(mtlDevice: texture.device)
        return renderer.createCGImage(image, from: image.extent,
            format: texture.pixelFormat == .rgba32Float ? .RGBAf : .RGBAh, colorSpace: colorSpace, deferred: false)
    }
}
