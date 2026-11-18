import Foundation
import Testing
import Metal
import CoreImage
import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

@Suite(.serialized)
@MainActor
struct RollBaselineTests {
    private let automatic: [String: Double] = ["autoBase": 1, "autoEndpoints": 1, "autoBalance": 1]

    private func context() throws -> ProcessingContext {
        let device = try #require(MTLCreateSystemDefaultDevice())
        return ProcessingContext(device: device, commandQueue: try #require(device.makeCommandQueue()), ciContext: CIContext(mtlDevice: device))
    }

    private func fixture(_ context: ProcessingContext, shift: Float = 0, mode: Float = 0,
                         width: Int = 256, height: Int = 256, texture existing: MTLTexture? = nil) async throws -> ImageData {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .private; descriptor.usage = [.shaderRead, .shaderWrite]
        let texture = try #require(existing ?? context.device.makeTexture(descriptor: descriptor))
        let function = try #require(context.shaderLibrary?.makeFunction(name: "rollTestFixture"))
        let pipeline = try await context.device.makeComputePipelineState(function: function)
        let command = try #require(context.commandQueue.makeCommandBuffer())
        let encoder = try #require(command.makeComputeCommandEncoder())
        var config = SIMD4<Float>(shift, mode, 0, 0)
        encoder.setComputePipelineState(pipeline); encoder.setTexture(texture, index: 0)
        encoder.setBytes(&config, length: 16, index: 0)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding(); command.commit(); await command.completed()
        try #require(command.status == .completed)
        var metadata = ImageMetadata(width: width, height: height)
        metadata.domain = .linearTransmittance
        return ImageData(texture: texture, metadata: metadata)
    }

    private func read(_ texture: MTLTexture, context: ProcessingContext) async throws -> [SIMD4<Float>] {
        let buffer = try #require(context.device.makeBuffer(length: texture.width*texture.height*16))
        let command = try #require(context.commandQueue.makeCommandBuffer())
        let blit = try #require(command.makeBlitCommandEncoder())
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
            sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1), to: buffer,
            destinationOffset: 0, destinationBytesPerRow: texture.width*16, destinationBytesPerImage: texture.width*texture.height*16)
        blit.endEncoding(); command.commit(); await command.completed()
        return Array(UnsafeBufferPointer(start: buffer.contents().assumingMemoryBound(to: SIMD4<Float>.self), count: texture.width*texture.height))
    }

    private func baseline(_ reduction: RollReduction, urls: [URL]) throws -> RollBaseline {
        var calibration = NegativeDevelopParameters.defaults
        for group in ["Base", "Endpoints", "Balance"] { calibration = reduction.statistics.locking(group, in: calibration) }
        let frames = try urls.indices.map { i in
            try RollFrame(url: urls[i], included: reduction.frames[i].x == 1, densityShift: reduction.frames[i].y)
        }
        let r = reduction.statistics
        return RollBaseline(folder: urls[0].deletingLastPathComponent(), calibration: calibration,
            confidence: min(r.base.w, r.low.w, r.offset.w), frames: frames)
    }

    @Test func `GPU roll recovers shared calibration rejects outliers and matches exposed neutrals`() async throws {
        let ctx = try context(), meter = NegativeMetering(context: ctx)
        let shifts: [Float] = [-0.2, -0.1, 0, 0.1, 0.2, 0, 0, 0, 0]
        let modes: [Float] = [0, 0, 0, 0, 0, 1, 2, 3, 4]
        var inputs: [ImageData] = [], summaries: [NegativeMeteringResult] = []
        for i in shifts.indices {
            let input = try await fixture(ctx, shift: shifts[i], mode: modes[i])
            inputs.append(input)
            summaries.append(try #require(await meter.analyze(input, parameters: automatic)).result)
        }
        let reduction = try #require(await RollReduction.reduce(summaries, context: ctx)), r = reduction.statistics
        #expect(reduction.frames.map { $0.x } == [1,1,1,1,1,0,0,0,0])
        #expect(r.quality.x == 5)
        for c in 0..<3 { #expect(abs(r.base[c] - [Float(0.8),0.4,0.2][c]) < 0.004) }
        #expect(abs(r.offset.x - 0.12) < 0.006 && abs(r.offset.z + 0.05) < 0.006)
        #expect(abs(r.slope.x - 1.1) < 0.005 && abs(r.slope.z - 0.9) < 0.005)
        // Exact scene 1st/99th percentiles over the sampled interior, independent
        // of histogram implementation (pixel centers and a 5% border).
        #expect(abs(r.low.y - 0.4847656) < 0.01)
        #expect(abs(r.high.y - 1.7152344) < 0.01)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Roll-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = try inputs.indices.map { i -> URL in
            let url = root.appendingPathComponent("\(i).tiff"); try Data([UInt8(i)]).write(to: url); return url
        }
        let roll = try baseline(reduction, urls: urls)
        var outputs: [[SIMD4<Float>]] = []
        for i in 0..<5 {
            var metadata = inputs[i].metadata; metadata.sourceURL = urls[i]
            let input = ImageData(texture: inputs[i].texture, metadata: metadata)
            var node = NodeData(type: .negativeDevelop, position: .zero); node.rollBaseline = roll
            let output = try #require(await NegativeDevelopProcessor(context: ctx).process(inputs: ["Input": input], node: node, context: ctx)?["Output"])
            outputs.append(try await read(output.texture, context: ctx))
        }
        for output in outputs {
            for x in stride(from: 40, to: 210, by: 10) {
                let p = output[128*256+x], reference = outputs[2][128*256+x]
                #expect(abs(p.x-p.y) < 0.003 && abs(p.z-p.y) < 0.003)
                #expect(abs(p.y-reference.y) < 0.003)
            }
        }
        Attachment.record("Roll GPU baseline \(r), alignment \(reduction.frames)", named: "roll-reference")
    }

    @Test func `Insufficient reliable frames never create confident baselines`() async throws {
        let ctx = try context(), meter = NegativeMetering(context: ctx)
        let good = try #require(await meter.analyze(try await fixture(ctx), parameters: automatic)).result
        let blank = try #require(await meter.analyze(try await fixture(ctx, mode: 1), parameters: automatic)).result
        let r = try #require(await RollReduction.reduce([good,good,blank], context: ctx)).statistics
        #expect(r.base.w == 0 && r.low.w == 0 && r.offset.w == 0)
    }

    @Test func `Frame overrides trims opt out and version survive flow save load`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RollOverrides-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("frame.tiff"); try Data([0]).write(to: url)
        var values = NegativeDevelopParameters.defaults
        values["baseR"] = 0.8; values["highG"] = 1.8
        var roll = RollBaseline(folder: root, calibration: values, confidence: 0.9,
            frames: [try RollFrame(url: url, included: true, densityShift: 0.2)])
        roll.frames[0].exposure = 0.4
        var node = NodeData(type: .negativeDevelop, position: .zero); node.parameters["exposure"] = 0.2
        var p = try #require(roll.parameters(for: url, node: node.parameters))
        #expect(p["baseR"] == 0.8 && p["autoBase"] == 0)
        #expect(abs(p["exposure"]! - 0.6) < 1e-10 && p["rollDensityShift"] == Double(Float(0.2)))
        node.parameters["autoBase"] = 0; node.parameters["baseR"] = 0.9
        #expect(roll.parameters(for: url, node: node.parameters)?["baseR"] == 0.9)
        node.parameters["exposure"] = 8
        #expect(roll.parameters(for: url, node: node.parameters) == nil)
        node.parameters["exposure"] = 0.2
        roll.frames[0].overrides = ["baseR": 0.7, "exposure": -1]
        p = try #require(roll.parameters(for: url, node: node.parameters))
        #expect(p["baseR"] == 0.7 && p["autoBase"] == 0 && p["exposure"] == -1)
        roll.frames[0].optOut = true; roll.frames[0].overrides = [:]
        node.parameters["autoBase"] = 1
        p = try #require(roll.parameters(for: url, node: node.parameters))
        #expect(p["autoBase"] == 1 && p["rollDensityShift"] == 0)
        node.rollBaseline = roll
        let flow = FlowDocument(version: "1.0", sourceFile: nil, metadata: DocumentMetadata(), nodeGraph: NodeGraph(nodes: [node]))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(FlowDocument.self, from: encoder.encode(flow))
        #expect(decoded.nodeGraph.nodes.first?.rollBaseline == roll)
        roll.version = 99
        #expect(roll.parameters(for: url, node: node.parameters) == nil)
        roll.version = 1
        try Data([1,2]).write(to: url)
        #expect(roll.parameters(for: url, node: node.parameters) == nil)
        let old = Data("{\"nodes\":[],\"connections\":[]}".utf8)
        #expect(try JSONDecoder().decode(NodeGraph.self, from: old).nodes.isEmpty)
    }

    @Test func `Folder measurement persists and batch export uses the saved baseline`() async throws {
        let ctx = try context(), root = FileManager.default.temporaryDirectory.appendingPathComponent("RollBatch-\(UUID())")
        let inputs = root.appendingPathComponent("inputs"), output = root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<5 {
            let image = try await fixture(ctx, shift: Float(i-2)*0.1)
            let cg = try #require(NegativeImageIO.boundaryImage(image.texture, context: ctx.linearCIContext))
            let url = inputs.appendingPathComponent("frame\(i).tiff")
            let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, cg, nil); try #require(CGImageDestinationFinalize(destination))
        }
        let folder = NodeData(type: .folderInput, position: .zero)
        var source = folder; source.imageURL = inputs
        let develop = NodeData(type: .negativeDevelop, position: .zero), preview = NodeData(type: .preview, position: .zero)
        var graph = NodeGraph(nodes: [source, develop, preview], connections: [
            Connection(fromNodeId: source.id, fromOutput: "Image", toNodeId: develop.id, toInput: "Input"),
            Connection(fromNodeId: develop.id, fromOutput: "Output", toNodeId: preview.id, toInput: "Input")])
        let kit = RawrKit()
        let roll = try #require(await kit.measureRoll(graph, nodeID: develop.id))
        #expect(roll.frames.count == 5 && roll.frames.allSatisfy(\.included))
        let dust = NodeData(type:.dustRemoval,position:.zero), crop = NodeData(type:.autoCrop,position:.zero)
        let throughCleanup = NodeGraph(nodes:[source,dust,crop,develop,preview],connections:[
            Connection(fromNodeId:source.id,fromOutput:"Image",toNodeId:dust.id,toInput:"Input"),
            Connection(fromNodeId:dust.id,fromOutput:"Output",toNodeId:crop.id,toInput:"Input"),
            Connection(fromNodeId:crop.id,fromOutput:"Output",toNodeId:develop.id,toInput:"Input"),
            Connection(fromNodeId:develop.id,fromOutput:"Output",toNodeId:preview.id,toInput:"Input")])
        #expect(RawrKit.rollMeasurementPath(throughCleanup,nodeID:develop.id)?.map(\.id)==[source.id,dust.id,crop.id])
        let cleanedRoll = try #require(await kit.measureRoll(throughCleanup,nodeID:develop.id))
        #expect(cleanedRoll.frames.count==5 && cleanedRoll.frames.allSatisfy(\.included))
        graph.nodes[1].rollBaseline = roll
        for frame in roll.frames {
            #expect(roll.parameters(for: inputs.appendingPathComponent(frame.name), node: develop.parameters) != nil)
        }
        graph = try JSONDecoder().decode(NodeGraph.self, from: JSONEncoder().encode(graph))
        try #require(await kit.exportFolderBatch(graph, to: output, format: .tiff))
        let files = try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil).sorted { $0.path < $1.path }
        #expect(files.count == 5)
        var centers: [SIMD4<Float>] = []
        for url in files {
            let loaded = try NegativeImageIO.load(url: url, context: ctx)
            centers.append(try await read(loaded.texture, context: ctx)[128*256+128])
        }
        for p in centers {
            #expect(abs(p.x-p.y)<0.004 && abs(p.z-p.y)<0.004)
            #expect(abs(p.y-centers[2].y)<0.004)
        }
        // Existing calibration must be used, rather than silently metering again.
        graph.nodes[1].rollBaseline?.frames[0].exposure = -1
        let trimmed = root.appendingPathComponent("trimmed")
        try FileManager.default.createDirectory(at: trimmed, withIntermediateDirectories: true)
        try #require(await kit.exportFolderBatch(graph, to: trimmed, format: .tiff))
        let first = try #require(try FileManager.default.contentsOfDirectory(at: trimmed, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("frame0_") })
        let trimImage = try NegativeImageIO.load(url: first, context: ctx)
        let p = try await read(trimImage.texture, context: ctx)[128*256+128]
        #expect(abs(p.y-centers[0].y*0.5)<0.003)
        try Data([0]).write(to: inputs.appendingPathComponent("new.tiff"))
        let rejected = root.appendingPathComponent("rejected")
        try FileManager.default.createDirectory(at: rejected, withIntermediateDirectories: true)
        #expect(await kit.exportFolderBatch(graph, to: rejected, format: .tiff) == false)
        #expect(try FileManager.default.contentsOfDirectory(atPath: rejected.path).isEmpty)
    }

    @Test func `36 frame 24 MP roll records GPU and wall timings with bounded image memory`() async throws {
        let ctx = try context(), meter = NegativeMetering(context: ctx)
        var texture: MTLTexture?, summaries: [NegativeMeteringResult] = [], wall = 0.0, gpu = 0.0
        let totalStart = Date()
        for i in 0..<36 {
            let input = try await fixture(ctx, shift: Float(i%9-4)*0.05, width: 6000, height: 4000, texture: texture)
            texture = input.texture
            let start = Date()
            let result = try #require(await meter.analyze(input, parameters: automatic))
            wall += Date().timeIntervalSince(start); gpu += result.gpuSeconds; summaries.append(result.result)
        }
        let start = Date(), reduction = try #require(await RollReduction.reduce(summaries, context: ctx))
        let reduceWall = Date().timeIntervalSince(start)
        #expect(reduction.statistics.quality.x == 36)
        Attachment.record("36 x 24 MP (6000x4000), device \(ctx.device.name); metering wall \(wall)s, GPU \(gpu)s; roll reduction wall \(reduceWall)s GPU \(reduction.gpuSeconds)s; including GPU fixture generation \(Date().timeIntervalSince(totalStart))s. One reused 384 MB input texture; no decode/export in this benchmark.", named: "roll-36x24mp-performance")
    }

    @Test func `36 frame 24 MP folder measurement and TIFF batch export record end to end timings`() async throws {
        let ctx = try context(), root = FileManager.default.temporaryDirectory.appendingPathComponent("Roll36EndToEnd-\(UUID())")
        let inputs = root.appendingPathComponent("inputs"), output = root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var texture: MTLTexture?
        let fixtureStart = Date()
        for i in 0..<36 {
            let image = try await fixture(ctx, shift: Float(i%9-4)*0.05, width: 6000, height: 4000, texture: texture)
            texture = image.texture
            let url = inputs.appendingPathComponent(String(format: "frame%02d.tiff", i))
            try autoreleasepool {
                let cg = try #require(NegativeImageIO.boundaryImage(image.texture, context: ctx.linearCIContext))
                let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil))
                let properties = [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5]] as CFDictionary
                CGImageDestinationAddImage(destination, cg, properties)
                try #require(CGImageDestinationFinalize(destination))
            }
        }
        texture = nil
        let fixtureSeconds = Date().timeIntervalSince(fixtureStart)
        var source = NodeData(type: .folderInput, position: .zero); source.imageURL = inputs
        let develop = NodeData(type: .negativeDevelop, position: .zero), preview = NodeData(type: .preview, position: .zero)
        var graph = NodeGraph(nodes: [source, develop, preview], connections: [
            Connection(fromNodeId: source.id, fromOutput: "Image", toNodeId: develop.id, toInput: "Input"),
            Connection(fromNodeId: develop.id, fromOutput: "Output", toNodeId: preview.id, toInput: "Input")])
        let kit = RawrKit(), measureStart = Date()
        let roll = try #require(await kit.measureRoll(graph, nodeID: develop.id))
        let measurementSeconds = Date().timeIntervalSince(measureStart)
        #expect(roll.frames.count == 36 && roll.frames.allSatisfy(\.included))
        graph.nodes[1].rollBaseline = roll
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let flow = FlowDocument(version: "1.0", sourceFile: nil, metadata: DocumentMetadata(), nodeGraph: graph)
        graph = try decoder.decode(FlowDocument.self, from: encoder.encode(flow)).nodeGraph
        let exportStart = Date()
        try #require(await kit.exportFolderBatch(graph, to: output, format: .tiff))
        let exportSeconds = Date().timeIntervalSince(exportStart)
        let files = try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: [.fileSizeKey])
        #expect(files.count == 36)
        var bytes: Int64 = 0
        for url in files {
            let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
            let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            #expect((properties[kCGImagePropertyPixelWidth] as? Int) == 6000)
            #expect((properties[kCGImagePropertyPixelHeight] as? Int) == 4000)
            bytes += Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
        Attachment.record("36 x 24 MP TIFF files, device \(ctx.device.name); fixture generation/write \(fixtureSeconds)s (excluded); folder measurement incl decode \(measurementSeconds)s; batch export incl decode/develop/16-bit linear TIFF write \(exportSeconds)s; output bytes \(bytes). Saved .flow roundtrip before export. Synthetic smooth gradients, warm filesystem; no real-scan throughput claim.", named: "roll-36x24mp-end-to-end-performance")
    }

    @Test func `Roll and selected frame controls render without an app window`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RollUI-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("frame07.tiff"); try Data([0]).write(to: url)
        var calibration = NegativeDevelopParameters.defaults
        calibration.merge(["baseR": 0.8, "baseG": 0.4, "baseB": 0.2, "lowR": 0.2, "lowG": 0.2,
            "lowB": 0.2, "highR": 2.2, "highG": 2.2, "highB": 2.2,
            "balanceR": 0.12, "balanceB": -0.05, "slopeR": 1.1, "slopeB": 0.9]) { _, new in new }
        var roll = RollBaseline(folder: root, calibration: calibration, confidence: 0.92,
            frames: try (0..<36).map { i in
                var frame = try RollFrame(url: url, included: i < 33, densityShift: i < 33 ? 0.12 : 0)
                frame.name = String(format: "frame%02d.tiff", i)
                return frame
            })
        roll.frames[7].exposure = 0.25
        let view = VStack(alignment: .leading) {
            Text("Negative Develop").font(.headline)
            RollBaselineControls(baseline: roll, selectedName: "frame07.tiff", onMeasure: {}, onChange: { _ in })
            Divider()
            NegativeDevelopControls(parameters: automatic, statistics: roll.statistics, onChange: { _ in })
        }.padding().frame(width: 360).background(.white).environment(\.colorScheme, .light)
        // ImageRenderer cannot flatten AppKit-backed TextFields. Capture an
        // offscreen hosting view so native controls are visible, without a window.
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: 360, height: 900)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let cg = try #require(bitmap.cgImage)
        let canvas = try #require(CGContext(data: nil, width: cg.width, height: cg.height,
            bitsPerComponent: 8, bytesPerRow: cg.width*4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        canvas.setFillColor(CGColor(gray: 1, alpha: 1)); canvas.fill(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        canvas.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let flattened = try #require(canvas.makeImage())
        let png = try #require(NSBitmapImageRep(cgImage: flattened).representation(using: .png, properties: [:]))
        Attachment.record(png, named: "roll-consistency-controls.png")
        if let path = ProcessInfo.processInfo.environment["RAWR_PROOF_DIR"] {
            try png.write(to: URL(fileURLWithPath: path).appendingPathComponent("roll-consistency-controls.png"))
        }
    }
}
