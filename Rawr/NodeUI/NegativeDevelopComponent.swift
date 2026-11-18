import SwiftUI

struct NegativeDevelopComponent: NodeUIComponent {
    func build(node: NodeData, context: NodeUIContext) -> some View {
        let optedOut = node.rollBaseline?.frames.first(where: { $0.name == context.rollFrameName })?.optOut == true
        let statistics = optedOut ? context.negativeStatistics : (node.rollBaseline?.statistics ?? context.negativeStatistics)
        return VStack(alignment: .leading, spacing: 8) {
            RollBaselineControls(baseline: node.rollBaseline, parameters: node.parameters, selectedName: context.rollFrameName,
                onMeasure: { context.onCustomAction?("measureRoll", nil) },
                onChange: { context.onCustomAction?("setRoll", $0) })
            NegativeDevelopControls(parameters: node.parameters, statistics: statistics,
                onChange: context.onParameterChange)
        }
    }
}

struct NegativeDevelopControls: View {
    let parameters: [String: Double]
    var statistics: NegativeMeteringResult? = nil
    let onChange: ([String: Double]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            NegativeAutoControl(group: "Base", title: "Film base", confidence: statistics?.base.w,
                parameters: parameters, statistics: statistics, onChange: onChange)
            if let statistics {
                Text("Auto RGB \(statistics.base.x, specifier: "%.4f") / \(statistics.base.y, specifier: "%.4f") / \(statistics.base.z, specifier: "%.4f")")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                field("R", key: "baseR")
                field("G", key: "baseG")
                field("B", key: "baseB")
            }.disabled(parameters["autoBase"] == 1)
            NegativeAutoControl(group: "Endpoints", title: "Density endpoints", confidence: statistics?.low.w,
                parameters: parameters, statistics: statistics, onChange: onChange)
            if let statistics {
                Text("Auto \(statistics.low.y, specifier: "%.3f") → \(statistics.high.y, specifier: "%.3f") D")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            DisclosureGroup("Manual density endpoints") {
                VStack(spacing: 4) {
                    Text("Low → black · High → white").font(.caption2)
                    HStack { field("R low", key: "lowR"); field("R high", key: "highR") }
                    HStack { field("G low", key: "lowG"); field("G high", key: "highG") }
                    HStack { field("B low", key: "lowB"); field("B high", key: "highB") }
                }.disabled(parameters["autoEndpoints"] == 1)
            }.font(.caption2)
            NegativeAutoControl(group: "Balance", title: "Neutral balance", confidence: statistics?.offset.w,
                parameters: parameters, statistics: statistics, onChange: onChange)
            if let statistics {
                Text("Auto shift \(statistics.offset.x, specifier: "%.3f") / \(statistics.offset.y, specifier: "%.3f") / \(statistics.offset.z, specifier: "%.3f") D")
                    .font(.caption2).foregroundStyle(.secondary)
                Text("Auto slope \(statistics.slope.x, specifier: "%.3f") / \(statistics.slope.y, specifier: "%.3f") / \(statistics.slope.z, specifier: "%.3f")")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            DisclosureGroup("Manual neutral axis") {
                VStack {
                    HStack { field("R shift", key: "balanceR"); field("R slope", key: "slopeR") }
                    HStack { field("G shift", key: "balanceG"); field("G slope", key: "slopeG") }
                    HStack { field("B shift", key: "balanceB"); field("B slope", key: "slopeB") }
                }.disabled(parameters["autoBalance"] == 1)
            }.font(.caption2)
            field("Exposure (EV)", key: "exposure")
            field("Contrast", key: "contrast")
            field("Toe (0–0.5)", key: "toe")
            field("Shoulder (0–0.5)", key: "shoulder")
            if NegativeDevelopParameters(parameters) == nil {
                Text("Invalid calibration: check base, endpoints and balance.")
                    .font(.caption2).foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 12)
    }

    private func field(_ label: LocalizedStringKey, key: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            TextField(label, value: Binding(
                get: { parameters[key] ?? NegativeDevelopParameters.defaults[key]! },
                set: { value in
                    var updated = parameters
                    updated[key] = value
                    onChange(updated)
                }
            ), format: .number.precision(.fractionLength(0...6)))
            .textFieldStyle(.roundedBorder).controlSize(.mini).font(.caption2)
        }
    }
}

private struct NegativeAutoControl: View {
    let group: String
    let title: LocalizedStringKey
    let confidence: Float?
    let parameters: [String: Double]
    let statistics: NegativeMeteringResult?
    let onChange: ([String: Double]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(title, isOn: Binding(
                get: { parameters["auto" + group] == 1 },
                set: { enabled in
                    var updated = parameters
                    updated["auto" + group] = enabled ? 1 : 0
                    onChange(updated)
                }
            )).toggleStyle(.checkbox)
            HStack {
                if let confidence {
                    Text("Confidence \(Int(confidence * 100))%")
                        .foregroundStyle(confidence < 0.5 ? .orange : .secondary)
                } else {
                    Text("Connect a source to meter").foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button("Lock") {
                    if let statistics { onChange(statistics.locking(group, in: parameters)) }
                }.disabled(statistics == nil || parameters["auto" + group] != 1)
            }
        }.font(.caption2)
        .help("Checked: use the automatic estimate. Lock copies it into editable manual values. Uncheck to use your saved manual values.")
    }
}
