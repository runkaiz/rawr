import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Checks native sensor admission before decoding. Oversized supported RAWs can
/// explicitly request a bounded working preview; exports retain the native cap.
struct ImageDecoder {
    let context: CIContext

    enum DecodeError: LocalizedError {
        case invalidImage, unsupportedRAW, invalidDimensions, unexpectedRAWDimensions, fullResolutionLimit, emptyRAW

        var errorDescription: String? {
            switch self {
            case .invalidImage: return "The input is not a decodable image."
            case .unsupportedRAW: return "The RAW sensor image could not be decoded."
            case .invalidDimensions: return "Image dimensions are invalid or exceed the supported size (16384 per edge, 128 megapixels)."
            case .unexpectedRAWDimensions: return "RAW decoder output does not match the full sensor dimensions."
            case .fullResolutionLimit: return "Full-resolution processing is limited to 128 megapixels and 16384 pixels per edge. Use the downscaled preview, or export a smaller calibrated linear DNG/TIFF for full-resolution processing."
            case .emptyRAW: return "RAW decoding produced an empty or transparent frame. Check the capture or export a calibrated linear DNG/TIFF."
            }
        }
    }

    static let rawExtensions: Set<String> = ["dng", "cr2", "cr3", "nef", "nrw", "arw", "orf", "rw2", "raf", "raw", "pef", "srw"]

    func decode(url: URL, allowDownscale: Bool = false) throws -> CGImage {
        let hint = UTType(filenameExtension: url.pathExtension)?.identifier
        let raw = Self.rawExtensions.contains(url.pathExtension.lowercased()) || Self.isRAW(hint)
        if raw {
            guard let filter = try LinearDNG.filter(url: url) ?? CIRAWFilter(imageURL: url) else { throw DecodeError.unsupportedRAW }
            return try renderRAW(filter, allowDownscale: allowDownscale)
        }
        return try decode(data: Data(contentsOf: url), typeHint: hint ?? UTType.image.identifier)
    }

    /// Data has no filename: callers must preserve its type (for example com.nikon.raw-image).
    /// TIFF-based RAW bytes alone can be indistinguishable from an ordinary TIFF to ImageIO.
    func decode(data: Data, typeHint: String) throws -> CGImage {
        let options = [kCGImageSourceTypeIdentifierHint: typeHint] as CFDictionary
        let source = CGImageSourceCreateWithData(data as CFData, options)
        let detectedType = source.flatMap { CGImageSourceGetType($0) as String? }
        if Self.isRAW(typeHint) || Self.isRAW(detectedType) {
            let sensorData = try LinearDNG.threePlaneData(data) ?? data
            guard let filter = CIRAWFilter(imageData: sensorData, identifierHint: typeHint) else {
                throw DecodeError.unsupportedRAW
            }
            return try renderRAW(filter)
        }
        guard let source,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw DecodeError.invalidImage
        }
        try Self.validateDimensions(width: width.doubleValue, height: height.doubleValue)
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, [
            kCGImageSourceShouldAllowFloat: true,
            kCGImageSourceShouldCache: false
        ] as CFDictionary) else { throw DecodeError.invalidImage }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.int32Value ?? 1
        guard orientation != 1 else { return image }
        let oriented = CIImage(cgImage: image).oriented(forExifOrientation: orientation)
        guard let result = context.createCGImage(oriented, from: oriented.extent) else { throw DecodeError.invalidImage }
        return result
    }

    private static func isRAW(_ identifier: String?) -> Bool {
        identifier.flatMap { UTType($0) }?.conforms(to: .rawImage) == true
    }

    static func validateDimensions(width: Double, height: Double) throws {
        guard width.isFinite, height.isFinite, width >= 1, height >= 1,
              width <= 16384, height <= 16384, width * height <= 128_000_000 else {
            throw DecodeError.invalidDimensions
        }
    }

    /// Oversized originals have a bounded 24 MP working preview. This ceiling
    /// is independent of the source admission limit and never changes exports.
    static func workingScale(width: Double, height: Double, allowDownscale: Bool) throws -> Float {
        guard width.isFinite, height.isFinite, width >= 1, height >= 1,
              width <= 65536, height <= 65536, width*height <= 1_000_000_000 else { throw DecodeError.invalidDimensions }
        if width <= 16384, height <= 16384, width*height <= 128_000_000 { return 1 }
        guard allowDownscale else { throw DecodeError.fullResolutionLimit }
        return Float(min(sqrt(24_000_000/(width*height)), 8192/max(width,height)))
    }

    static func validateContent(_ image: CIImage, context: CIContext) throws {
        // A full-sized transparent-black output is a known decoder failure.
        // Reduction runs on Core Image; only one RGBA pixel crosses to CPU.
        let average = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey:CIVector(cgRect:image.extent)])
        var pixel = [Float](repeating:0,count:4)
        pixel.withUnsafeMutableBytes {
            context.render(average,toBitmap:$0.baseAddress!,rowBytes:16,bounds:CGRect(x:0,y:0,width:1,height:1),format:.RGBAf,colorSpace:NegativeImageIO.colorSpace)
        }
        guard pixel.allSatisfy(\.isFinite), pixel[3] > 0.99,
              max(pixel[0],max(pixel[1],pixel[2])) > 1e-7 else { throw DecodeError.emptyRAW }
    }

    private func renderRAW(_ filter: CIRAWFilter, allowDownscale: Bool = false) throws -> CGImage {
        // CIRAWFilter can silently fall back to the ordinary image decoder,
        // reporting an embedded thumbnail as nativeSize. That is not a RAW decode.
        guard !filter.decoderVersion.rawValue.isEmpty, filter.decoderVersion.rawValue != "None" else {
            throw DecodeError.unsupportedRAW
        }
        let native = filter.nativeSize
        let scale = try Self.workingScale(width:native.width,height:native.height,allowDownscale:allowDownscale)
        filter.scaleFactor = scale
        filter.isDraftModeEnabled = false
        guard let output = filter.outputImage else { throw DecodeError.unsupportedRAW }
        let extent = output.extent
        try Self.validateDimensions(width: extent.width, height: extent.height)
        // nativeSize is unaffected by EXIF orientation; compare both axis orders.
        let expected = [native.width*Double(scale), native.height*Double(scale)].sorted()
        let actual = [extent.width, extent.height].sorted()
        guard zip(expected, actual).allSatisfy({ abs($0 - $1) <= 2 }) else {
            throw DecodeError.unexpectedRAWDimensions
        }
        try Self.validateContent(output,context:context)
        guard let image = context.createCGImage(output, from: extent) else { throw DecodeError.unsupportedRAW }
        return image
    }
}
