//
//  RawrDocument.swift
//  Rawr
//
//  Created by Runkai Zhang on 4/29/25.
//

import SwiftUI
import UniformTypeIdentifiers

enum NodeGraphError: LocalizedError {
    case tooManyImageInputs
    case tooManyPreviews

    var errorDescription: String? {
        switch self {
        case .tooManyImageInputs:
            return "Flow can only contain one Image Input node"
        case .tooManyPreviews:
            return "Flow can only contain one Preview node"
        }
    }
}

extension UTType {
    static var flow: UTType {
        UTType(importedAs: "xyz.runkaizhang.flow")
    }

    static var dng: UTType {
        UTType(importedAs: "com.adobe.raw-image")
    }
}

struct RawrDocument: FileDocument {
    var flowDocument: FlowDocument?
    var sourceImageData: Data?

    init(sourceImageURL: URL? = nil) {
        if let url = sourceImageURL {
            self.sourceImageData = try? Data(contentsOf: url)
            self.flowDocument = FlowDocument(sourceFileURL: url)
        } else {
            self.sourceImageData = nil
            self.flowDocument = FlowDocument(sourceFileURL: nil)
        }
    }

    static var readableContentTypes: [UTType] {
        [.flow]
    }

    static var writableContentTypes: [UTType] {
        [.flow]
    }

    init(configuration: ReadConfiguration) throws {
        let contentType = configuration.contentType

        if contentType == .flow {
            guard let data = configuration.file.regularFileContents else {
                throw CocoaError(.fileReadCorruptFile)
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            do {
                var decodedFlow = try decoder.decode(FlowDocument.self, from: data)

                // Sync sourceFile URL to Image Input node's imageURL
                if let sourceFileURL = decodedFlow.sourceFile?.originalPath {
                    print("📄 RawrDocument: Found sourceFile path: \(sourceFileURL)")
                    let url = URL(fileURLWithPath: sourceFileURL)
                    var updatedNodes = decodedFlow.nodeGraph.nodes
                    if let imageInputIndex = updatedNodes.firstIndex(where: { $0.type == .imageInput }) {
                        print("📄 RawrDocument: Setting imageURL on Image Input node to: \(url.path)")
                        updatedNodes[imageInputIndex].imageURL = url
                    } else {
                        print("📄 RawrDocument: No Image Input node found in document")
                    }
                    let updatedNodeGraph = NodeGraph(nodes: updatedNodes, connections: decodedFlow.nodeGraph.connections)
                    decodedFlow = FlowDocument(version: decodedFlow.version, sourceFile: decodedFlow.sourceFile, metadata: decodedFlow.metadata, nodeGraph: updatedNodeGraph)
                } else {
                    print("📄 RawrDocument: No sourceFile found in document")
                }

                self.flowDocument = decodedFlow
                self.sourceImageData = nil
            } catch {
                throw CocoaError(.fileReadCorruptFile)
            }
        } else if contentType == .dng || contentType == UTType("public.camera-raw-image") || contentType == .rawImage {
            if let data = configuration.file.regularFileContents {
                self.sourceImageData = data
            } else {
                self.sourceImageData = nil
            }

            if let filename = configuration.file.filename {
                let sourceURL = URL(fileURLWithPath: filename)
                self.flowDocument = FlowDocument(sourceFileURL: sourceURL)
            } else {
                self.flowDocument = nil
            }
        } else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
    }
    
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        if configuration.contentType == .flow {
            guard let flowDocument = flowDocument else {
                throw CocoaError(.fileWriteFileExists)
            }

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

            do {
                let data = try encoder.encode(flowDocument)
                return .init(regularFileWithContents: data)
            } catch {
                throw CocoaError(.fileWriteUnknown)
            }
        } else if let sourceImageData = sourceImageData {
            return .init(regularFileWithContents: sourceImageData)
        } else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    mutating func updateNodeGraph(nodes: [NodeData], connections: [Connection]) throws {
        guard let flow = flowDocument else { return }

        // Validate node limits
        let imageInputCount = nodes.filter { $0.type == .imageInput }.count
        let previewCount = nodes.filter { $0.type == .preview }.count

        if imageInputCount > 1 {
            throw NodeGraphError.tooManyImageInputs
        }
        if previewCount > 1 {
            throw NodeGraphError.tooManyPreviews
        }

        flowDocument = FlowDocument(
            version: flow.version,
            sourceFile: flow.sourceFile,
            metadata: DocumentMetadata(
                createdAt: flow.metadata.createdAt,
                lastModified: Date(),
                appVersion: flow.metadata.appVersion
            ),
            nodeGraph: NodeGraph(nodes: nodes, connections: connections)
        )
    }
}
