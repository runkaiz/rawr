import SwiftUI

// MARK: - NodePaletteView

struct NodePaletteView: View {
    @Binding var selectedNodeType: NodeType?
    var nodes: [NodeData] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Nodes")
                .font(.headline)
                .padding()

            Divider()

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(NodeType.allCases, id: \.self) { nodeType in
                        let isDisabled = isNodeDisabled(nodeType)
                        NodePaletteItem(
                            nodeType: nodeType,
                            isSelected: selectedNodeType == nodeType,
                            isDisabled: isDisabled
                        )
                        .onTapGesture {
                            if !isDisabled {
                                if selectedNodeType == nodeType {
                                    selectedNodeType = nil
                                } else {
                                    selectedNodeType = nodeType
                                }
                            }
                        }
                    }
                }
                .padding()
            }

            Spacer()
        }
        .frame(width: 200)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func isNodeDisabled(_ nodeType: NodeType) -> Bool {
        guard let maxCount = nodeType.maxAllowedCount else {
            return false
        }
        let currentCount = nodes.filter { $0.type == nodeType }.count
        return currentCount >= maxCount
    }
}

// MARK: - NodePaletteItem

struct NodePaletteItem: View {
    let nodeType: NodeType
    let isSelected: Bool
    let isDisabled: Bool

    var body: some View {
        HStack {
            Image(systemName: nodeType.icon)
                .font(.body)
                .foregroundColor(isDisabled ? .secondary.opacity(0.4) : .secondary)
                .frame(width: 20)

            Text(nodeType.rawValue)
                .font(.body)
                .foregroundColor(isDisabled ? .secondary.opacity(0.4) : .primary)

            Spacer()
        }
        .padding(12)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .opacity(isDisabled ? 0.5 : 1.0)
    }
}
