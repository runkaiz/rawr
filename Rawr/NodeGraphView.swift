import SwiftUI

// MARK: - NodeGraphView

struct NodeGraphView: View {
    @Binding var nodes: [NodeData]
    @Binding var connections: [Connection]
    @Binding var selectedNodeType: NodeType?
    @State private var connectingFrom: (nodeId: UUID, output: String)?
    @State private var currentMousePosition: CGPoint = .zero
    @State private var isHoveringInput: UUID?
    @State private var hoveredConnectionId: UUID?
    @State private var inputDotPositions: [UUID: [String: CGPoint]] = [:]
    @State private var outputDotPositions: [UUID: [String: CGPoint]] = [:]
    @State private var panOffset: CGSize = .zero
    @State private var dragStart: CGPoint?
    @State private var viewportSize: CGSize = .zero
    @State private var zoomScale: CGFloat = 1.0
    @State private var zoomAnchor: CGPoint = .zero
    @State private var baseZoomScale: CGFloat = 1.0
    @State private var isZooming: Bool = false
    @State private var currentMouseLocation: CGPoint = .zero

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Background with tap gesture - always fills viewport
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

                            // Adjust position to account for zoom and pan
                            let adjustedLocation = CGPoint(
                                x: (location.x - panOffset.width) / zoomScale,
                                y: (location.y - panOffset.height) / zoomScale
                            )
                            let newNode = NodeData(
                                type: nodeType,
                                position: adjustedLocation
                            )
                            nodes.append(newNode)
                            selectedNodeType = nil
                        } else {
                            // Cancel connection when clicking on empty space
                            connectingFrom = nil
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 5)
                            .onChanged { value in
                                // Only pan if we're not connecting nodes
                                if connectingFrom == nil {
                                    if dragStart == nil {
                                        dragStart = value.startLocation
                                    }
                                    panOffset = CGSize(
                                        width: value.translation.width,
                                        height: value.translation.height
                                    )
                                }
                            }
                            .onEnded { _ in
                                // Apply the pan offset to all nodes
                                for i in nodes.indices {
                                    nodes[i].position = CGPoint(
                                        x: nodes[i].position.x + panOffset.width / zoomScale,
                                        y: nodes[i].position.y + panOffset.height / zoomScale
                                    )
                                }
                                panOffset = .zero
                                dragStart = nil
                            }
                    )

                // Scaled content layer
                ZStack {
                    // Dotted grid
                    GridPattern(size: geometry.size)

                    // Connection lines
                    ForEach(connections) { connection in
                        if let fromPos = outputDotPositions[connection.fromNodeId]?[connection.fromOutput],
                           let toPos = inputDotPositions[connection.toNodeId]?[connection.toInput]
                        {
                            ConnectionLine(
                                from: fromPos,
                                to: toPos,
                                isPreview: false,
                                isHovering: hoveredConnectionId == connection.id,
                                onTap: {
                                    connections.removeAll { $0.id == connection.id }
                                }
                            )
                        }
                    }

                    // Preview connection line while connecting
                    if let from = connectingFrom,
                       let fromPos = outputDotPositions[from.nodeId]?[from.output]
                    {
                        ConnectionLine(
                            from: fromPos,
                            to: currentMousePosition,
                            isPreview: true,
                            isHovering: false,
                            onTap: nil
                        )
                    }

                    // Nodes
                    ForEach(nodes) { node in
                        nodeView(for: node)
                            .offset(panOffset)
                    }
                }
                .scaleEffect(zoomScale, anchor: .center)
            }
            .coordinateSpace(name: "nodeGraph")
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        if !isZooming {
                            // Start of zoom gesture - lock base scale and anchor
                            isZooming = true
                            baseZoomScale = zoomScale
                            zoomAnchor = currentMouseLocation
                        }

                        let newZoomScale = max(0.25, min(baseZoomScale * value, 3.0))
                        let scaleDelta = newZoomScale / zoomScale

                        // Adjust node positions to zoom toward cursor
                        let centerX = viewportSize.width / 2
                        let centerY = viewportSize.height / 2
                        let offsetX = (zoomAnchor.x - centerX) / zoomScale
                        let offsetY = (zoomAnchor.y - centerY) / zoomScale

                        for i in nodes.indices {
                            let oldX = nodes[i].position.x
                            let oldY = nodes[i].position.y
                            nodes[i].position = CGPoint(
                                x: oldX - offsetX * (scaleDelta - 1),
                                y: oldY - offsetY * (scaleDelta - 1)
                            )
                        }

                        zoomScale = newZoomScale
                    }
                    .onEnded { _ in
                        isZooming = false
                    }
            )
            .onContinuousHover { phase in
                switch phase {
                case let .active(location):
                    // Track current mouse location for zoom gesture
                    currentMouseLocation = location
                    currentMousePosition = CGPoint(
                        x: (location.x - panOffset.width) / zoomScale,
                        y: (location.y - panOffset.height) / zoomScale
                    )
                    // Check which connection is being hovered
                    updateHoveredConnection(at: location)
                case .ended:
                    hoveredConnectionId = nil
                }
            }
            .onPreferenceChange(InputDotPositionKey.self) { positions in
                inputDotPositions = positions
            }
            .onPreferenceChange(OutputDotPositionKey.self) { positions in
                outputDotPositions = positions
            }
            .background(
                // Invisible focusable overlay for keyboard events
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .focusable()
                    .focusEffectDisabled()
                    .onKeyPress(.escape) {
                        // Cancel connection on Escape key
                        if connectingFrom != nil {
                            connectingFrom = nil
                            return .handled
                        }
                        return .ignored
                    }
            )
            .onAppear {
                viewportSize = geometry.size
                zoomAnchor = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }
            .onChange(of: geometry.size) {
                viewportSize = geometry.size
            }
            .toolbar {
                ToolbarItemGroup(placement: .automatic) {
                    Button(action: centerOnNodes) {
                        Label("Center", systemImage: "scope")
                    }
                    .help("Center view on nodes")

                    Button(action: zoomOut) {
                        Label("Zoom Out", systemImage: "minus.magnifyingglass")
                    }
                    .help("Zoom out")

                    Text("\(Int(zoomScale * 100))%")
                        .font(.caption)
                        .monospacedDigit()
                        .frame(minWidth: 45)

                    Button(action: zoomIn) {
                        Label("Zoom In", systemImage: "plus.magnifyingglass")
                    }
                    .help("Zoom in")

                    Button(action: resetZoom) {
                        Label("Reset Zoom", systemImage: "1.magnifyingglass")
                    }
                    .help("Reset zoom to 100%")
                }
            }
        }
    }

    private func zoomIn() {
        // Set zoom anchor to viewport center for button-based zoom
        zoomAnchor = CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
        withAnimation(.easeInOut(duration: 0.2)) {
            zoomScale = min(zoomScale * 1.2, 3.0)
        }
    }

    private func zoomOut() {
        // Set zoom anchor to viewport center for button-based zoom
        zoomAnchor = CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
        withAnimation(.easeInOut(duration: 0.2)) {
            zoomScale = max(zoomScale / 1.2, 0.25)
        }
    }

    private func resetZoom() {
        // Set zoom anchor to viewport center for button-based zoom
        zoomAnchor = CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
        withAnimation(.easeInOut(duration: 0.2)) {
            zoomScale = 1.0
        }
    }

    private func centerOnNodes() {
        guard !nodes.isEmpty else { return }

        // Calculate bounding box of all nodes
        let positions = nodes.map { $0.position }
        let minX = positions.map { $0.x }.min() ?? 0
        let maxX = positions.map { $0.x }.max() ?? 0
        let minY = positions.map { $0.y }.min() ?? 0
        let maxY = positions.map { $0.y }.max() ?? 0

        // Calculate center of nodes
        let centerX = (minX + maxX) / 2
        let centerY = (minY + maxY) / 2

        // Get viewport center
        let viewportCenterX = viewportSize.width / 2
        let viewportCenterY = viewportSize.height / 2

        // Calculate offset needed to center nodes
        let offsetX = viewportCenterX - centerX
        let offsetY = viewportCenterY - centerY

        // Apply offset to all nodes
        withAnimation(.easeInOut(duration: 0.3)) {
            for i in nodes.indices {
                nodes[i].position = CGPoint(
                    x: nodes[i].position.x + offsetX,
                    y: nodes[i].position.y + offsetY
                )
            }
        }
    }

    private func updateHoveredConnection(at location: CGPoint) {
        // Check all connections to find which one is being hovered
        for connection in connections {
            guard let fromPos = outputDotPositions[connection.fromNodeId]?[connection.fromOutput],
                  let toPos = inputDotPositions[connection.toNodeId]?[connection.toInput]
            else {
                continue
            }

            if isPointNearCurve(location, from: fromPos, to: toPos) {
                hoveredConnectionId = connection.id
                return
            }
        }
        hoveredConnectionId = nil
    }

    private func isPointNearCurve(_ point: CGPoint, from: CGPoint, to: CGPoint, threshold: CGFloat = 10) -> Bool {
        let samples = 50
        for i in 0 ... samples {
            let t = CGFloat(i) / CGFloat(samples)
            let curvePoint = pointOnCurve(t: t, from: from, to: to)
            let distance = hypot(point.x - curvePoint.x, point.y - curvePoint.y)
            if distance <= threshold {
                return true
            }
        }
        return false
    }

    private func pointOnCurve(t: CGFloat, from: CGPoint, to: CGPoint) -> CGPoint {
        let controlPoint1 = CGPoint(x: from.x + (to.x - from.x) / 2, y: from.y)
        let controlPoint2 = CGPoint(x: from.x + (to.x - from.x) / 2, y: to.y)

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
            onInputHover: { _ in
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
            onParameterChange: { updatedParameters in
                if let index = nodes.firstIndex(where: { $0.id == node.id }) {
                    nodes[index].parameters = updatedParameters
                }
            },
            isConnecting: connectingFrom != nil
        )
        .position(node.position)
    }
}

