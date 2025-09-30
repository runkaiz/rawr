//
//  FlowDocument.swift
//  Rawr
//
//  Created by Claude on 9/29/25.
//

import Foundation

public struct FlowDocument: Codable {
    public let version: String
    public let sourceFile: SourceFileReference?
    public let metadata: DocumentMetadata
    public let nodeGraph: NodeGraph

    public init(sourceFileURL: URL? = nil) {
        self.version = "1.0"
        self.sourceFile = sourceFileURL.map { SourceFileReference(url: $0) }
        self.metadata = DocumentMetadata()
        self.nodeGraph = NodeGraph()
    }

    public init(version: String, sourceFile: SourceFileReference?, metadata: DocumentMetadata, nodeGraph: NodeGraph) {
        self.version = version
        self.sourceFile = sourceFile
        self.metadata = metadata
        self.nodeGraph = nodeGraph
    }
}

public struct NodeGraph: Codable {
    public var nodes: [NodeData]
    public var connections: [Connection]

    public init(nodes: [NodeData] = [], connections: [Connection] = []) {
        self.nodes = nodes
        self.connections = connections
    }
}

public struct SourceFileReference: Codable {
    public let originalPath: String
    public let fileName: String
    public let fileSize: Int64?
    public let lastModified: Date?

    public init(url: URL) {
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
    }
}

public struct DocumentMetadata: Codable {
    public let createdAt: Date
    public let lastModified: Date
    public let appVersion: String

    public init() {
        let now = Date()
        self.createdAt = now
        self.lastModified = now
        self.appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    public init(createdAt: Date, lastModified: Date, appVersion: String) {
        self.createdAt = createdAt
        self.lastModified = lastModified
        self.appVersion = appVersion
    }
}