import Foundation

/// Coordinates are fractions of the oriented source with a top-left origin.
/// Rotation is clockwise in source pixels, not normalized space.
public struct CropGeometry: Codable, Equatable, Hashable, Sendable {
    public var centerX: Double = 0.5
    public var centerY: Double = 0.5
    public var width: Double = 1
    public var height: Double = 1
    public var degrees: Double = 0

    func isValid(width pixelsWide: Int, height pixelsHigh: Int) -> Bool {
        guard [centerX, centerY, width, height, degrees].allSatisfy(\.isFinite),
              width >= 0.02, height >= 0.02, width <= 1, height <= 1,
              abs(degrees) <= 12, pixelsWide > 0, pixelsHigh > 0 else { return false }
        let a = degrees * .pi / 180
        let dx = (abs(cos(a)) * width + abs(sin(a)) * height * Double(pixelsHigh) / Double(pixelsWide)) / 2
        let dy = (abs(sin(a)) * width * Double(pixelsWide) / Double(pixelsHigh) + abs(cos(a)) * height) / 2
        return centerX >= dx && centerX <= 1 - dx && centerY >= dy && centerY <= 1 - dy
    }
}

public struct CropOffset: Codable, Equatable, Hashable, Sendable {
    public var x: Double = 0
    public var y: Double = 0
    public var degrees: Double = 0
}

/// A locked rectangle is document-owned. In roll mode only its size is fixed;
/// each frame retains its detected center/angle plus optional saved corrections.
public struct AutoCropSettings: Codable, Equatable, Hashable, Sendable {
    public var manual: CropGeometry?
    public var rollSize: CropGeometry?
    public var rollSourceWidth: Int?
    public var rollSourceHeight: Int?
    public var frameOffsets: [String: CropOffset] = [:]
    public var useBorderForBase = true

    func geometry(proposal: CropGeometry, source: URL?, sourceWidth: Int = 0, sourceHeight: Int = 0) -> CropGeometry {
        guard let rollSize else { return manual ?? proposal }
        var result = proposal
        result.width = rollSize.width
        result.height = rollSize.height
        if let rollSourceWidth, let rollSourceHeight, sourceWidth > 0, sourceHeight > 0 {
            result.width *= Double(rollSourceWidth) / Double(sourceWidth)
            result.height *= Double(rollSourceHeight) / Double(sourceHeight)
        }
        if let source, let offset = frameOffsets[source.standardizedFileURL.path] {
            result.centerX += offset.x
            result.centerY += offset.y
            result.degrees += offset.degrees
        }
        return result
    }
}

struct AutoCropResult: Sendable {
    var proposal: CropGeometry
    var applied: CropGeometry
    var confidence: Double
    var source: URL?
    var sourceWidth: Int
    var sourceHeight: Int
    var borderBase: SIMD4<Float> = .zero
    var gpuSeconds: Double = 0
    var accepted: Bool { confidence >= 0.55 }
}
