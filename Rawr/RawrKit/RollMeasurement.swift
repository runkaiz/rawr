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
              graph.nodes.contains(where: { $0.id == nodeID && $0.type == .negativeDevelop }),
              let edge = graph.connections.first(where: { $0.toNodeId == nodeID && $0.toInput == "Input" }),
              let source = graph.nodes.first(where: { $0.id == edge.fromNodeId && $0.type == .folderInput }),
              let folder = source.imageBookmark.flatMap({ self.resolveBookmark($0) }) ?? source.imageURL,
              let context = processingContext else {
            log("Roll measurement requires a direct Folder Input connection", level: .error)
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
        let automatic: [String: Double] = ["autoBase": 1, "autoEndpoints": 1, "autoBalance": 1]
        let started = Date()
        // Stream one full-resolution texture at a time. Never retain a whole
        // roll of images in unified memory; only 96-byte summaries accumulate.
        for url in urls {
            do {
                let identity = try RollFrame(url: url, included: false, densityShift: 0)
                let input = try NegativeImageIO.load(url: url, context: context)
                guard let output = await meter.analyze(input, parameters: automatic), identity.matches(url) else {
                    throw CocoaError(.fileReadUnknown)
                }
                summaries.append(output.result)
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
              zip(identities, urls).allSatisfy({ $0.matches($1) }) else {
            log("Folder changed during roll measurement; try again", level: .warning)
            return nil
        }
        for i in identities.indices {
            identities[i].included = reduction.frames[i].x == 1
            identities[i].densityShift = reduction.frames[i].y
        }
        let r = reduction.statistics
        var calibration = NegativeDevelopParameters.defaults
        for group in ["Base", "Endpoints", "Balance"] { calibration = r.locking(group, in: calibration) }
        log("Roll: \(Int(r.quality.x))/\(urls.count) accepted, \(Date().timeIntervalSince(started)) seconds including decode")
        return RollBaseline(folder: folder, calibration: calibration,
            confidence: min(r.base.w, r.low.w, r.offset.w), frames: identities)
    }
}
