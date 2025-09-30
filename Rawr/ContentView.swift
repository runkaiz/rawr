//
//  ContentView.swift
//  Rawr
//
//  Created by Runkai Zhang on 4/29/25.
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Binding var document: RawrDocument

    var body: some View {
        EditorView(document: $document)
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
                            var updatedDoc = document
                            let connections = updatedDoc.flowDocument?.nodeGraph.connections ?? []
                            try? updatedDoc.updateNodeGraph(nodes: newNodes, connections: connections)
                            document = updatedDoc
                        }
                    ),
                    connections: Binding(
                        get: { document.flowDocument?.nodeGraph.connections ?? [] },
                        set: { newConnections in
                            var updatedDoc = document
                            let nodes = updatedDoc.flowDocument?.nodeGraph.nodes ?? []
                            try? updatedDoc.updateNodeGraph(nodes: nodes, connections: newConnections)
                            document = updatedDoc
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
    @StateObject private var rawrKit = RawrKit()

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

                if let previewImage = rawrKit.previewImage {
                    let nsImage = NSImage(cgImage: previewImage, size: NSSize(width: previewImage.width, height: previewImage.height))
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
                   let processedPreview = rawrKit.processedPreviewImage {
                    let nsImage = NSImage(cgImage: processedPreview, size: NSSize(width: processedPreview.width, height: processedPreview.height))
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
        .onAppear {
            loadImageFromNode()
        }
        .task(id: imageInputNode?.imageURL) {
            loadImageFromNode()
        }
    }

    private func loadImageFromNode() {
        guard let node = imageInputNode else {
            return
        }

        // Try to resolve from bookmark first, fall back to URL
        let urlToLoad: URL?
        if let bookmarkData = node.imageBookmark {
            // Use RawrKit to resolve the bookmark (with logging)
            urlToLoad = rawrKit.resolveBookmark(bookmarkData)
        } else {
            // No bookmark - this is likely an old document or a newly selected file in the current session
            // For newly selected files, the fileImporter gives us temporary access
            urlToLoad = node.imageURL
        }

        if let url = urlToLoad {
            Task {
                let success = await rawrKit.loadRawFile(from: url)
                if !success {
                    rawrKit.log("Cannot access file. If this is a saved document, please re-select the image.", level: .error)
                }
            }
        }
    }
}

#Preview {
    ContentView(document: .constant(RawrDocument()))
}
