import Foundation
import SwiftUI

public enum NodeType: String, Codable, CaseIterable, Hashable {
    case imageInput = "Image Input"
    case inversion = "Inversion"
    case exposure = "Exposure"
    case gamma = "Gamma"
    case denoise = "Denoise"
    case combination = "Combination"
    case preview = "Preview"

    public var icon: String {
        switch self {
        case .imageInput: return "photo"
        case .inversion: return "circle.lefthalf.filled"
        case .exposure: return "sun.max"
        case .gamma: return "slider.horizontal.3"
        case .denoise: return "waveform.path"
        case .combination: return "square.stack.3d.down.right"
        case .preview: return "eye"
        }
    }

    public var maxAllowedCount: Int? {
        switch self {
        case .imageInput: return 1
        case .preview: return 1
        case .inversion, .exposure, .gamma, .denoise, .combination: return nil
        }
    }
}

public struct NodeData: Identifiable, Codable, Equatable, Hashable {
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
        case .denoise:
            self.inputs = ["Input"]
            self.outputs = ["Output"]
            self.parameters = ["strength": 1.0, "colorSigma": 0.2] // Default: moderate denoising
        case .combination:
            self.inputs = ["Input A", "Input B"]
            self.outputs = ["Output"]
        case .preview:
            self.inputs = ["Input"]
        }
    }

    // Custom decoder to ensure nodes loaded from old documents have correct inputs/outputs
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        type = try container.decode(NodeType.self, forKey: .type)
        position = try container.decode(CGPoint.self, forKey: .position)
        imageURL = try container.decodeIfPresent(URL.self, forKey: .imageURL)
        imageBookmark = try container.decodeIfPresent(Data.self, forKey: .imageBookmark)
        parameters = try container.decodeIfPresent([String: Double].self, forKey: .parameters) ?? [:]

        // Ignore decoded inputs/outputs and set expected values based on type (migration for old documents)
        _ = try container.decodeIfPresent([String].self, forKey: .inputs)
        _ = try container.decodeIfPresent([String].self, forKey: .outputs)

        // Set expected inputs/outputs based on type
        switch type {
        case .imageInput:
            outputs = ["Image"]
        case .inversion:
            inputs = ["Input"]
            outputs = ["Output"]
        case .exposure:
            inputs = ["Input"]
            outputs = ["Output"]
            if parameters["stops"] == nil {
                parameters["stops"] = 0.0
            }
        case .gamma:
            inputs = ["Input"]
            outputs = ["Output"]
            if parameters["gamma"] == nil {
                parameters["gamma"] = 2.2
            }
        case .denoise:
            inputs = ["Input"]
            outputs = ["Output"]
            if parameters["strength"] == nil {
                parameters["strength"] = 1.0
            }
            if parameters["colorSigma"] == nil {
                parameters["colorSigma"] = 0.2
            }
        case .combination:
            inputs = ["Input A", "Input B"]
            outputs = ["Output"]
        case .preview:
            inputs = ["Input"]
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