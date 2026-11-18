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

    /// Runtime invalidation key for processing. Canvas placement changes the
    /// document layout without changing any image pixels; all controls, spots,
    /// calibration, sources, ports and wiring still invalidate the preview.
    public var processingRevision: Int {
        var hasher = Hasher()
        hasher.combine(nodes.count)
        for var node in nodes {
            node.position = .zero
            hasher.combine(node)
        }
        hasher.combine(connections.count)
        for edge in connections {
            hasher.combine(edge.id)
            hasher.combine(edge.fromNodeId)
            hasher.combine(edge.fromOutput)
            hasher.combine(edge.toNodeId)
            hasher.combine(edge.toInput)
        }
        return hasher.finalize()
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

extension NodeGraph {
    /// Validate the whole document, including disconnected cycles, before any processor runs.
    func validationError() -> String? {
        var nodesByID: [UUID: NodeData] = [:]
        for node in nodes {
            guard nodesByID.updateValue(node, forKey: node.id) == nil else {
                return "Invalid graph: duplicate node IDs."
            }
        }
        var incoming = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, 0) })
        var downstream: [UUID: [UUID]] = [:]
        var occupied: [UUID: Set<String>] = [:]
        for connection in connections {
            guard let source = nodesByID[connection.fromNodeId],
                  let target = nodesByID[connection.toNodeId],
                  source.outputs.contains(connection.fromOutput),
                  target.inputs.contains(connection.toInput) else {
                return "Invalid graph: a connection references a missing node or port."
            }
            guard occupied[target.id, default: []].insert(connection.toInput).inserted else {
                return "Invalid graph: multiple connections to the same input."
            }
            incoming[target.id, default: 0] += 1
            downstream[source.id, default: []].append(target.id)
        }
        var ready = nodes.filter { incoming[$0.id] == 0 }.map(\.id)
        var cursor = 0
        while cursor < ready.count {
            let id = ready[cursor]
            cursor += 1
            for target in downstream[id, default: []] {
                incoming[target, default: 0] -= 1
                if incoming[target] == 0 { ready.append(target) }
            }
        }
        return ready.count == nodes.count ? nil : "Invalid graph: cycle detected. Remove cyclic connections before executing."
    }
}
