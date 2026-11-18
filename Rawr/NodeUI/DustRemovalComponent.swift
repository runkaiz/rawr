import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct DustRemovalComponent: NodeUIComponent {
    func build(node: NodeData, context: NodeUIContext) -> some View {
        DustRemovalControls(node: node, onParameters: context.onParameterChange,
            onSpots: { context.onCustomAction?("setHealSpots", $0) },
            onInfrared: { context.onCustomAction?("setInfrared", $0) })
    }
}

struct DustRemovalControls: View {
    let node: NodeData
    let onParameters: ([String: Double]) -> Void
    let onSpots: ([HealSpot]) -> Void
    let onInfrared: (URL?) -> Void
    @State private var x = 50.0
    @State private var y = 50.0
    @State private var radius = 0.5

    private func parameter(_ key: String) -> Binding<Double> {
        Binding(get: { node.parameters[key] ?? DustParameters.defaults[key]! }, set: {
            var values = node.parameters
            values[key] = $0
            onParameters(values)
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Repair before Negative Develop").font(.caption).foregroundStyle(.secondary)
            Text("Sensitivity")
            Slider(value: parameter("sensitivity"), in: 0...1)
            HStack {
                Text("Defect radius")
                Spacer()
                Text("\(Int(node.parameters["size"] ?? 2)) px")
            }
            Slider(value: parameter("size"), in: 1...8, step: 1)
                .help("Radius in full-resolution source pixels. Larger values can remove real detail.")
            Toggle("Show defect mask", isOn: Binding(get: { parameter("maskPreview").wrappedValue == 1 },
                set: { parameter("maskPreview").wrappedValue = $0 ? 1 : 0 }))
            Toggle("Use infrared when present", isOn: Binding(get: { parameter("useIR").wrappedValue == 1 },
                set: { parameter("useIR").wrappedValue = $0 ? 1 : 0 }))
            Text("IR ghost correction")
            Slider(value: parameter("irGhost"), in: 0...1)
            Text(node.infraredURL?.lastPathComponent ?? "Embedded IR, otherwise RGB detection")
                .font(.caption2).lineLimit(2)
            HStack {
                Button("IR frame…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.image]
                    panel.canChooseDirectories = false
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url { onInfrared(url) }
                }
                if node.infraredURL != nil { Button("Clear IR") { onInfrared(nil) } }
            }
            Text("IR must be registered and match source size. Disable for silver B&W or image-contaminated IR.")
                .font(.caption2).foregroundStyle(.secondary)
            Divider()
            Text("Manual heal points (\(node.healSpots.count)/128)").font(.caption)
            Text("X/Y: % from top-left; radius: % of short edge.").font(.caption2).foregroundStyle(.secondary)
            HStack {
                TextField("X %", value: $x, format: .number.precision(.fractionLength(2)))
                TextField("Y %", value: $y, format: .number.precision(.fractionLength(2)))
                TextField("Radius %", value: $radius, format: .number.precision(.fractionLength(2)))
            }.textFieldStyle(.roundedBorder)
            Button("Add heal point") {
                let spot = HealSpot(x: x / 100, y: y / 100, radius: radius / 100)
                if spot.isValid, node.healSpots.count < 128 { onSpots(node.healSpots + [spot]) }
            }.disabled(!HealSpot(x: x / 100, y: y / 100, radius: radius / 100).isValid || node.healSpots.count >= 128)
            if !node.healSpots.isEmpty {
                ScrollView {
                    VStack(alignment: .leading) {
                        ForEach(node.healSpots) { spot in
                            HStack {
                                Text("\(spot.x * 100, specifier: "%.2f"), \(spot.y * 100, specifier: "%.2f") · r \(spot.radius * 100, specifier: "%.2f")%")
                                Spacer()
                                Button { onSpots(node.healSpots.filter { $0.id != spot.id }) } label: {
                                    Image(systemName: "minus.circle")
                                }.buttonStyle(.borderless).help("Remove this heal point")
                            }
                        }
                    }
                }.frame(maxHeight: 95)
                Button("Clear points") { onSpots([]) }
            }
            Text("Inspect the mask: automatic RGB detection may flag real detail.")
                .font(.caption2).foregroundStyle(.secondary)
        }.font(.caption).padding(.horizontal, 12)
    }
}
