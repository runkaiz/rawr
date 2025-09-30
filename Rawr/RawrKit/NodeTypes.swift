import Foundation
import SwiftUI

public enum NodeType: String, Codable, CaseIterable, Hashable {
    case imageInput = "Image Input"
    case inversion = "Inversion"
    case exposure = "Exposure"
    case gamma = "Gamma"
    case preview = "Preview"

    public var icon: String {
        switch self {
        case .imageInput: return "photo"
        case .inversion: return "circle.lefthalf.filled"
        case .exposure: return "sun.max"
        case .gamma: return "slider.horizontal.3"
        case .preview: return "eye"
        }
    }

    public var maxAllowedCount: Int? {
        switch self {
        case .imageInput: return 1
        case .preview: return 1
        case .inversion, .exposure, .gamma: return nil
        }
    }
}

public struct NodeData: Identifiable, Codable {
    public let id: UUID
    public var type: NodeType
    public var position: CGPoint
    public var inputs: [String] = []
    public var outputs: [String] = []
    public var imageURL: URL?
    public var imageBookmark: Data? // Security-scoped bookmark data
    public var parameters: [String: Double] = [:] // Node-specific parameters

    public init(id: UUID = UUID(), type: NodeType, position: CGPoint) {
        self.id = id
        self.type = type
        self.position = position

        switch type {
        case .imageInput:
            self.outputs = ["Image"]
        case .inversion:
            self.inputs = ["Input"]
            self.outputs = ["Output"]
        case .exposure:
            self.inputs = ["Input"]
            self.outputs = ["Output"]
            self.parameters = ["stops": 0.0] // Default: no exposure adjustment
        case .gamma:
            self.inputs = ["Input"]
            self.outputs = ["Output"]
            self.parameters = ["gamma": 2.2] // Default: sRGB standard gamma
        case .preview:
            self.inputs = ["Input"]
        }
    }
}

public struct Connection: Identifiable, Codable, Equatable {
    public let id: UUID
    public let fromNodeId: UUID
    public let fromOutput: String
    public let toNodeId: UUID
    public let toInput: String

    public init(id: UUID = UUID(), fromNodeId: UUID, fromOutput: String, toNodeId: UUID, toInput: String) {
        self.id = id
        self.fromNodeId = fromNodeId
        self.fromOutput = fromOutput
        self.toNodeId = toNodeId
        self.toInput = toInput
    }
}