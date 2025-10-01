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
            ForEach(Array(descriptor.components.enumerated()), id: \.offset) { index, component in
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
                    range: -5...5,
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
                    range: 0.5...4.0,
                    step: 0.01,
                    format: "%.2f"
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
