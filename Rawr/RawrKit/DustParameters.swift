import Foundation

/// Coordinates and radius are fractions of the oriented full image (radius uses
/// the shorter edge). Independent of preview size, and persisted in .flow.
public struct HealSpot: Codable, Hashable, Identifiable {
    public var id = UUID()
    public var x: Double
    public var y: Double
    public var radius: Double

    public init(x: Double, y: Double, radius: Double) {
        self.x = x
        self.y = y
        self.radius = radius
    }

    var isValid: Bool {
        x.isFinite && y.isFinite && radius.isFinite && (0...1).contains(x)
            && (0...1).contains(y) && (0.0001...0.05).contains(radius)
    }
}

struct DustParameters {
    static let defaults: [String: Double] = ["sensitivity": 0.5, "size": 2, "maskPreview": 0,
        "useIR": 1, "irGhost": 1]
    var controls: SIMD4<Float>
    var flags: SIMD4<UInt32>

    init?(_ values: [String: Double], infrared: Bool, spots: [HealSpot]) {
        let p = values.merging(Self.defaults) { saved, _ in saved }
        guard let sensitivity = p["sensitivity"], sensitivity.isFinite, (0...1).contains(sensitivity),
              let size = p["size"], size.isFinite, (1...8).contains(size),
              ["maskPreview", "useIR"].allSatisfy({ p[$0] == 0 || p[$0] == 1 }),
              let ghost = p["irGhost"], ghost.isFinite, (0...1).contains(ghost),
              spots.count <= 128, spots.allSatisfy(\.isValid) else { return nil }
        controls = SIMD4(Float(sensitivity), Float(size.rounded()), Float(p["maskPreview"]!), Float(ghost))
        flags = SIMD4(infrared && p["useIR"] == 1 ? 1 : 0, UInt32(spots.count), 0, 0)
    }
}
