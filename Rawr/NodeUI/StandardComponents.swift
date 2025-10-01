import SwiftUI

// MARK: - Slider Component

/// Standard slider component for numeric parameters
public struct SliderComponent: NodeUIComponent {
    let parameterKey: String
    let label: String
    let range: ClosedRange<Double>
    let step: Double
    let format: String

    public init(
        parameterKey: String,
        label: String,
        range: ClosedRange<Double>,
        step: Double = 0.1,
        format: String = "%.1f"
    ) {
        self.parameterKey = parameterKey
        self.label = label
        self.range = range
        self.step = step
        self.format = format
    }

    public func build(node: NodeData, context: NodeUIContext) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Text(String(format: format, node.parameters[parameterKey] ?? 0.0))
                    .font(.caption2)
                    .monospacedDigit()
            }
            Slider(
                value: Binding(
                    get: { node.parameters[parameterKey] ?? 0.0 },
                    set: { newValue in
                        var updatedParams = node.parameters
                        updatedParams[parameterKey] = newValue
                        context.onParameterChange(updatedParams)
                    }
                ),
                in: range,
                step: step
            )
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
    }
}

// MARK: - Image Picker Component

/// Standard image picker component for image input nodes
public struct ImagePickerComponent: NodeUIComponent {
    public init() {}

    public func build(node: NodeData, context: NodeUIContext) -> some View {
        ImagePickerView(node: node, context: context)
    }
}

private struct ImagePickerView: View {
    let node: NodeData
    let context: NodeUIContext
    @State private var showingImagePicker = false

    var body: some View {
        VStack(spacing: 4) {
            Button(action: {
                showingImagePicker = true
            }) {
                HStack {
                    Image(systemName: node.imageURL == nil ? "photo.badge.plus" : "photo")
                    Text(node.imageURL == nil ? "Select Image" : "Change Image")
                        .font(.caption2)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .simultaneousGesture(DragGesture().onChanged { _ in })

            if let imageURL = node.imageURL {
                Text(imageURL.lastPathComponent)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 12)
        .fileImporter(
            isPresented: $showingImagePicker,
            allowedContentTypes: [.image, .rawImage],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    context.onImageSelect?(url)
                }
            case .failure(let error):
                print("Error selecting image: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Text Field Component

/// Standard text field component for string/numeric input
public struct TextFieldComponent: NodeUIComponent {
    let parameterKey: String
    let label: String
    let placeholder: String

    public init(parameterKey: String, label: String, placeholder: String = "") {
        self.parameterKey = parameterKey
        self.label = label
        self.placeholder = placeholder
    }

    public func build(node: NodeData, context: NodeUIContext) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            TextField(placeholder, value: Binding(
                get: { node.parameters[parameterKey] ?? 0.0 },
                set: { newValue in
                    var updatedParams = node.parameters
                    updatedParams[parameterKey] = newValue
                    context.onParameterChange(updatedParams)
                }
            ), format: .number)
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
    }
}

// MARK: - Toggle Component

/// Standard toggle component for boolean parameters
public struct ToggleComponent: NodeUIComponent {
    let parameterKey: String
    let label: String

    public init(parameterKey: String, label: String) {
        self.parameterKey = parameterKey
        self.label = label
    }

    public func build(node: NodeData, context: NodeUIContext) -> some View {
        Toggle(label, isOn: Binding(
            get: { (node.parameters[parameterKey] ?? 0.0) > 0.5 },
            set: { newValue in
                var updatedParams = node.parameters
                updatedParams[parameterKey] = newValue ? 1.0 : 0.0
                context.onParameterChange(updatedParams)
            }
        ))
        .font(.caption2)
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(.horizontal, 12)
    }
}

// MARK: - Picker Component

/// Standard picker component for selection from options
public struct PickerComponent: NodeUIComponent {
    let parameterKey: String
    let label: String
    let options: [(String, Double)]

    public init(parameterKey: String, label: String, options: [(String, Double)]) {
        self.parameterKey = parameterKey
        self.label = label
        self.options = options
    }

    public func build(node: NodeData, context: NodeUIContext) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Picker("", selection: Binding(
                get: { node.parameters[parameterKey] ?? options.first?.1 ?? 0.0 },
                set: { newValue in
                    var updatedParams = node.parameters
                    updatedParams[parameterKey] = newValue
                    context.onParameterChange(updatedParams)
                }
            )) {
                ForEach(options, id: \.1) { option in
                    Text(option.0).tag(option.1)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
    }
}

// MARK: - Divider Component

/// Simple divider for visual separation
public struct DividerComponent: NodeUIComponent {
    public init() {}

    public func build(node: NodeData, context: NodeUIContext) -> some View {
        Divider()
            .padding(.horizontal, 12)
    }
}

// MARK: - Label Component

/// Simple text label for displaying static information
public struct LabelComponent: NodeUIComponent {
    let text: String
    let style: LabelStyle

    public enum LabelStyle {
        case body
        case caption
        case caption2
        case secondary
    }

    public init(text: String, style: LabelStyle = .caption2) {
        self.text = text
        self.style = style
    }

    public func build(node: NodeData, context: NodeUIContext) -> some View {
        Group {
            switch style {
            case .body:
                Text(text).font(.body)
            case .caption:
                Text(text).font(.caption)
            case .caption2:
                Text(text).font(.caption2)
            case .secondary:
                Text(text).font(.caption2).foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
    }
}

// MARK: - Spacer Component

/// Vertical spacer for layout
public struct SpacerComponent: NodeUIComponent {
    let height: CGFloat

    public init(height: CGFloat = 8) {
        self.height = height
    }

    public func build(node: NodeData, context: NodeUIContext) -> some View {
        Spacer()
            .frame(height: height)
    }
}
