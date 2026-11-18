import SwiftUI

struct RollBaselineControls: View {
    let baseline: RollBaseline?
    var parameters: [String: Double] = [:]
    let selectedName: String?
    let onMeasure: () -> Void
    let onChange: (RollBaseline?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Roll consistency").font(.caption.bold())
            Button(baseline == nil ? "Measure folder roll" : "Measure roll again", action: onMeasure)
                .help("Connect Folder Input directly. At least three reliable frames with film borders and neutral detail are required. Measurement replaces the baseline and frame edits.")
            if let baseline {
                Text("Baseline v\(baseline.version) · Confidence \(Int(baseline.confidence * 100))%")
                Text("\(baseline.frames.filter(\.included).count) / \(baseline.frames.count) frames accepted")
                let p = baseline.calibration
                Text("Base RGB \(p["baseR", default: 1], specifier: "%.3f") / \(p["baseG", default: 1], specifier: "%.3f") / \(p["baseB", default: 1], specifier: "%.3f")")
                Text("Density \(p["lowG", default: 0], specifier: "%.3f") → \(p["highG", default: 2], specifier: "%.3f")")
                Text("Neutral shift \(p["balanceR", default: 0], specifier: "%.3f") / \(p["balanceG", default: 0], specifier: "%.3f") / \(p["balanceB", default: 0], specifier: "%.3f")")
                Text("Neutral slope \(p["slopeR", default: 1], specifier: "%.3f") / \(p["slopeG", default: 1], specifier: "%.3f") / \(p["slopeB", default: 1], specifier: "%.3f")")
                Text("Automatic groups use the saved roll; manual groups take priority.").foregroundStyle(.secondary)
                if let selectedName, let index = baseline.frames.firstIndex(where: { $0.name == selectedName }) {
                    RollFrameControls(baseline: baseline, parameters: parameters, index: index, onChange: onChange)
                }
                Button("Remove roll baseline") { onChange(nil) }
            } else {
                Text("Measure one folder of film to share its base, endpoints and balance.").foregroundStyle(.secondary)
            }
        }.font(.caption2).controlSize(.mini).padding(.horizontal, 12)
    }
}

private struct RollFrameControls: View {
    let baseline: RollBaseline
    let parameters: [String: Double]
    let index: Int
    let onChange: (RollBaseline?) -> Void

    var body: some View {
        let frame = baseline.frames[index]
        VStack(alignment: .leading, spacing: 4) {
            Text(frame.name).lineLimit(1)
            Text(frame.included ? "Included in baseline" : "Outlier excluded from measurement")
                .foregroundStyle(frame.included ? .secondary : .orange)
            Text("Density alignment \(frame.densityShift, specifier: "%.3f") D")
            Toggle("Use individual frame settings", isOn: Binding(
                get: { frame.optOut }, set: { value in
                    var updated = baseline; updated.frames[index].optOut = value; onChange(updated)
                }))
            .toggleStyle(.checkbox)
            TextField("Frame exposure trim (EV)", value: Binding(
                get: { frame.exposure }, set: { value in
                    guard value.isFinite, (-8...8).contains(value) else { return }
                    var updated = baseline; updated.frames[index].exposure = value; onChange(updated)
                }), format: .number.precision(.fractionLength(0...3)))
                .textFieldStyle(.roundedBorder)
            Text("Frame exposure trim (EV)").foregroundStyle(.secondary)
            Button("Override frame with current node settings") {
                var updated = baseline
                var manual = parameters.merging(NegativeDevelopParameters.defaults) { saved, _ in saved }
                for group in ["Base", "Endpoints", "Balance"] { manual["auto" + group] = 0 }
                manual["rollDensityShift"] = 0
                updated.frames[index].overrides = manual
                onChange(updated)
            }
            if !frame.overrides.isEmpty {
                Text("Saved frame override active").foregroundStyle(.orange)
                Button("Clear frame override") {
                    var updated = baseline; updated.frames[index].overrides = [:]; onChange(updated)
                }
            }
        }
    }
}

