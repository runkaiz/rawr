import Foundation

/// Manual calibration and automatic-mode switches in decoded linear sRGB. See docs/negative-develop.md.
struct NegativeDevelopParameters {
    static let defaults: [String: Double] = [
        "baseR": 1, "baseG": 1, "baseB": 1,
        "lowR": 0, "lowG": 0, "lowB": 0,
        "highR": 2, "highG": 2, "highB": 2,
        "autoBase": 0, "autoEndpoints": 0, "autoBalance": 0,
        "balanceR": 0, "balanceG": 0, "balanceB": 0,
        "slopeR": 1, "slopeG": 1, "slopeB": 1,
        "rollDensityShift": 0, "rollRelativeDensity": 0, "meterBaseConfidence": 0,
        "exposure": 0, "contrast": 1, "toe": 0, "shoulder": 0
    ]

    // Six packed float4s, shared with the Metal constant buffer.
    let base: SIMD4<Float>
    let low: SIMD4<Float>
    let high: SIMD4<Float>
    let print: SIMD4<Float>
    let balance: SIMD4<Float>
    let slope: SIMD4<Float>

    init?(_ values: [String: Double]) {
        let p = values.merging(Self.defaults) { saved, _ in saved }
        guard p.values.allSatisfy({ $0.isFinite }),
              ["autoBase", "autoEndpoints", "autoBalance", "rollRelativeDensity"].allSatisfy({ p[$0] == 0 || p[$0] == 1 }),
              (0...1).contains(p["meterBaseConfidence"]!),
              ["balanceR", "balanceG", "balanceB"].allSatisfy({ (-1...1).contains(p[$0]!) }),
              ["slopeR", "slopeG", "slopeB"].allSatisfy({ (0.25...4).contains(p[$0]!) }),
              ["baseR", "baseG", "baseB"].allSatisfy({ p[$0]! >= 1e-6 && p[$0]! <= 16 }),
              zip(["lowR", "lowG", "lowB"], ["highR", "highG", "highB"]).allSatisfy({
                  p[$0.0]! >= -6 && p[$0.1]! <= 6 && p[$0.1]! - p[$0.0]! >= 0.01
              }),
              (-6...6).contains(p["rollDensityShift"]!), (-8...8).contains(p["exposure"]!), (0.1...4).contains(p["contrast"]!),
              (0...0.5).contains(p["toe"]!), (0...0.5).contains(p["shoulder"]!) else { return nil }
        balance = SIMD4(Float(p["balanceR"]!), Float(p["balanceG"]!), Float(p["balanceB"]!), Float(p["rollDensityShift"]!))
        slope = SIMD4(Float(p["slopeR"]!), Float(p["slopeG"]!), Float(p["slopeB"]!), 0)
        base = SIMD4(Float(p["baseR"]!), Float(p["baseG"]!), Float(p["baseB"]!), Float(p["meterBaseConfidence"]!))
        low = SIMD4(Float(p["lowR"]!), Float(p["lowG"]!), Float(p["lowB"]!), 0)
        high = SIMD4(Float(p["highR"]!), Float(p["highG"]!), Float(p["highB"]!), 0)
        print = SIMD4(Float(p["exposure"]!), Float(p["contrast"]!), Float(p["toe"]!), Float(p["shoulder"]!))
    }
}
