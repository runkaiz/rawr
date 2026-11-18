import Testing
import Foundation
import Metal
import CoreImage
import ImageIO
import AppKit
import SwiftUI
import UniformTypeIdentifiers

@Suite(.serialized)
@MainActor
struct DustRemovalTests {
    private func context() throws -> ProcessingContext {
        let device = try #require(MTLCreateSystemDefaultDevice())
        return ProcessingContext(device: device, commandQueue: try #require(device.makeCommandQueue()), ciContext: CIContext(mtlDevice: device))
    }

    private func texture(_ pixels: [SIMD4<Float>], width: Int, context: ProcessingContext) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width, height: pixels.count / width, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        let t = try #require(context.device.makeTexture(descriptor: d))
        pixels.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, d.width, d.height), mipmapLevel: 0,
            withBytes: $0.baseAddress!, bytesPerRow: width * 16) }
        return t
    }

    private func read(_ texture: MTLTexture, context: ProcessingContext) async throws -> [SIMD4<Float>] {
        let half = texture.pixelFormat == .rgba16Float
        let row = texture.width * (half ? 8 : 16)
        let buffer = try #require(context.device.makeBuffer(length: row * texture.height))
        let command = try #require(context.commandQueue.makeCommandBuffer())
        let blit = try #require(command.makeBlitCommandEncoder())
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
            sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1), to: buffer,
            destinationOffset: 0, destinationBytesPerRow: row, destinationBytesPerImage: row * texture.height)
        blit.endEncoding()
        command.commit()
        await command.completed()
        try #require(command.status == .completed)
        if half {
            let p = buffer.contents().assumingMemoryBound(to: SIMD4<Float16>.self)
            return (0..<(texture.width * texture.height)).map { SIMD4<Float>(p[$0]) }
        }
        return Array(UnsafeBufferPointer(start: buffer.contents().assumingMemoryBound(to: SIMD4<Float>.self), count: texture.width * texture.height))
    }

    private func image(_ texture: MTLTexture, infrared: MTLTexture? = nil) -> ImageData {
        var metadata = ImageMetadata(width: texture.width, height: texture.height)
        metadata.domain = .linearTransmittance
        return ImageData(texture: texture, metadata: metadata, infraredTexture: infrared)
    }

    private func scene(width: Int = 128, height: Int = 96) -> [SIMD4<Float>] {
        (0..<(width * height)).map { i in
            let x = i % width, y = i / width
            let base: Float = x < width / 2 ? 0.3 : 0.7
            let grain = Float(sin(Double(x * 13 + y * 17))) * 0.006
            return SIMD4(repeating: base + grain) * SIMD4(1, 1, 1, 0) + SIMD4(0, 0, 0, 1)
        }
    }

    @Test func `Optical specks hairs and scratches repair while edges and clean grain stay intact`() async throws {
        let ctx = try context(), w = 128
        let clean = scene()
        var damaged = clean
        let specks = [20 * w + 20, 30 * w + 100]
        let hair = (45...56).map { $0 * w + 28 }
        let scratch = (85...96).map { 70 * w + $0 }
        let defects = specks + hair + scratch
        for i in specks + hair { damaged[i] = SIMD4(0.01, 0.01, 0.01, 1) }
        for i in scratch { damaged[i] = SIMD4(1, 1, 1, 1) }
        let source = try texture(damaged, width: w, context: ctx)
        let node = NodeData(type: .dustRemoval, position: .zero)
        let out = try #require(await DustRemovalProcessor(context: ctx).process(inputs: ["Input": image(source)], node: node, context: ctx))
        let repaired = try #require(out["Output"]), mask = try #require(out["Mask"])
        #expect(repaired.cgImage == nil && mask.cgImage == nil)
        #expect(repaired.texture.storageMode == .private)
        let pixels = try await read(repaired.texture, context: ctx)
        let scores = try await read(mask.texture, context: ctx)
        let detected = defects.filter { scores[$0].x > 0.9 }.count
        let error = defects.map { abs(pixels[$0].x - clean[$0].x) }.max()!
        let cleanIndices = clean.indices.filter { !defects.contains($0) }
        let changed = cleanIndices.filter { pixels[$0] != damaged[$0] }.count
        #expect(detected == defects.count)
        #expect(error < 0.03)
        #expect(changed == 0, "No edge or fine-grain pixels should change")
        #expect(pixels.allSatisfy { $0.w == 1 })
        Attachment.record("Detected \(detected)/\(defects.count); repaired max error \(error); clean changes \(changed)", named: "optical-accuracy")
    }

    @Test func `Infrared ratio detects faint defects and removes visible image ghost`() async throws {
        let ctx = try context(), w = 128
        let clean = scene()
        var damaged = clean
        var ir = clean.map { SIMD4<Float>(repeating: 0.5 + 0.4 * $0.x) }
        let index = 30 * w + 30
        damaged[index] -= SIMD4(0.06, 0.06, 0.06, 0)
        ir[index] -= SIMD4(repeating: 0.3)
        let rgb = try texture(damaged, width: w, context: ctx), infrared = try texture(ir, width: w, context: ctx)
        let processor = DustRemovalProcessor(context: ctx)
        var node = NodeData(type: .dustRemoval, position: .zero)
        node.parameters["sensitivity"] = 0.7
        let out = try #require(await processor.process(inputs: ["Input": image(rgb, infrared: infrared)], node: node, context: ctx))
        let mask = try await read(try #require(out["Mask"]).texture, context: ctx)
        let pixels = try await read(try #require(out["Output"]).texture, context: ctx)
        #expect(mask[index].x > 0.9)
        #expect(abs(pixels[index].x - clean[index].x) < 0.03)
        #expect(mask.enumerated().filter { $0.offset != index && $0.element.x > 0 }.isEmpty)
        node.parameters["useIR"] = 0
        let optical = try #require(await processor.process(inputs: ["Input": image(rgb, infrared: infrared)], node: node, context: ctx))
        let fallback = try #require(await processor.process(inputs: ["Input": image(rgb)], node: node, context: ctx))
        let a = try await read(try #require(optical["Output"]).texture, context: ctx)
        let b = try await read(try #require(fallback["Output"]).texture, context: ctx)
        #expect(a == b)
        #expect(a[index] == damaged[index], "IR drives detection of a mark below the RGB threshold")
    }

    @Test func `Manual points survive flow save load and feather the repaired footprint`() async throws {
        let ctx = try context(), w = 128
        var clean = scene(), damaged = clean
        let index = 40 * w + 30
        damaged[index] -= SIMD4(0.05, 0.05, 0.05, 0)
        var node = NodeData(type: .dustRemoval, position: .zero)
        node.healSpots = [HealSpot(x: 30.5 / 128, y: 40.5 / 96, radius: 0.025)]
        let flow = FlowDocument(version: "1.0", sourceFile: nil, metadata: DocumentMetadata(), nodeGraph: NodeGraph(nodes: [node]))
        let restored = try JSONDecoder().decode(FlowDocument.self, from: JSONEncoder().encode(flow))
        let saved = try #require(restored.nodeGraph.nodes.first)
        #expect(saved == node)
        let source = try texture(damaged, width: w, context: ctx)
        let out = try #require(await DustRemovalProcessor(context: ctx).process(inputs: ["Input": image(source)], node: saved, context: ctx))
        let pixels = try await read(try #require(out["Output"]).texture, context: ctx)
        let mask = try await read(try #require(out["Mask"]).texture, context: ctx)
        #expect(abs(pixels[index].x - clean[index].x) < 0.03)
        #expect(mask[index].x == 1)
        #expect(mask[index + 2].x > 0 && mask[index + 2].x < 1)
        #expect(mask[index + 3].x == 0)
        clean[index] = damaged[index]
        #expect(pixels[index + 3] == clean[index + 3])
        var old = NodeData(type: .exposure, position: .zero)
        old.parameters["stops"] = 1
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        json.removeValue(forKey: "healSpots")
        #expect(try JSONDecoder().decode(NodeData.self, from: JSONSerialization.data(withJSONObject: json)).healSpots.isEmpty)
    }

    @Test func `Invalid controls and mismatched infrared fail safely`() async throws {
        let ctx = try context()
        for values in [["sensitivity": Double.nan], ["size": 0], ["size": 99], ["irGhost": 2]] {
            #expect(DustParameters(values, infrared: false, spots: []) == nil)
        }
        #expect(DustParameters([:], infrared: false, spots: [HealSpot(x: 2, y: 0, radius: 0.01)]) == nil)
        let a = try texture(scene(), width: 128, context: ctx)
        let b = try texture([SIMD4<Float>(repeating: 1)], width: 1, context: ctx)
        #expect(await DustRemovalProcessor(context: ctx).process(inputs: ["Input": image(a, infrared: b)],
            node: NodeData(type: .dustRemoval, position: .zero), context: ctx) == nil)
        var disabled = NodeData(type: .dustRemoval, position: .zero)
        disabled.parameters["useIR"] = 0
        disabled.infraredURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(await DustRemovalProcessor(context: ctx).process(inputs: ["Input": image(a, infrared: b)],
            node: disabled, context: ctx) != nil)
    }

    @Test func `Dust controls and repaired preview render without opening a window`() async throws {
        let ctx = try context()
        var pixels = scene()
        pixels[40 * 128 + 30] = SIMD4(0, 0, 0, 1)
        let source = try texture(pixels, width: 128, context: ctx)
        var node = NodeData(type: .dustRemoval, position: .zero)
        node.healSpots = [HealSpot(x: 0.25, y: 0.4, radius: 0.01)]
        let output = try #require(await DustRemovalProcessor(context: ctx).process(inputs: ["Input": image(source)], node: node, context: ctx))
        let before = try #require(NegativeImageIO.boundaryImage(source, context: ctx.linearCIContext))
        let resultTexture = try #require(output["Output"]).texture
        let maskTexture = try #require(output["Mask"]).texture
        let after = try #require(NegativeImageIO.boundaryImage(resultTexture, context: ctx.linearCIContext))
        let mask = try #require(NegativeImageIO.boundaryImage(maskTexture, context: ctx.linearCIContext))
        let view = HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading) {
                Label("Dust Removal", systemImage: node.type.icon).font(.headline)
                DustRemovalControls(node: node, onParameters: { _ in }, onSpots: { _ in }, onInfrared: { _ in })
            }.frame(width: 245)
            VStack {
                Text("Before / Repaired / Mask")
                Image(decorative: before, scale: 1).resizable().interpolation(.none).scaledToFit().frame(width: 350, height: 190)
                Image(decorative: after, scale: 1).resizable().interpolation(.none).scaledToFit().frame(width: 350, height: 190)
                Image(decorative: mask, scale: 1).resizable().interpolation(.none).scaledToFit().frame(width: 350, height: 190)
            }
        }.padding().frame(width: 660, height: 760).background(.background)
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: 660, height: 760)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        Attachment.record(try #require(bitmap.representation(using: .png, properties: [:])), named: "dust-removal.png")
    }
}
