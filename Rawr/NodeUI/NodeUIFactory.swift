import SwiftUI

// MARK: - NodeUIFactory

/// Factory for creating node UIs from descriptors
public class NodeUIFactory {
    private var descriptors: [NodeType: NodeUIDescriptor] = [:]

    public static let shared = NodeUIFactory()

    private init() {
        registerDefaultDescriptors()
    }

    /// Register a UI descriptor for a node type
    public func register(descriptor: NodeUIDescriptor) {
        descriptors[descriptor.nodeType] = descriptor
    }

    /// Get the descriptor for a node type
    public func descriptor(for nodeType: NodeType) -> NodeUIDescriptor? {
        return descriptors[nodeType]
    }

    /// Build the UI for a node
    @ViewBuilder
    public func buildUI(for node: NodeData, context: NodeUIContext) -> some View {
        if let descriptor = descriptors[node.type] {
            ForEach(Array(descriptor.components.enumerated()), id: \.offset) { _, component in
                AnyView(component.buildView(node: node, context: context))
            }
        } else {
            EmptyView()
        }
    }

    // MARK: - Default Descriptors

    private func registerDefaultDescriptors() {
        // Image Input Node
        register(descriptor: NodeUIDescriptor(
            nodeType: .imageInput,
            components: [
                ImagePickerComponent()
            ]
        ))

        // Exposure Node
        register(descriptor: NodeUIDescriptor(
            nodeType: .exposure,
            components: [
                SliderComponent(
                    parameterKey: "stops",
                    label: "Stops",
                    range: -5 ... 5,
                    step: 0.1,
                    format: "%.1f"
                )
            ]
        ))

        // Gamma Node
        register(descriptor: NodeUIDescriptor(
            nodeType: .gamma,
            components: [
                SliderComponent(
                    parameterKey: "gamma",
                    label: "Gamma",
                    range: 0.5 ... 4.0,
                    step: 0.1,
                    format: "%.2f"
                )
            ]
        ))

        // Denoise Node
        register(descriptor: NodeUIDescriptor(
            nodeType: .denoise,
            components: [
                SliderComponent(
                    parameterKey: "strength",
                    label: "Strength",
                    range: 0.5 ... 3.0,
                    step: 0.1,
                    format: "%.1f"
                ),
                SliderComponent(
                    parameterKey: "colorSigma",
                    label: "Color Sigma",
                    range: 0.05 ... 0.5,
                    step: 0.05,
                    format: "%.2f"
                )
            ]
        ))

        // Sharpening Node
        register(descriptor: NodeUIDescriptor(
            nodeType: .sharpening,
            components: [
                PickerComponent(
                    parameterKey: "algorithm",
                    label: "Algorithm",
                    options: [
                        ("Default (Safe)", 0.0),
                        ("Detail-max (Low ISO)", 1.0)
                    ]
                ),
                SliderComponent(
                    parameterKey: "strength",
                    label: "Strength",
                    range: 0.1 ... 2.0,
                    step: 0.1,
                    format: "%.1f"
                ),
                SliderComponent(
                    parameterKey: "radius",
                    label: "Radius",
                    range: 0.5 ... 3.0,
                    step: 0.1,
                    format: "%.1f"
                ),
                SliderComponent(
                    parameterKey: "iterations",
                    label: "Iterations",
                    range: 1 ... 10,
                    step: 1,
                    format: "%.0f"
                )
            ]
        ))

        // Inversion Node (no custom UI)
        register(descriptor: NodeUIDescriptor.empty(for: .inversion))

        // Preview Node (no custom UI)
        register(descriptor: NodeUIDescriptor.empty(for: .preview))
    }
}

// MARK: - Type Erasure Helper

extension NodeUIComponent {
    /// Type-erased view builder
    func buildView(node: NodeData, context: NodeUIContext) -> AnyView {
        AnyView(build(node: node, context: context))
    }
}
