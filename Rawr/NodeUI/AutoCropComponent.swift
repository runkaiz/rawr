import SwiftUI

struct AutoCropComponent: NodeUIComponent {
    func build(node: NodeData, context: NodeUIContext) -> some View {
        AutoCropControls(settings: node.autoCrop ?? AutoCropSettings(), result: context.cropResult,
            onChange: { context.onCustomAction?("setAutoCrop", $0) })
    }
}

struct AutoCropControls: View {
    let settings: AutoCropSettings
    let result: AutoCropResult?
    let onChange: (AutoCropSettings) -> Void

    private var geometry: CropGeometry { settings.geometry(proposal: result?.accepted == true ? result!.proposal : CropGeometry(), source: result?.source, sourceWidth: result?.sourceWidth ?? 0, sourceHeight: result?.sourceHeight ?? 0) }

    private var detectionStatus: LocalizedStringKey {
        if result?.accepted == true { return "Frame detected · review the crop" }
        if settings.rollSize != nil { return "Uncertain frame · review before roll export" }
        if settings.manual != nil { return "Uncertain detection · manual crop applied" }
        return "Uncertain frame · retained intact"
    }

    private var mode: LocalizedStringKey {
        if settings.rollSize != nil { return "Roll size + per-frame center/rotation" }
        return settings.manual == nil ? "Automatic" : "Manual crop"
    }

    private var baseStatus: LocalizedStringKey {
        result?.borderBase.w == 1 ? "Unexposed border available for Negative Develop" :
            "No reliable unexposed border; metering uses its normal fallback"
    }

    private func field(_ keyPath: WritableKeyPath<CropGeometry, Double>, percent: Bool = true) -> Binding<Double> {
        Binding(get: { geometry[keyPath: keyPath] * (percent ? 100 : 1) }, set: { value in
            var updated = settings
            var rect = geometry
            rect[keyPath: keyPath] = value / (percent ? 100 : 1)
            if var size = updated.rollSize {
                size.width = rect.width * Double(result?.sourceWidth ?? 1) / Double(settings.rollSourceWidth ?? result?.sourceWidth ?? 1)
                size.height = rect.height * Double(result?.sourceHeight ?? 1) / Double(settings.rollSourceHeight ?? result?.sourceHeight ?? 1)
                updated.rollSize = size
                if let result, let source = result.source {
                    updated.frameOffsets[source.standardizedFileURL.path] = CropOffset(
                        x: rect.centerX - result.proposal.centerX,
                        y: rect.centerY - result.proposal.centerY,
                        degrees: rect.degrees - result.proposal.degrees)
                }
            } else { updated.manual = rect }
            onChange(updated)
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let result {
                Text("Confidence: \(Int(result.confidence * 100))%")
                    .foregroundStyle(result.accepted ? .primary : .secondary)
                Text(detectionStatus)
                    .font(.caption2).foregroundStyle(.secondary)
                CropOutline(geometry: geometry, sourceWidth: result.sourceWidth, sourceHeight: result.sourceHeight)
                    .frame(height: 100)
                if !geometry.isValid(width: result.sourceWidth, height: result.sourceHeight) {
                    Text("Rectangle extends outside the scan").foregroundStyle(.red)
                }
            } else {
                Text("Connect a source and process to detect its frame.").font(.caption2)
            }
            Text(mode)
                .fontWeight(.medium)
            Text("Center and size: % of source. Y from top.").font(.caption2).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 5) {
                GridRow { Text("Center X"); TextField("Center X", value: field(\.centerX), format: .number.precision(.fractionLength(2))) }
                GridRow { Text("Center Y"); TextField("Center Y", value: field(\.centerY), format: .number.precision(.fractionLength(2))) }
                GridRow { Text("Width"); TextField("Width", value: field(\.width), format: .number.precision(.fractionLength(2))) }
                GridRow { Text("Height"); TextField("Height", value: field(\.height), format: .number.precision(.fractionLength(2))) }
                GridRow { Text("Rotation °"); TextField("Rotation", value: field(\.degrees, percent: false), format: .number.precision(.fractionLength(2))) }
            }.textFieldStyle(.roundedBorder)
            HStack {
                Button("Detect again") {
                    var next = settings
                    next.manual = nil
                    next.rollSize = nil
                    onChange(next)
                }
                Button("Lock crop") {
                    var next = settings
                    next.manual = geometry
                    next.rollSize = nil
                    onChange(next)
                }.disabled(result == nil)
            }
            Toggle("Consistent size across roll", isOn: Binding(get: { settings.rollSize != nil }, set: { enabled in
                var next = settings
                next.rollSize = enabled ? geometry : nil
                next.rollSourceWidth = result?.sourceWidth
                next.rollSourceHeight = result?.sourceHeight
                next.manual = nil
                onChange(next)
            })).disabled(result?.accepted != true)
            if settings.rollSize != nil {
                Text(result?.source?.lastPathComponent ?? "Select a folder frame")
                    .font(.caption2).lineLimit(1)
                Text("Center/rotation edits save an offset for this frame. Width/height affect the entire roll.")
                    .font(.caption2).foregroundStyle(.secondary)
                Button("Reset this frame offset") {
                    var next = settings
                    if let source = result?.source { next.frameOffsets.removeValue(forKey: source.standardizedFileURL.path) }
                    onChange(next)
                }
            }
            Toggle("Meter base from detected border", isOn: Binding(get: { settings.useBorderForBase }, set: {
                var next = settings
                next.useBorderForBase = $0
                onChange(next)
            }))
            Text(baseStatus)
                .font(.caption2).foregroundStyle(.secondary)
        }.font(.caption).padding(.horizontal, 12)
    }
}

/// Source-space outline keeps the geometry reviewable without image readback.
struct CropOutline: View {
    let geometry: CropGeometry
    let sourceWidth: Int
    let sourceHeight: Int

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width / Double(sourceWidth), size.height / Double(sourceHeight))
            let w = Double(sourceWidth) * scale, h = Double(sourceHeight) * scale
            let origin = CGPoint(x: (size.width - w) / 2, y: (size.height - h) / 2)
            let source = CGRect(origin: origin, size: CGSize(width: w, height: h))
            context.stroke(Path(source), with: .color(.secondary), lineWidth: 1)
            var cropContext = context
            cropContext.translateBy(x: origin.x + geometry.centerX * w, y: origin.y + geometry.centerY * h)
            cropContext.rotate(by: .degrees(geometry.degrees))
            let crop = CGRect(x: -geometry.width * w / 2, y: -geometry.height * h / 2, width: geometry.width * w, height: geometry.height * h)
            cropContext.fill(Path(crop), with: .color(.accentColor.opacity(0.15)))
            cropContext.stroke(Path(crop), with: .color(.accentColor), lineWidth: 2)
        }.accessibilityLabel("Crop rectangle within source scan")
    }
}
