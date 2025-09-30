import SwiftUI

// Helper extension for getting center of CGRect
extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}

// Preference keys for reporting dot positions
struct InputDotPositionKey: PreferenceKey {
    static var defaultValue: [UUID: [String: CGPoint]] = [:]
    static func reduce(value: inout [UUID: [String: CGPoint]], nextValue: () -> [UUID: [String: CGPoint]]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

struct OutputDotPositionKey: PreferenceKey {
    static var defaultValue: [UUID: [String: CGPoint]] = [:]
    static func reduce(value: inout [UUID: [String: CGPoint]], nextValue: () -> [UUID: [String: CGPoint]]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

struct NodeView: View {
    let node: NodeData
    let onConnectOutput: (String) -> Void
    let onConnectInput: (String) -> Void
    let onImageSelect: ((URL) -> Void)?
    let onInputHover: (String) -> Void
    let onInputHoverEnd: () -> Void
    let onDelete: () -> Void
    let onPositionChange: (CGPoint) -> Void
    let isConnecting: Bool

    @State private var showingImagePicker = false
    @State private var hoveredInput: String?
    @State private var hoveredOutput: String?
    @State private var dragStartPosition: CGPoint?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                Image(systemName: node.type.icon)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(node.type.rawValue)
                    .font(.caption)
                    .fontWeight(.semibold)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(coordinateSpace: .named("nodeGraph"))
                    .onChanged { value in
                        if dragStartPosition == nil {
                            dragStartPosition = node.position
                        }
                        if let startPos = dragStartPosition {
                            let newPosition = CGPoint(
                                x: startPos.x + value.translation.width,
                                y: startPos.y + value.translation.height
                            )
                            onPositionChange(newPosition)
                        }
                    }
                    .onEnded { _ in
                        dragStartPosition = nil
                    }
            )

            // Image Input specific content
            if node.type == .imageInput {
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
            }

            // Inputs
            if !node.inputs.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(node.inputs, id: \.self) { input in
                        HStack(spacing: 4) {
                            Circle()
                                .fill(hoveredInput == input && isConnecting ? Color.green : Color.gray)
                                .frame(width: hoveredInput == input && isConnecting ? 12 : 10, height: hoveredInput == input && isConnecting ? 12 : 10)
                                .overlay(
                                    Circle()
                                        .stroke(hoveredInput == input && isConnecting ? Color.green : Color.clear, lineWidth: 2)
                                        .scaleEffect(hoveredInput == input && isConnecting ? 1.5 : 1.0)
                                        .opacity(hoveredInput == input && isConnecting ? 0.5 : 0)
                                )
                                .background(
                                    GeometryReader { geo in
                                        Color.clear.preference(
                                            key: InputDotPositionKey.self,
                                            value: [node.id: [input: geo.frame(in: .named("nodeGraph")).center]]
                                        )
                                    }
                                )
                                .onTapGesture {
                                    onConnectInput(input)
                                }
                                .onHover { hovering in
                                    if hovering {
                                        hoveredInput = input
                                        onInputHover(input)
                                    } else {
                                        hoveredInput = nil
                                        onInputHoverEnd()
                                    }
                                }
                                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: hoveredInput)
                            Text(input)
                                .font(.caption2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 12)
            }

            // Outputs
            if !node.outputs.isEmpty {
                VStack(alignment: .trailing, spacing: 4) {
                    ForEach(node.outputs, id: \.self) { output in
                        HStack(spacing: 4) {
                            Text(output)
                                .font(.caption2)
                            Circle()
                                .fill(Color.gray)
                                .frame(width: 12, height: 12)
                                .scaleEffect(hoveredOutput == output ? 1.2 : 1.0)
                                .overlay(
                                    Circle()
                                        .stroke(Color.gray, lineWidth: 2)
                                        .scaleEffect(hoveredOutput == output ? 1.5 : 1.0)
                                        .opacity(hoveredOutput == output ? 0.5 : 0)
                                )
                                .background(
                                    GeometryReader { geo in
                                        Color.clear.preference(
                                            key: OutputDotPositionKey.self,
                                            value: [node.id: [output: geo.frame(in: .named("nodeGraph")).center]]
                                        )
                                    }
                                )
                                .gesture(
                                    DragGesture(minimumDistance: 0)
                                        .onChanged { _ in
                                            onConnectOutput(output)
                                        }
                                )
                                .onHover { hovering in
                                    hoveredOutput = hovering ? output : nil
                                }
                                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: hoveredOutput)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 12)
            }
        }
        .padding(.bottom, 8)
        .frame(width: 150)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
        )
        .shadow(radius: 2)
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .contextMenu {
            Button("Delete", role: .destructive) {
                onDelete()
            }
        }
        .fileImporter(
            isPresented: $showingImagePicker,
            allowedContentTypes: [.image, .rawImage],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    onImageSelect?(url)
                }
            case .failure(let error):
                print("Error selecting image: \(error.localizedDescription)")
            }
        }
    }
}
