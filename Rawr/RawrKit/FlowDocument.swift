//
//  FlowDocument.swift
//  Rawr
//
//  Created by Claude on 9/29/25.
//

import Foundation
import CoreImage

struct FlowDocument: Codable {
    let version: String
    let sourceFile: SourceFileReference?
    let editHistory: [EditOperation]
    let metadata: DocumentMetadata
    let nodeGraph: NodeGraph

    init(sourceFileURL: URL? = nil) {
        self.version = "1.0"
        self.sourceFile = sourceFileURL.map { SourceFileReference(url: $0) }
        self.editHistory = []
        self.metadata = DocumentMetadata()
        self.nodeGraph = NodeGraph()
    }

    init(version: String, sourceFile: SourceFileReference?, editHistory: [EditOperation], metadata: DocumentMetadata, nodeGraph: NodeGraph) {
        self.version = version
        self.sourceFile = sourceFile
        self.editHistory = editHistory
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

enum EditOperation: Codable {
    case exposure(ExposureAdjustment)
    case contrast(ContrastAdjustment)
    case saturation(SaturationAdjustment)
    case crop(CropOperation)
    case rotate(RotateOperation)
    case whiteBalance(WhiteBalanceAdjustment)

    var id: UUID {
        switch self {
        case .exposure(let adj): return adj.id
        case .contrast(let adj): return adj.id
        case .saturation(let adj): return adj.id
        case .crop(let op): return op.id
        case .rotate(let op): return op.id
        case .whiteBalance(let adj): return adj.id
        }
    }

    var timestamp: Date {
        switch self {
        case .exposure(let adj): return adj.timestamp
        case .contrast(let adj): return adj.timestamp
        case .saturation(let adj): return adj.timestamp
        case .crop(let op): return op.timestamp
        case .rotate(let op): return op.timestamp
        case .whiteBalance(let adj): return adj.timestamp
        }
    }
}

struct ExposureAdjustment: Codable {
    let id = UUID()
    let timestamp = Date()
    let stops: Float
}

struct ContrastAdjustment: Codable {
    let id = UUID()
    let timestamp = Date()
    let value: Float
}

struct SaturationAdjustment: Codable {
    let id = UUID()
    let timestamp = Date()
    let value: Float
}

struct CropOperation: Codable {
    let id = UUID()
    let timestamp = Date()
    let rect: CGRect
}

struct RotateOperation: Codable {
    let id = UUID()
    let timestamp = Date()
    let degrees: Float
}

struct WhiteBalanceAdjustment: Codable {
    let id = UUID()
    let timestamp = Date()
    let temperature: Float
    let tint: Float
}