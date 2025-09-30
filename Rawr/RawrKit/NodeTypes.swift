import Foundation
import SwiftUI

enum NodeType: String, Codable, CaseIterable, Hashable {
    case imageInput = "Image Input"
    case inversion = "Inversion"
    case preview = "Preview"

    var icon: String {
        switch self {
        case .imageInput: return "photo"
        case .inversion: return "circle.lefthalf.filled"
        case .preview: return "eye"
        }
    }

    var maxAllowedCount: Int? {
        switch self {
        case .imageInput: return 1
        case .preview: return 1
        case .inversion: return nil
        }
    }
}

struct NodeData: Identifiable, Codable {
    let id: UUID
    var type: NodeType
    var position: CGPoint
    var inputs: [String] = []
    var outputs: [String] = []
    var imageURL: URL?

    init(id: UUID = UUID(), type: NodeType, position: CGPoint) {
        self.id = id
        self.type = type
        self.position = position

        switch type {
        case .imageInput:
            self.outputs = ["Image"]
        case .inversion:
            self.inputs = ["Input"]
            self.outputs = ["Output"]
        case .preview:
            self.inputs = ["Input"]
        }
    }
}

struct Connection: Identifiable, Codable {
    let id: UUID
    let fromNodeId: UUID
    let fromOutput: String
    let toNodeId: UUID
    let toInput: String

    init(id: UUID = UUID(), fromNodeId: UUID, fromOutput: String, toNodeId: UUID, toInput: String) {
        self.id = id
        self.fromNodeId = fromNodeId
        self.fromOutput = fromOutput
        self.toNodeId = toNodeId
        self.toInput = toInput
    }
}