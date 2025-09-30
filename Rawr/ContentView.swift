//
//  ContentView.swift
//  Rawr
//
//  Created by Runkai Zhang on 4/29/25.
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - ContentView

struct ContentView: View {
    @Binding var document: RawrDocument

    var body: some View {
        EditorView(document: $document)
    }
}

// MARK: - EditorView

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

// MARK: - PreviewSectionView

struct PreviewSectionView: View {
    @Binding var document: RawrDocument
    @StateObject private var rawrKit = RawrKit()

    var imageInputNode: NodeData? {
        document.flowDocument?.nodeGraph.nodes.first(where: { $0.type == .imageInput })
    }

    var previewNode: NodeData? {
        document.flowDocument?.nodeGraph.nodes.first(where: { $0.type == .preview })
    }

    private var imagePreviewsView: some View {
        HStack(spacing: 0) {
            beforePreviewView
            Divider()
            afterPreviewView
        }
        .background(Color(NSColor.textBackgroundColor))
    }

    private var beforePreviewView: some View {
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
    }

    private var afterPreviewView: some View {
        VStack(spacing: 0) {
            Text("After")
                .font(.headline)
                .padding(8)
                .frame(maxWidth: .infinity)
                .background(Color(NSColor.controlBackgroundColor))

            if let _ = previewNode,
               let processedPreview = rawrKit.processedPreviewImage
            {
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

    private var logsView: some View {
        VStack(spacing: 0) {
            Text("Logs")
                .font(.headline)
                .padding(8)
                .frame(maxWidth: .infinity)
                .background(Color(NSColor.controlBackgroundColor))

            logScrollView
        }
        .frame(minWidth: 200, idealWidth: 300)
        .background(Color(NSColor.textBackgroundColor))
    }

    private var logScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(rawrKit.logs) { log in
                        logEntryView(log)
                            .id(log.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: rawrKit.logs.count) {
                if let lastLog = rawrKit.logs.last {
                    withAnimation {
                        proxy.scrollTo(lastLog.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func logEntryView(_ log: LogEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(log.timestamp, style: .time)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)

            Text(log.level.emoji)
                .font(.caption)

            Text(log.message)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(log.level.color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
    }

    var body: some View {
        HSplitView {
            imagePreviewsView
            logsView
        }
        .background(Color(NSColor.textBackgroundColor))
        .onAppear {
            loadImageOrExecuteGraph()
        }
        .task(id: imageInputNode?.imageURL) {
            loadImageOrExecuteGraph()
        }
        .task(id: document.flowDocument?.nodeGraph.nodes.count) {
            loadImageOrExecuteGraph()
        }
        .task(id: document.flowDocument?.nodeGraph.connections) {
            loadImageOrExecuteGraph()
        }
    }

    private func loadImageOrExecuteGraph() {
        guard let nodeGraph = document.flowDocument?.nodeGraph else {
            print("PreviewSectionView: No nodeGraph available")
            return
        }

        // Check if preview node is connected
        let hasPreviewNode = nodeGraph.nodes.contains(where: { $0.type == .preview })
        let previewNodeConnected = hasPreviewNode && nodeGraph.nodes.first(where: { $0.type == .preview }).map { previewNode in
            nodeGraph.connections.contains(where: { $0.toNodeId == previewNode.id })
        } ?? false

        // If we have a connected preview node, execute the full graph
        if previewNodeConnected {
            print("PreviewSectionView: Found connected preview node, executing full graph")
            executeGraph()
        } else if let imageInputNode = nodeGraph.nodes.first(where: { $0.type == .imageInput }) {
            // Otherwise, just load the image input for the "Before" view
            // Resolve URL from bookmark if available
            let urlToLoad: URL?
            if let bookmarkData = imageInputNode.imageBookmark {
                urlToLoad = rawrKit.resolveBookmark(bookmarkData)
            } else {
                urlToLoad = imageInputNode.imageURL
            }

            if let url = urlToLoad {
                print("PreviewSectionView: Loading image from: \(url.path)")
                Task {
                    let success = await rawrKit.loadRawFile(from: url)
                    print("PreviewSectionView: Image load result: \(success)")
                }
            } else {
                print("PreviewSectionView: No valid URL or bookmark for image input node")
            }
        } else {
            print("PreviewSectionView: No image input node")
        }
    }

    private func executeGraph() {
        guard let nodeGraph = document.flowDocument?.nodeGraph else {
            return
        }

        // Only execute if we have all required nodes
        guard nodeGraph.nodes.contains(where: { $0.type == .imageInput }),
              nodeGraph.nodes.contains(where: { $0.type == .preview })
        else {
            return
        }

        Task {
            let success = await rawrKit.executeGraph(nodeGraph)
            if !success {
                rawrKit.log("Graph execution failed", level: .error)
            }
        }
    }
}

#Preview {
    ContentView(document: .constant(RawrDocument()))
}
