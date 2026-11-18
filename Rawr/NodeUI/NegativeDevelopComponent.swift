import SwiftUI

struct NegativeDevelopComponent: NodeUIComponent {
    func build(node: NodeData, context: NodeUIContext) -> some View {
        NegativeDevelopControls(parameters: node.parameters, onChange: context.onParameterChange)
    }
}

/// Manual values are measured in decoded linear sRGB, never display RGB.
struct NegativeDevelopControls: View {
    let parameters: [String: Double]
    let onChange: ([String: Double]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Linear film base RGB")
                .font(.caption2)
                .help("Enter the unexposed border's linear sRGB values. Use a direct Image Input or Folder Input connection.")
            HStack {
                field("R", key: "baseR")
                field("G", key: "baseG")
                field("B", key: "baseB")
            }
            DisclosureGroup("Density endpoints") {
                VStack(spacing: 4) {
                    Text("Low → black · High → white")
                        .font(.caption2)
                    HStack {
                        field("R low", key: "lowR")
                        field("R high", key: "highR")
                    }
                    HStack {
                        field("G low", key: "lowG")
                        field("G high", key: "highG")
                    }
                    HStack {
                        field("B low", key: "lowB")
                        field("B high", key: "highB")
                    }
                }
            }
            .font(.caption2)
            field("Exposure (EV)", key: "exposure")
            field("Contrast", key: "contrast")
            field("Toe (0–0.5)", key: "toe")
            field("Shoulder (0–0.5)", key: "shoulder")
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
            .textFieldStyle(.roundedBorder)
            .controlSize(.mini)
            .font(.caption2)
        }
    }
}
