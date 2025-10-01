import SwiftUI

// MARK: - NodeUIComponent Protocol

/// Protocol for reusable node UI components
public protocol NodeUIComponent {
    /// The SwiftUI view representing this component
    associatedtype Content: View

    /// Builds the SwiftUI view for this component
    func build(node: NodeData, context: NodeUIContext) -> Content
}

// MARK: - NodeUIContext

/// Context passed to UI components for interaction with the node system
public struct NodeUIContext {
    /// Callback to update node parameters
    public let onParameterChange: ([String: Double]) -> Void

    /// Callback to select an image (for ImageInput nodes)
    public let onImageSelect: ((URL) -> Void)?

    /// Callback to trigger custom actions
    public let onCustomAction: ((String, Any?) -> Void)?

    public init(
        onParameterChange: @escaping ([String: Double]) -> Void,
        onImageSelect: ((URL) -> Void)? = nil,
        onCustomAction: ((String, Any?) -> Void)? = nil
    ) {
        self.onParameterChange = onParameterChange
        self.onImageSelect = onImageSelect
        self.onCustomAction = onCustomAction
    }
}

// MARK: - NodeUIDescriptor

/// Declarative descriptor for node UI
public struct NodeUIDescriptor {
    public let nodeType: NodeType
    public let components: [any NodeUIComponent]

    public init(nodeType: NodeType, components: [any NodeUIComponent]) {
        self.nodeType = nodeType
        self.components = components
    }

    /// Creates a descriptor with no custom UI (just inputs/outputs)
    public static func empty(for nodeType: NodeType) -> NodeUIDescriptor {
        return NodeUIDescriptor(nodeType: nodeType, components: [])
    }
}
