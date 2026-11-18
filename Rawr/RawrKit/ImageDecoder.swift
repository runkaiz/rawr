import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// One full-size decoding path for files and embedded image data. Preview scaling
/// happens only after decoding and checking the sensor dimensions.
struct ImageDecoder {
    let context: CIContext

    enum DecodeError: LocalizedError {
        case invalidImage, unsupportedRAW, invalidDimensions, unexpectedRAWDimensions

        var errorDescription: String? {
            switch self {
            case .invalidImage: return "The input is not a decodable image."
            case .unsupportedRAW: return "The RAW sensor image could not be decoded."
            case .invalidDimensions: return "Image dimensions are invalid or exceed the supported size (16384 per edge, 128 megapixels)."
            case .unexpectedRAWDimensions: return "RAW decoder output does not match the full sensor dimensions."
            }
        }
    }

    static let rawExtensions: Set<String> = ["dng", "cr2", "cr3", "nef", "nrw", "arw", "orf", "rw2", "raf", "raw", "pef", "srw"]

    func decode(url: URL) throws -> CGImage {
        let hint = UTType(filenameExtension: url.pathExtension)?.identifier
        let raw = Self.rawExtensions.contains(url.pathExtension.lowercased()) || Self.isRAW(hint)
        if raw {
            guard let filter = CIRAWFilter(imageURL: url) else { throw DecodeError.unsupportedRAW }
            return try renderRAW(filter)
        }
        return try decode(data: Data(contentsOf: url), typeHint: hint)
    }

    func decode(data: Data, typeHint: String? = nil) throws -> CGImage {
        let options = typeHint.map { [kCGImageSourceTypeIdentifierHint: $0] as CFDictionary }
        let source = CGImageSourceCreateWithData(data as CFData, options)
        let detectedType = source.flatMap { CGImageSourceGetType($0) as String? }
        if Self.isRAW(typeHint) || Self.isRAW(detectedType) {
            guard let filter = CIRAWFilter(imageData: data, identifierHint: typeHint ?? detectedType) else {
                throw DecodeError.unsupportedRAW
            }
            return try renderRAW(filter)
        }
        // Some TIFF-based RAW containers (notably NEF) are identified as TIFF
        // without a filename. Ask the RAW decoder before ImageIO can return IFD0's thumbnail.
        if detectedType == UTType.tiff.identifier,
           let filter = CIRAWFilter(imageData: data, identifierHint: nil) {
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

    private func renderRAW(_ filter: CIRAWFilter) throws -> CGImage {
        let native = filter.nativeSize
        try Self.validateDimensions(width: native.width, height: native.height)
        filter.scaleFactor = 1
        filter.isDraftModeEnabled = false
        guard let output = filter.outputImage else { throw DecodeError.unsupportedRAW }
        let extent = output.extent
        try Self.validateDimensions(width: extent.width, height: extent.height)
        // nativeSize is unaffected by EXIF orientation; compare both axis orders.
        let expected = [native.width, native.height].sorted()
        let actual = [extent.width, extent.height].sorted()
        guard zip(expected, actual).allSatisfy({ abs($0 - $1) <= 1 }) else {
            throw DecodeError.unexpectedRAWDimensions
        }
        guard let image = context.createCGImage(output, from: extent) else { throw DecodeError.unsupportedRAW }
        return image
    }
}
