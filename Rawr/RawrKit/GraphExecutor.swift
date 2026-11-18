import Foundation
import Metal

/// Executes a node graph, handling dependency resolution and data flow
public actor GraphExecutor {
    private let context: ProcessingContext
    private var processors: [NodeType: NodeProcessor] = [:]
    private var executing = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var remainingConsumers: [UUID: Int] = [:]
    private var executionCache: [UUID: [String: ImageData]] = [:]

    public init(context: ProcessingContext) {
        self.context = context
        self.processors = GraphExecutor.defaultProcessors(context: context)
        context.log("Registered default processors (\(processors.count))")
    }

    /// Register a processor for a specific node type
    public func registerProcessor(_ processor: NodeProcessor) {
        processors[processor.nodeType] = processor
        context.log("Registered processor for node type: \(processor.nodeType.rawValue)")
    }

    private static func defaultProcessors(context: ProcessingContext) -> [NodeType: NodeProcessor] {
        var dict: [NodeType: NodeProcessor] = [:]
        let defaults: [NodeProcessor] = [
            ImageInputProcessor(),
            FolderInputProcessor(),
            InversionProcessor(context: context),
            NegativeDevelopProcessor(context: context),
            DustRemovalProcessor(context: context),
            AutoCropProcessor(context: context),
            ExposureProcessor(context: context),
            GammaProcessor(context: context),
            DenoiseProcessor(context: context),
            SharpeningProcessor(context: context),
            CombinationProcessor(context: context),
            PreviewProcessor()
        ]
        for processor in defaults {
            dict[processor.nodeType] = processor
        }
        return dict
    }

    /// Execute the entire node graph
    /// - Parameters:
    ///   - nodeGraph: The graph to execute
    /// - Returns: Dictionary of Preview node outputs (node ID -> output images)
    public func execute(nodeGraph: NodeGraph) async -> [UUID: [String: ImageData]] {
        await acquire()
        defer { release() }
        executionCache.removeAll()
        defer { executionCache.removeAll() }
        if let error = nodeGraph.validationError() {
            context.log(error, level: .error)
            return [:]
        }
        var reachable: Set<UUID> = []
        func visit(_ id: UUID) {
            guard reachable.insert(id).inserted else { return }
            for edge in nodeGraph.connections where edge.toNodeId == id { visit(edge.fromNodeId) }
        }
        for node in nodeGraph.nodes where node.type == .preview { visit(node.id) }
        context.requestedMasks = Set(nodeGraph.connections.filter {
            $0.fromOutput == "Mask" && reachable.contains($0.toNodeId)
        }.map(\.fromNodeId))
        defer { context.requestedMasks = nil }
        remainingConsumers = [:]
        for edge in nodeGraph.connections where reachable.contains(edge.toNodeId) {
            remainingConsumers[edge.fromNodeId, default: 0] += 1
        }
        // Both cleanup and development operate on full-size linear float sources.
        context.negativeInputIDs = []
        for node in nodeGraph.nodes where node.type == .negativeDevelop || node.type == .dustRemoval || node.type == .autoCrop {
            var current = node
            while true {
                guard let edge = nodeGraph.connections.first(where: { $0.toNodeId == current.id && $0.toInput == "Input" }),
                      let source = nodeGraph.nodes.first(where: { $0.id == edge.fromNodeId }),
                      edge.fromOutput != "Mask" else {
                    context.log("Cleanup/development requires a source through cleanup/crop Output", level: .error)
                    return [:]
                }
                if source.type == .imageInput || source.type == .folderInput {
                    context.negativeInputIDs.insert(source.id)
                    break
                }
                guard source.type == .dustRemoval || source.type == .autoCrop else {
                    context.log("Cleanup/development requires linear source data; place it before legacy effects", level: .error)
                    return [:]
                }
                current = source
            }
        }
        context.log("Starting graph execution with \(nodeGraph.nodes.count) nodes")

        var previewOutputs: [UUID: [String: ImageData]] = [:]

        // Find all preview nodes
        let previewNodes = nodeGraph.nodes.filter { $0.type == .preview }

        for previewNode in previewNodes {
            context.log("Executing path to preview node: \(previewNode.id)")
            if let outputs = await executeNode(previewNode, in: nodeGraph) {
                previewOutputs[previewNode.id] = outputs
            }
        }

        context.log("Graph execution completed. \(previewOutputs.count) preview outputs generated.")
        return previewOutputs
    }

    /// Execute a single node and all its dependencies recursively
    private func executeNode(_ node: NodeData, in graph: NodeGraph) async -> [String: ImageData]? {
        // Check cache first
        if let cachedOutputs = executionCache[node.id] {
            context.log("Using cached output for node: \(node.type.rawValue)")
            return cachedOutputs
        }

        context.log("Executing node: \(node.type.rawValue) (\(node.id))")

        // Get the processor for this node type
        guard let processor = processors[node.type] else {
            context.log("No processor registered for node type: \(node.type.rawValue)", level: .error)
            return nil
        }

        // Gather inputs by executing upstream nodes
        var inputs: [String: ImageData] = [:]

        for inputName in node.inputs {
            // Find the connection that provides this input
            if let connection = graph.connections.first(where: { $0.toNodeId == node.id && $0.toInput == inputName }) {
                // Find the source node
                if let sourceNode = graph.nodes.first(where: { $0.id == connection.fromNodeId }) {
                    // Execute the source node recursively
                    if let sourceOutputs = await executeNode(sourceNode, in: graph) {
                        // Get the specific output we need
                        if let imageData = sourceOutputs[connection.fromOutput] {
                            inputs[inputName] = imageData
                            context.log("  Input '\(inputName)' provided by \(sourceNode.type.rawValue)")
                        } else {
                            context.log("  Source node did not produce output '\(connection.fromOutput)'", level: .warning)
                        }
                    } else {
                        context.log("  Failed to execute source node: \(sourceNode.type.rawValue)", level: .error)
                    }
                } else {
                    context.log("  Source node not found for connection", level: .error)
                }
            } else {
                context.log("  No connection found for input '\(inputName)'", level: .warning)
            }
        }

        defer {
            // Once all reachable consumers have encoded/completed, release the
            // ancestor. Branches keep their input until the final consumer.
            for edge in graph.connections where edge.toNodeId == node.id {
                remainingConsumers[edge.fromNodeId, default: 1] -= 1
                if remainingConsumers[edge.fromNodeId] == 0 { executionCache.removeValue(forKey: edge.fromNodeId) }
            }
        }
        // Validate inputs
        guard processor.canProcess(inputs: inputs, node: node) else {
            context.log("Node cannot be processed with available inputs", level: .error)
            return nil
        }

        // Execute the processor
        guard let outputs = await processor.process(inputs: inputs, node: node, context: context) else {
            context.log("Processor failed to produce outputs", level: .error)
            return nil
        }

        // Cache the outputs
        executionCache[node.id] = outputs
        context.log("Node execution successful, produced \(outputs.count) outputs")

        return outputs
    }

    /// Clear the execution cache (useful when graph changes)
    public func clearCache() async {
        await acquire()
        defer { release() }
        executionCache.removeAll()
        for processor in processors.values {
            (processor as? DustRemovalProcessor)?.clearCache()
        }
        context.log("Execution cache cleared")
    }
    private func acquire() async {
        if executing { await withCheckedContinuation { waiters.append($0) } }
        else { executing = true }
    }

    private func release() {
        if waiters.isEmpty { executing = false }
        else { waiters.removeFirst().resume() }
    }

}
