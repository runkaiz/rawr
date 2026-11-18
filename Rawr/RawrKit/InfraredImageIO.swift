import Foundation
import CoreImage
import ImageIO
import Metal

/// IR is a scalar measurement, not alpha and not ICC-color-managed RGB.
/// Separate frames are assumed registered to the oriented visible frame.
enum InfraredImageIO {
    static func loadFrame(url: URL, context: ProcessingContext) throws -> MTLTexture {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldAllowFloat: true] as CFDictionary) else {
            throw ImageDecoder.DecodeError.invalidImage
        }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = (props?[kCGImagePropertyOrientation] as? NSNumber)?.int32Value ?? 1
        // Null color space retains scanner sample values. Replicated grayscale or
        // the red component of a monochrome RGB export is the IR measurement.
        let image = CIImage(cgImage: cg, options: [.colorSpace: NSNull()]).oriented(forExifOrientation: orientation)
        try ImageDecoder.validateDimensions(width: image.extent.width, height: image.extent.height)
        return try upload(image, format: .r32Float, context: context, colorSpace: nil)
    }

    private static func upload(_ image: CIImage, format: MTLPixelFormat, context: ProcessingContext,
                               colorSpace: CGColorSpace?) throws -> MTLTexture {
        let stageStart = ProcessInfo.processInfo.systemUptime
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: Int(image.extent.width),
            height: Int(image.extent.height), mipmapped: false)
        d.storageMode = .private
        d.usage = [.shaderRead, .shaderWrite]
        guard let texture = context.device.makeTexture(descriptor: d),
              let command = context.commandQueue.makeCommandBuffer() else { throw ImageDecoder.DecodeError.invalidImage }
        let normalized = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        context.linearCIContext.render(normalized, to: texture, commandBuffer: command,
            bounds: CGRect(x: 0, y: 0, width: d.width, height: d.height), colorSpace: colorSpace ?? NegativeImageIO.colorSpace)
        command.commit()
        command.waitUntilCompleted()
        context.trace.record("ir-upload", since: stageStart, device: context.device, command: command)
        guard command.status == .completed else { throw ImageDecoder.DecodeError.invalidImage }
        return texture
    }

    /// Baseline scanner TIFF: unsigned 8/16-bit, chunky RGB + one *unspecified*
    /// extra sample, uncompressed strips, either byte order. Alpha-tagged TIFFs
    /// are deliberately excluded. Compressed/planar IR TIFFs report an error so
    /// the caller can export a registered separate IR frame instead.
    static func scannerTIFF(url: URL, context: ProcessingContext) throws -> ImageData? {
        guard ["tif", "tiff"].contains(url.pathExtension.lowercased()) else { return nil }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= 8 else { return nil }
        let little = data[0] == 73 && data[1] == 73
        guard little || (data[0] == 77 && data[1] == 77) else { return nil }
        func integer(_ offset: Int, _ size: Int) throws -> Int {
            guard offset >= 0, size > 0, offset <= data.count - size else { throw ImageDecoder.DecodeError.invalidImage }
            var value: UInt64 = 0
            for k in 0..<size { value |= UInt64(data[offset + k]) << (8 * (little ? k : size - k - 1)) }
            guard value <= UInt64(Int.max) else { throw ImageDecoder.DecodeError.invalidImage }
            return Int(value)
        }
        guard try integer(2, 2) == 42 else { return nil } // BigTIFF requires a separate IR export.
        let ifd = try integer(4, 4), count = try integer(ifd, 2)
        guard count <= 4096 else { throw ImageDecoder.DecodeError.invalidImage }
        var tags: [Int: [Int]] = [:]
        let wanted: Set<Int> = [256,257,258,259,262,273,274,277,278,279,284,338,339]
        for k in 0..<count {
            let entry = ifd + 2 + k * 12, tag = try integer(entry, 2)
            guard wanted.contains(tag) else { continue }
            let type = try integer(entry + 2, 2), n = try integer(entry + 4, 4)
            guard [1,3,4].contains(type), n <= 1_000_000 else { throw ImageDecoder.DecodeError.invalidImage }
            let size = type == 3 ? 2 : (type == 4 ? 4 : 1)
            let base: Int
            if n * size <= 4 { base = entry + 8 }
            else { base = try integer(entry + 8, 4) }
            tags[tag] = try (0..<n).map { try integer(base + $0 * size, size) }
        }
        guard tags[277] == [4], tags[262] == [2], tags[338] == [0] else { return nil }
        guard let w = tags[256]?.first, let h = tags[257]?.first,
              let bits = tags[258], bits.count == 4, Set(bits).count == 1, [8,16].contains(bits[0]),
              (tags[259] ?? [1]) == [1], (tags[284] ?? [1]) == [1],
              (tags[339] ?? [1]).allSatisfy({ $0 == 1 }),
              let offsets = tags[273], let lengths = tags[279], offsets.count == lengths.count,
              let rows = tags[278]?.first, rows > 0 else { throw ScannerError.unsupported }
        try ImageDecoder.validateDimensions(width: Double(w), height: Double(h))
        guard offsets.count == (h + rows - 1) / rows else { throw ImageDecoder.DecodeError.invalidImage }
        let bytes = bits[0] / 8, denominator = Float((1 << bits[0]) - 1)
        var rgb = [SIMD4<Float>](repeating: .zero, count: w * h)
        var ir = [Float](repeating: 0, count: w * h)
        for strip in offsets.indices {
            let rowCount = min(rows, h - strip * rows), required = rowCount * w * 4 * bytes
            guard lengths[strip] >= required, offsets[strip] <= data.count - required else { throw ImageDecoder.DecodeError.invalidImage }
            for i in 0..<(rowCount * w) {
                let base = offsets[strip] + i * 4 * bytes, index = strip * rows * w + i
                rgb[index] = SIMD4(Float(try integer(base, bytes)) / denominator,
                    Float(try integer(base + bytes, bytes)) / denominator,
                    Float(try integer(base + 2 * bytes, bytes)) / denominator, 1)
                ir[index] = Float(try integer(base + 3 * bytes, bytes)) / denominator
            }
        }
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        let cg = source.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        let orientation = Int32(tags[274]?.first ?? 1)
        guard (1...8).contains(orientation) else { throw ImageDecoder.DecodeError.invalidImage }
        let visible = CIImage(bitmapData: rgb.withUnsafeBytes { Data($0) }, bytesPerRow: w * 16,
            size: CGSize(width: w, height: h), format: .RGBAf, colorSpace: cg?.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB))
            .oriented(forExifOrientation: orientation)
        let infrared = CIImage(bitmapData: ir.withUnsafeBytes { Data($0) }, bytesPerRow: w * 4,
            size: CGSize(width: w, height: h), format: .Rf, colorSpace: nil).oriented(forExifOrientation: orientation)
        let texture = try upload(visible, format: .rgba32Float, context: context, colorSpace: NegativeImageIO.colorSpace)
        let irTexture = try upload(infrared, format: .r32Float, context: context, colorSpace: nil)
        var metadata = ImageMetadata(width: texture.width, height: texture.height, colorSpace: NegativeImageIO.colorSpace)
        metadata.domain = .linearTransmittance
        metadata.sourceURL = url
        return ImageData(texture: texture, metadata: metadata, infraredTexture: irTexture)
    }

    enum ScannerError: LocalizedError {
        case unsupported
        var errorDescription: String? {
            "This RGB+IR TIFF layout is unsupported. Export uncompressed chunky 8/16-bit TIFF or a separate registered infrared frame."
        }
    }
}
