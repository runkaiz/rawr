import Foundation

extension RawrKit {
    /// Serialized with preview/export so source cache and resolution are owned
    /// by one operation. The UI explicitly installs the result in its document.
    @MainActor
    func measureRoll(_ graph: NodeGraph, nodeID: UUID) async -> RollBaseline? {
        var baseline: RollBaseline?
        _ = await enqueue {
            baseline = await self.measureRollNow(graph, nodeID: nodeID)
            return baseline != nil
        }
        return baseline
    }

    @MainActor
    private func measureRollNow(_ graph: NodeGraph, nodeID: UUID) async -> RollBaseline? {
        guard graph.validationError() == nil,
              let develop = graph.nodes.first(where: { $0.id == nodeID && $0.type == .negativeDevelop }),
              let path = Self.rollMeasurementPath(graph, nodeID: nodeID),
              let source = path.first,
              let folder = source.imageBookmark.flatMap({ self.resolveBookmark($0) }) ?? source.imageURL,
              let context = processingContext else {
            log("Roll measurement requires Folder Input, optionally through Dust Removal and Auto Crop", level: .error)
            return nil
        }
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        clearFolderCache()
        guard let urls = await scanFolderForImages(folderURL: folder), urls.count >= 3, urls.count <= 4096 else {
            log("Roll measurement requires 3–4096 frames", level: .error)
            return nil
        }
        let meter = NegativeMetering(context: context)
        var summaries: [NegativeMeteringResult] = []
        var identities: [RollFrame] = []
        let parameters = develop.parameters
        guard let manual = NegativeDevelopParameters(parameters) else { return nil }
        let cropper = AutoCropProcessor(context:context)
        let duster = DustRemovalProcessor(context:context)
        let started = Date()
        // Stream one full-resolution texture at a time. Never retain a whole
        // roll of images in unified memory; only 96-byte summaries accumulate.
        for url in urls {
            do {
                let identity = try RollFrame(url: url, included: false, densityShift: 0)
                var input = try NegativeImageIO.load(url: url, context: context)
                for node in path.dropFirst() {
                    let processor: any NodeProcessor = node.type == .autoCrop ? cropper : duster
                    guard let output = await processor.process(inputs:["Input":input],node:node,context:context)?["Output"] else {
                        throw CocoaError(.fileReadUnknown)
                    }
                    input = output
                }
                guard let output = await meter.analyze(input, parameters: parameters), identity.matches(url) else {
                    throw CocoaError(.fileReadUnknown)
                }
                var result = output.result
                if parameters["autoEndpoints"] == 0 {
                    result.low = manual.low; result.low.w = 1
                    result.high = manual.high; result.high.w = 1
                }
                if parameters["autoBalance"] == 0 {
                    result.offset = manual.balance; result.offset.w = 1
                    result.slope = manual.slope
                }
                summaries.append(result)
                identities.append(identity)
            } catch {
                log("Roll measurement failed for \(url.lastPathComponent): \(error.localizedDescription)", level: .error)
                return nil
            }
        }
        guard let reduction = await RollReduction.reduce(summaries, context: context),
              reduction.statistics.quality.x >= 3 else {
            log("Roll has fewer than three reliable frames; no baseline saved", level: .warning)
            return nil
        }
        // A folder edit during measurement invalidates the entire transaction.
        clearFolderCache()
        guard await scanFolderForImages(folderURL: folder) == urls,
              zip(identities, urls).allSatisfy({ pair in pair.0.matches(pair.1) }) else {
            log("Folder changed during roll measurement; try again", level: .warning)
            return nil
        }
        for i in identities.indices {
            identities[i].included = reduction.frames[i].x == 1
            identities[i].densityShift = reduction.frames[i].y
        }
        let r = reduction.statistics
        var calibration = NegativeDevelopParameters.defaults
        for group in ["Base", "Endpoints"] { calibration = r.locking(group, in: calibration) }
        if r.offset.w >= 0.5 {
            calibration = r.locking("Balance",in:calibration)
        } else {
            calibration["autoBalance"] = 1
            log("Roll: base and endpoints saved; insufficient neutral evidence for shared balance",level:.warning)
        }
        log("Roll: \(Int(r.quality.x))/\(urls.count) accepted, \(Date().timeIntervalSince(started)) seconds including decode")
        return RollBaseline(folder: folder, calibration: calibration,
            confidence: min(r.base.w, r.low.w), frames: identities)
    }

    /// Only supported transmission-preserving nodes may precede development.
    /// Graph validation handles cycles; visited also protects direct API calls.
    static func rollMeasurementPath(_ graph: NodeGraph, nodeID: UUID) -> [NodeData]? {
        var path = [NodeData](), current = nodeID, visited = Set<UUID>()
        while visited.insert(current).inserted {
            guard let edge = graph.connections.first(where:{ $0.toNodeId == current && $0.toInput == "Input" }),
                  edge.fromOutput != "Mask",
                  let node = graph.nodes.first(where:{ $0.id == edge.fromNodeId }) else { return nil }
            path.append(node)
            if node.type == .folderInput { return path.reversed() }
            guard node.type == .dustRemoval || node.type == .autoCrop else { return nil }
            current = node.id
        }
        return nil
    }
}