// MARK: - ConnectionLine

struct ConnectionLine: View {
    let from: CGPoint
    let to: CGPoint
    let isPreview: Bool
    let isHovering: Bool
    var onTap: (() -> Void)?

    private func curvePath(in _: CGSize) -> Path {
        Path { path in
            path.move(to: from)
            let controlPoint1 = CGPoint(x: from.x + (to.x - from.x) / 2, y: from.y)
            let controlPoint2 = CGPoint(x: from.x + (to.x - from.x) / 2, y: to.y)
            path.addCurve(to: to, control1: controlPoint1, control2: controlPoint2)
        }
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
        }
    }
}

// MARK: - GridPattern

struct GridPattern: View {
    let size: CGSize
    let spacing: CGFloat = 20
    let dotRadius: CGFloat = 1.5

    var body: some View {
        Canvas { context, size in
            // Extend grid beyond viewport to account for panning/zooming
            let margin: CGFloat = 2000
            let startX = -margin
            let startY = -margin
            let endX = size.width + margin
            let endY = size.height + margin

            let columns = Int((endX - startX) / spacing)
            let rows = Int((endY - startY) / spacing)

            for col in 0 ... columns {
                for row in 0 ... rows {
                    let x = startX + CGFloat(col) * spacing
                    let y = startY + CGFloat(row) * spacing
                    let rect = CGRect(x: x - dotRadius, y: y - dotRadius, width: dotRadius * 2, height: dotRadius * 2)
                    context.fill(Path(ellipseIn: rect), with: .color(.gray.opacity(0.3)))
                }
            }
        }
        .allowsHitTesting(false)
    }
}
