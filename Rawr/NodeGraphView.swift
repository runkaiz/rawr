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
                            // Cancel connection when clicking on empty space
                            connectingFrom = nil
                        }
                    }

                // Dotted grid
                GridPattern(size: geometry.size)

                // Connection lines
                ForEach(connections) { connection in
                    if let fromPos = outputDotPositions[connection.fromNodeId]?[connection.fromOutput],
                       let toPos = inputDotPositions[connection.toNodeId]?[connection.toInput] {
                        ConnectionLine(from: fromPos, to: toPos, isPreview: false, onTap: {
                            connections.removeAll { $0.id == connection.id }
                        })
                    }
                }

                // Preview connection line while connecting
                if let from = connectingFrom,
                   let fromPos = outputDotPositions[from.nodeId]?[from.output] {
                    ConnectionLine(from: fromPos, to: currentMousePosition, isPreview: true, onTap: nil)
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
            .focusable(false)
            .focusEffectDisabled()
            .onKeyPress(.escape) {
                // Cancel connection on Escape key
                if connectingFrom != nil {
                    connectingFrom = nil
                    return .handled
                }
                return .ignored
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
                    // Remove any existing connection to this input (inputs can only have 1 connection)
                    connections.removeAll { connection in
                        connection.toNodeId == node.id && connection.toInput == input
                    }

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
                    // Create security-scoped bookmark using RawrKit
                    nodes[index].imageBookmark = RawrKit.createSecurityBookmark(for: url)
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
    var onTap: (() -> Void)?
    @State private var isHovering = false
    @State private var mouseLocation: CGPoint = .zero

    private func curvePath(in size: CGSize) -> Path {
        Path { path in
            path.move(to: from)
            let controlPoint1 = CGPoint(x: from.x + (to.x - from.x) / 2, y: from.y)
            let controlPoint2 = CGPoint(x: from.x + (to.x - from.x) / 2, y: to.y)
            path.addCurve(to: to, control1: controlPoint1, control2: controlPoint2)
        }
    }

    private func isPointNearCurve(_ point: CGPoint, threshold: CGFloat = 10) -> Bool {
        // Sample points along the curve to check distance
        let samples = 50
        for i in 0...samples {
            let t = CGFloat(i) / CGFloat(samples)
            let curvePoint = pointOnCurve(t: t)
            let distance = hypot(point.x - curvePoint.x, point.y - curvePoint.y)
            if distance <= threshold {
                return true
            }
        }
        return false
    }

    private func pointOnCurve(t: CGFloat) -> CGPoint {
        let controlPoint1 = CGPoint(x: from.x + (to.x - from.x) / 2, y: from.y)
        let controlPoint2 = CGPoint(x: from.x + (to.x - from.x) / 2, y: to.y)

        // Cubic Bezier formula
        let oneMinusT = 1 - t
        let x = pow(oneMinusT, 3) * from.x +
                3 * pow(oneMinusT, 2) * t * controlPoint1.x +
                3 * oneMinusT * pow(t, 2) * controlPoint2.x +
                pow(t, 3) * to.x
        let y = pow(oneMinusT, 3) * from.y +
                3 * pow(oneMinusT, 2) * t * controlPoint1.y +
                3 * oneMinusT * pow(t, 2) * controlPoint2.y +
                pow(t, 3) * to.y

        return CGPoint(x: x, y: y)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Invisible wider hit area for easier clicking
                curvePath(in: geometry.size)
                    .stroke(
                        Color.clear,
                        style: StrokeStyle(lineWidth: 20, lineCap: .round)
                    )
                    .contentShape(curvePath(in: geometry.size).strokedPath(StrokeStyle(lineWidth: 20, lineCap: .round)))
                    .onTapGesture {
                        if !isPreview {
                            onTap?()
                        }
                    }

                // Visible line
                curvePath(in: geometry.size)
                    .stroke(
                        isPreview ? Color.accentColor.opacity(0.5) : (isHovering ? Color.red : Color.accentColor),
                        style: StrokeStyle(
                            lineWidth: isPreview ? 3 : 2,
                            lineCap: .round
                        )
                    )
                    .allowsHitTesting(false)
                    .animation(.easeInOut(duration: 0.15), value: from)
                    .animation(.easeInOut(duration: 0.15), value: to)
                    .animation(.easeInOut(duration: 0.1), value: isHovering)
            }
            .onContinuousHover { phase in
                if !isPreview {
                    switch phase {
                    case .active(let location):
                        mouseLocation = location
                        isHovering = isPointNearCurve(location)
                    case .ended:
                        isHovering = false
                    }
                }
            }
        }
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
