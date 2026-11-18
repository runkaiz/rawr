import Foundation
import CoreImage
import Metal
import ImageIO
import UniformTypeIdentifiers

/// Source and terminal color boundaries for the manual negative pipeline.
enum NegativeImageIO {
    static let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    static func load(url: URL, context: ProcessingContext) throws -> ImageData {
        let stageStart = ProcessInfo.processInfo.systemUptime
        defer { context.trace.record("decode", since: stageStart, device: context.device) }
        if let scanner = try InfraredImageIO.scannerTIFF(url: url, context: context) { return scanner }
        let image: CIImage
        if ImageDecoder.rawExtensions.contains(url.pathExtension.lowercased()) {
            guard let raw = CIRAWFilter(imageURL: url), !raw.decoderVersion.rawValue.isEmpty,
                  raw.decoderVersion.rawValue != "None" else { throw ImageDecoder.DecodeError.unsupportedRAW }
            try ImageDecoder.validateDimensions(width: raw.nativeSize.width, height: raw.nativeSize.height)
            raw.scaleFactor = 1
            raw.isDraftModeEnabled = false
            raw.exposure = 0
            raw.baselineExposure = 0
            raw.boostAmount = 0
            raw.boostShadowAmount = 0
            raw.localToneMapAmount = 0
            raw.isGamutMappingEnabled = false
            raw.luminanceNoiseReductionAmount = 0
            raw.colorNoiseReductionAmount = 0
            raw.sharpnessAmount = 0
            raw.linearSpaceFilter = nil
            guard let output = raw.outputImage else { throw ImageDecoder.DecodeError.unsupportedRAW }
            let expected = [raw.nativeSize.width, raw.nativeSize.height].sorted()
            let actual = [output.extent.width, output.extent.height].sorted()
            guard zip(expected, actual).allSatisfy({ abs($0 - $1) <= 1 }) else {
                throw ImageDecoder.DecodeError.unexpectedRAWDimensions
            }
            context.log("Negative RAW: \(raw.decoderVersion.rawValue), linear sRGB; camera neutral retained, native \(raw.nativeSize)")
            image = output
        } else {
            // ImageIO honors embedded ICC/TRC. Untagged files use ImageIO's
            // default interpretation; profile scanner data explicitly before use.
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
                throw ImageDecoder.DecodeError.invalidImage
            }
            try ImageDecoder.validateDimensions(width: width.doubleValue, height: height.doubleValue)
            guard let cg = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldAllowFloat: true] as CFDictionary),
                  cg.colorSpace != nil else { throw ImageDecoder.DecodeError.invalidImage }
            let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.int32Value ?? 1
            image = CIImage(cgImage: cg).oriented(forExifOrientation: orientation)
        }
        try ImageDecoder.validateDimensions(width: image.extent.width, height: image.extent.height)
        let bounds = CGRect(origin: .zero, size: image.extent.size)
        let normalized = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float,
            width: Int(bounds.width), height: Int(bounds.height), mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite]
        guard let lease = context.resources.texture(format: .rgba32Float, width: descriptor.width, height: descriptor.height),
              let command = context.commandQueue.makeCommandBuffer() else { throw ImageDecoder.DecodeError.invalidImage }
        let texture = lease.texture
        context.linearCIContext.render(normalized, to: texture, commandBuffer: command, bounds: bounds, colorSpace: colorSpace)
        command.commit()
        awaitCompletion(command)
        context.trace.record("decode-upload", since: stageStart, device: context.device, command: command)
        guard command.status == .completed else { throw ImageDecoder.DecodeError.invalidImage }
        var metadata = ImageMetadata(width: texture.width, height: texture.height, colorSpace: colorSpace)
        metadata.domain = .linearTransmittance
        metadata.sourceURL = url
        return ImageData(lease: lease, metadata: metadata)
    }

    private static func awaitCompletion(_ command: MTLCommandBuffer) {
        command.waitUntilCompleted()
    }

    static func boundaryImage(_ texture: MTLTexture, context: CIContext, maxDimension: CGFloat? = nil, legacyFloat: Bool = false) -> CGImage? {
        guard var image = CIImage(mtlTexture: texture, options: [.colorSpace: colorSpace]) else { return nil }
        if let limit = maxDimension, limit.isFinite, limit > 0,
           max(image.extent.width, image.extent.height) > limit {
            let scale = limit / max(image.extent.width, image.extent.height)
            image = image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
        }
        // Negative/mask output uses unsigned 16-bit linear RGB. Legacy effects
        // retain half-float HDR values at this terminal boundary.
        return context.createCGImage(image, from: image.extent, format: legacyFloat ? .RGBAh : .RGBA16,
            colorSpace: legacyFloat ? colorSpace : CGColorSpace(name: CGColorSpace.linearSRGB)!, deferred: false)
    }
}
