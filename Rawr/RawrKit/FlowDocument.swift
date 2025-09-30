//
//  FlowDocument.swift
//  Rawr
//
//  Created by Claude on 9/29/25.
//

import Foundation

struct FlowDocument: Codable {
    let version: String
    let sourceFile: SourceFileReference?
    let metadata: DocumentMetadata
    let nodeGraph: NodeGraph

    init(sourceFileURL: URL? = nil) {
        self.version = "1.0"
        self.sourceFile = sourceFileURL.map { SourceFileReference(url: $0) }
        self.metadata = DocumentMetadata()
        self.nodeGraph = NodeGraph()
    }

    init(version: String, sourceFile: SourceFileReference?, metadata: DocumentMetadata, nodeGraph: NodeGraph) {
        self.version = version
        self.sourceFile = sourceFile
        self.metadata = metadata
        self.nodeGraph = nodeGraph
    }
}

struct NodeGraph: Codable {
    var nodes: [NodeData]
    var connections: [Connection]

    init(nodes: [NodeData] = [], connections: [Connection] = []) {
        self.nodes = nodes
        self.connections = connections
    }
}

struct SourceFileReference: Codable {
    let originalPath: String
    let fileName: String
    let fileSize: Int64?
    let checksum: String?
    let lastModified: Date?

    init(url: URL) {
        self.originalPath = url.path
        self.fileName = url.lastPathComponent

        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            self.fileSize = attributes[.size] as? Int64
            self.lastModified = attributes[.modificationDate] as? Date
        } catch {
            self.fileSize = nil
            self.lastModified = nil
        }

        self.checksum = nil
    }
}

struct DocumentMetadata: Codable {
    let createdAt: Date
    let lastModified: Date
    let appVersion: String

    init() {
        let now = Date()
        self.createdAt = now
        self.lastModified = now
        self.appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    init(createdAt: Date, lastModified: Date, appVersion: String) {
        self.createdAt = createdAt
        self.lastModified = lastModified
        self.appVersion = appVersion
    }
}