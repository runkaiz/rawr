import SwiftUI

struct NodeGraphView: View {
    @Binding var nodes: [NodeData]
    @Binding var connections: [Connection]
    @Binding var selectedNodeType: NodeType?
    @State private var connectingFrom: (nodeId: UUID, output: String)?
    @State private var currentMousePosition: CGPoint = .zero
    @State private var isHoveringInput: UUID?
    @State private var inputDotPositions: [UUID: [String: CGPoint]] = [:]
    @State private var outputDotPositions: [UUID: [String: CGPoint]] = [:]

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Background with tap gesture
                Color(nsColor: .textBackgroundColor)
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        if let nodeType = selectedNodeType {
                            // Check if this node type has a maximum count
                            if let maxCount = nodeType.maxAllowedCount {
                                let existingCount = nodes.filter { $0.type == nodeType }.count
                                if existingCount >= maxCount {
                                    selectedNodeType = nil
                                    return
                                }
                            }

                            let newNode = NodeData(
                                type: nodeType,
                                position: location
                            )
                            nodes.append(newNode)
                            selectedNodeType = nil
                        } else {
                            connectingFrom = nil
                        }
                    }

                // Dotted grid
                GridPattern(size: geometry.size)

                // Connection lines
                ForEach(connections) { connection in
                    if let fromPos = outputDotPositions[connection.fromNodeId]?[connection.fromOutput],
                       let toPos = inputDotPositions[connection.toNodeId]?[connection.toInput] {
                        ConnectionLine(from: fromPos, to: toPos, isPreview: false)
                    }
                }

                // Preview connection line while connecting
                if let from = connectingFrom,
                   let fromPos = outputDotPositions[from.nodeId]?[from.output] {
                    ConnectionLine(from: fromPos, to: currentMousePosition, isPreview: true)
                }

                // Nodes
                ForEach(nodes) { node in
                    nodeView(for: node)
                }
            }
            .coordinateSpace(name: "nodeGraph")
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    currentMousePosition = location
                case .ended:
                    break
                }
            }
            .onPreferenceChange(InputDotPositionKey.self) { positions in
                inputDotPositions = positions
            }
            .onPreferenceChange(OutputDotPositionKey.self) { positions in
                outputDotPositions = positions
            }
        }
    }

    @ViewBuilder
    private func nodeView(for node: NodeData) -> some View {
        NodeView(
            node: node,
            onConnectOutput: { output in
                connectingFrom = (node.id, output)
            },
            onConnectInput: { input in
                if let from = connectingFrom {
                    let connection = Connection(
                        fromNodeId: from.nodeId,
                        fromOutput: from.output,
                        toNodeId: node.id,
                        toInput: input
                    )
                    connections.append(connection)
                    connectingFrom = nil
                }
            },
            onImageSelect: { url in
                if let index = nodes.firstIndex(where: { $0.id == node.id }) {
                    nodes[index].imageURL = url
                    // Create security-scoped bookmark
                    // The URL from fileImporter already has security scope access
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer {
                        if accessing {
                            url.stopAccessingSecurityScopedResource()
                        }
                    }

                    do {
                        let bookmarkData = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                        nodes[index].imageBookmark = bookmarkData
                        print("📑 Created security-scoped bookmark for: \(url.lastPathComponent)")
                    } catch {
                        print("⚠️ Failed to create bookmark: \(error.localizedDescription)")
                    }
                }
            },
            onInputHover: { input in
                if connectingFrom != nil {
                    isHoveringInput = node.id
                }
            },
            onInputHoverEnd: {
                isHoveringInput = nil
            },
            onDelete: {
                if let index = nodes.firstIndex(where: { $0.id == node.id }) {
                    let nodeId = nodes[index].id
                    // Remove connections to/from this node
                    connections.removeAll { connection in
                        connection.fromNodeId == nodeId || connection.toNodeId == nodeId
                    }
                    // Remove node
                    nodes.remove(at: index)
                }
            },
            onPositionChange: { newPosition in
                if let index = nodes.firstIndex(where: { $0.id == node.id }) {
                    nodes[index].position = newPosition
                }
            },
            isConnecting: connectingFrom != nil
        )
        .position(node.position)
    }
}

struct ConnectionLine: View {
    let from: CGPoint
    let to: CGPoint
    let isPreview: Bool

    var body: some View {
        Path { path in
            path.move(to: from)

            let controlPoint1 = CGPoint(x: from.x + (to.x - from.x) / 2, y: from.y)
            let controlPoint2 = CGPoint(x: from.x + (to.x - from.x) / 2, y: to.y)

            path.addCurve(to: to, control1: controlPoint1, control2: controlPoint2)
        }
        .stroke(
            isPreview ? Color.accentColor.opacity(0.5) : Color.accentColor,
            style: StrokeStyle(
                lineWidth: isPreview ? 3 : 2,
                lineCap: .round
            )
        )
        .animation(.easeInOut(duration: 0.15), value: from)
        .animation(.easeInOut(duration: 0.15), value: to)
    }
}

struct GridPattern: View {
    let size: CGSize
    let spacing: CGFloat = 20
    let dotRadius: CGFloat = 1.5

    var body: some View {
        Canvas { context, size in
            let columns = Int(size.width / spacing)
            let rows = Int(size.height / spacing)

            for col in 0...columns {
                for row in 0...rows {
                    let x = CGFloat(col) * spacing
                    let y = CGFloat(row) * spacing
                    let rect = CGRect(x: x - dotRadius, y: y - dotRadius, width: dotRadius * 2, height: dotRadius * 2)
                    context.fill(Path(ellipseIn: rect), with: .color(.gray.opacity(0.3)))
                }
            }
        }
        .allowsHitTesting(false)
    }
}
