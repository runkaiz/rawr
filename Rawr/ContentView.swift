//
//  ContentView.swift
//  Rawr
//
//  Created by Runkai Zhang on 4/29/25.
//

import Metal
import MetalKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Binding var document: RawrDocument
    @State private var isDeveloperMode: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            // Top toolbar for mode switching
            HStack {
                Picker("Mode", selection: $isDeveloperMode) {
                    Text("Editor Mode").tag(false)
                    Text("Developer Mode").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)

                Spacer()

                Text(isDeveloperMode ? "RawrKit Development Interface" : "Rawr Editor")
                    .font(.headline)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Main content area
            Group {
                if isDeveloperMode {
                    DeveloperView()
                } else {
                    EditorView(document: $document)
                }
            }
        }
    }
}

struct EditorView: View {
    @Binding var document: RawrDocument
    @State private var selectedNodeType: NodeType?

    var hasPreviewNode: Bool {
        document.flowDocument?.nodeGraph.nodes.contains(where: { $0.type == .preview }) ?? false
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top: Node graph area
            HSplitView {
                // Left sidebar: Node palette
                NodePaletteView(
                    selectedNodeType: $selectedNodeType,
                    nodes: document.flowDocument?.nodeGraph.nodes ?? []
                )

                // Center: Node graph canvas
                NodeGraphView(
                    nodes: Binding(
                        get: { document.flowDocument?.nodeGraph.nodes ?? [] },
                        set: { newNodes in
                            let connections = document.flowDocument?.nodeGraph.connections ?? []
                            try? document.updateNodeGraph(nodes: newNodes, connections: connections)
                        }
                    ),
                    connections: Binding(
                        get: { document.flowDocument?.nodeGraph.connections ?? [] },
                        set: { newConnections in
                            let nodes = document.flowDocument?.nodeGraph.nodes ?? []
                            try? document.updateNodeGraph(nodes: nodes, connections: newConnections)
                        }
                    ),
                    selectedNodeType: $selectedNodeType
                )
            }

            // Bottom: Preview section (only shown when preview node exists)
            if hasPreviewNode {
                Divider()

                PreviewSectionView(document: $document)
                    .frame(height: 300)
            }
        }
    }
}

struct PreviewSectionView: View {
    @Binding var document: RawrDocument

    var imageInputNode: NodeData? {
        document.flowDocument?.nodeGraph.nodes.first(where: { $0.type == .imageInput })
    }

    var previewNode: NodeData? {
        document.flowDocument?.nodeGraph.nodes.first(where: { $0.type == .preview })
    }

    var body: some View {
        HStack(spacing: 0) {
            // Before preview
            VStack(spacing: 0) {
                Text("Before")
                    .font(.headline)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(Color(NSColor.controlBackgroundColor))

                if let imageURL = imageInputNode?.imageURL,
                   let nsImage = NSImage(contentsOf: imageURL) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text("No image loaded")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            Divider()

            // After preview
            VStack(spacing: 0) {
                Text("After")
                    .font(.headline)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(Color(NSColor.controlBackgroundColor))

                if let _ = previewNode,
                   let imageInputNode = imageInputNode,
                   let imageURL = imageInputNode.imageURL,
                   let nsImage = NSImage(contentsOf: imageURL) {
                    // TODO: Apply node graph operations to the image
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text("No preview available")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(Color(NSColor.textBackgroundColor))
    }
}

struct ImageDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.png] }

    let imageData: Data?

    init(image: CGImage?) {
        if let image = image,
           let destination = CFDataCreateMutable(nil, 0),
           let destRef = CGImageDestinationCreateWithData(destination, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(destRef, image, nil)
            CGImageDestinationFinalize(destRef)
            self.imageData = destination as Data
        } else {
            self.imageData = nil
        }
    }

    init(configuration: ReadConfiguration) throws {
        self.imageData = nil
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard let data = imageData else {
            throw CocoaError(.fileWriteUnknown)
        }
        return FileWrapper(regularFileWithContents: data)
    }
}

#Preview {
    ContentView(document: .constant(RawrDocument()))
}
