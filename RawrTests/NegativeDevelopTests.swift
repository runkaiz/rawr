import Foundation
import Testing
import CoreImage
import Metal
import ImageIO
import SwiftUI
import AppKit
import UniformTypeIdentifiers

@Suite(.serialized)
@MainActor
struct NegativeDevelopTests {
    private func context() throws -> ProcessingContext {
        let device = try #require(MTLCreateSystemDefaultDevice())
        return ProcessingContext(device: device, commandQueue: try #require(device.makeCommandQueue()),
            ciContext: CIContext(mtlDevice: device, options: [.workingFormat: CIFormat.RGBAf]))
    }

    // Independent Float64 oracle: scalar Foundation log/pow and Hermite basis,
    // rather than the shader's factorized cubic. Never calls production math.
    private func reference(_ input: Float, channel: String, values: [String: Double]) -> Double {
        let p = values.merging(NegativeDevelopParameters.defaults) { saved, _ in saved }
        var sample = Double(input)
        if sample.isNaN || sample < 0 { sample = 0 }
        let ratio = min(1, max(0.000001, sample / p["base" + channel]!))
        let d = -log10(ratio)
        var x = min(1, max(0, (d - p["low" + channel]!) / (p["high" + channel]! - p["low" + channel]!)))
        x = min(1, max(0, x * pow(2, p["exposure"]!)))
        x = min(1, max(0, 0.5 + p["contrast"]! * (x - 0.5)))
        let h01 = -2 * pow(x, 3) + 3 * pow(x, 2)
        let h10 = pow(x, 3) - 2 * pow(x, 2) + x
        let h11 = pow(x, 3) - pow(x, 2)
        return h01 + h10 * (1 - p["toe"]!) + h11 * (1 - p["shoulder"]!)
    }

    private func develop(_ pixels: [SIMD4<Float>], parameters: [String: Double] = [:]) async throws -> [SIMD4<Float>] {
        let ctx = try context()
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: pixels.count, height: 1, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        let texture = try #require(ctx.device.makeTexture(descriptor: descriptor))
        pixels.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, pixels.count, 1), mipmapLevel: 0,
            withBytes: $0.baseAddress!, bytesPerRow: pixels.count * 16) }
        var metadata = ImageMetadata(width: pixels.count, height: 1)
        metadata.domain = .linearTransmittance
        var node = NodeData(type: .negativeDevelop, position: .zero)
        node.parameters.merge(parameters) { _, new in new }
        let output = try #require(await NegativeDevelopProcessor(context: ctx).process(
            inputs: ["Input": ImageData(texture: texture, metadata: metadata)], node: node, context: ctx)?["Output"])
        #expect(output.cgImage == nil, "Development must not read back the image")
        #expect(output.texture.pixelFormat == .rgba32Float)
        #expect(output.metadata.domain == .positiveLinear)
        // Test-only readback through a shared staging buffer, since production is private.
        let buffer = try #require(ctx.device.makeBuffer(length: pixels.count * 16))
        let command = try #require(ctx.commandQueue.makeCommandBuffer())
        let blit = try #require(command.makeBlitCommandEncoder())
        blit.copy(from: output.texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
            sourceSize: MTLSize(width: pixels.count, height: 1, depth: 1), to: buffer, destinationOffset: 0,
            destinationBytesPerRow: pixels.count * 16, destinationBytesPerImage: pixels.count * 16)
        blit.endEncoding()
        command.commit()
        await command.completed()
        try #require(command.status == .completed)
        return Array(UnsafeBufferPointer(start: buffer.contents().assumingMemoryBound(to: SIMD4<Float>.self), count: pixels.count))
    }

    @Test(arguments: [false, true])
    func `Neutral and orange base wedges subtract to neutral monotone density`(orange: Bool) async throws {
        let base = orange ? SIMD3<Float>(0.8, 0.4, 0.2) : SIMD3<Float>(repeating: 1)
        let parameters = ["baseR": Double(base.x), "baseG": Double(base.y), "baseB": Double(base.z)]
        let pixels = (0...100).map { index -> SIMD4<Float> in
            let t = Float(pow(10, -Double(index) / 50))
            return SIMD4(base.x * t, base.y * t, base.z * t, 1)
        }
        let output = try await develop(pixels, parameters: parameters)
        var error = 0.0
        for (index, value) in output.enumerated() {
            error = max(error, abs(Double(value.x) - Double(index) / 100))
            #expect(abs(value.x - value.y) < 1e-6)
            #expect(abs(value.x - value.z) < 1e-6)
            if index > 0 { #expect(value.x > output[index - 1].x) }
        }
        #expect(error < 1e-5)
        Attachment.record("Wedge maximum absolute error: \(error)", named: orange ? "orange-wedge-error" : "neutral-wedge-error")
    }

    @Test func `Float32 shader agrees with independent Float64 reference across print controls`() async throws {
        var maxError = 0.0
        // Unequal ranges exercise per-layer normalization, negative densities,
        // exposure clipping, all curve corners, and densely sampled interiors.
        for toe in [0.0, 0.25, 0.5] {
            for shoulder in [0.0, 0.5] {
                for exposure in [-1.3, 0, 0.7] {
                    let p = ["baseR": 0.8, "baseG": 0.45, "baseB": 0.19,
                        "lowR": -0.1, "lowG": 0.1, "lowB": 0.3,
                        "highR": 2.7, "highG": 3.2, "highB": 4.1,
                        "exposure": exposure, "contrast": 1.17, "toe": toe, "shoulder": shoulder]
                    let pixels = (0...512).map { i -> SIMD4<Float> in
                        let t = Float(pow(10, -Double(i) / 100))
                        return SIMD4(t, t * 0.45, t * 0.19, 1)
                    }
                    let output = try await develop(pixels, parameters: p)
                    for i in pixels.indices {
                        for (c, channel) in ["R", "G", "B"].enumerated() {
                            maxError = max(maxError, abs(Double(output[i][c]) - reference(pixels[i][c], channel: channel, values: p)))
                            #expect(output[i][c].isFinite)
                            if i > 0 { #expect(output[i][c] >= output[i - 1][c]) }
                        }
                    }
                }
            }
        }
        #expect(maxError <= 1e-5)
        Attachment.record("Float64 reference maximum absolute error: \(maxError); limit 1e-5", named: "float-reference-error")
    }

    @Test func `Zero clipped NaN infinity and alpha follow the finite policy`() async throws {
        let samples: [Float] = [0, -1, .nan, -.infinity, .infinity, 1, 2, 1e-12, 1e-6]
        let pixels = samples.map { SIMD4<Float>($0, $0, $0, 1) } + [
            SIMD4(0.05, 0.05, 0.05, 0.5), SIMD4(0, 0, 0, 0), SIMD4(0, 0, 0, .nan)]
        let output = try await develop(pixels)
        for i in samples.indices {
            #expect(abs(Double(output[i].x) - reference(samples[i], channel: "R", values: [:])) < 1e-5)
            #expect(output[i].w == 1)
        }
        #expect(abs(output[samples.count].x - 0.25) < 1e-5)
        #expect(output[samples.count + 1] == .zero)
        #expect(output[samples.count + 2] == .zero)
        #expect(output.allSatisfy { pixel in (0..<4).allSatisfy { pixel[$0].isFinite && pixel[$0] >= 0 && pixel[$0] <= 1 } })
    }

    @Test func `Invalid calibrations fail and documents preserve legacy inversion`() throws {
        for invalid in [["baseR": 0], ["baseG": Double.nan], ["highB": 0], ["lowR": 3], ["contrast": -1], ["toe": 1], ["exposure": 9]] {
            #expect(NegativeDevelopParameters(invalid) == nil)
        }
        let node = NodeData(type: .negativeDevelop, position: .zero)
        let decoded = try JSONDecoder().decode(NodeData.self, from: JSONEncoder().encode(node))
        #expect(decoded == node)
        let inversion = NodeData(type: .inversion, position: .zero)
        #expect(inversion.parameters.isEmpty)
        #expect(try JSONDecoder().decode(NodeData.self, from: JSONEncoder().encode(inversion)) == inversion)
    }

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("NegativeTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func graph(_ url: URL, folder: Bool = false) -> NodeGraph {
        var input = NodeData(type: folder ? .folderInput : .imageInput, position: .zero)
        input.imageURL = url
        var negative = NodeData(type: .negativeDevelop, position: CGPoint(x: 210, y: 0))
        negative.parameters.merge(["baseR": 0.8, "baseG": 0.4, "baseB": 0.2, "toe": 0.2, "shoulder": 0.3]) { _, new in new }
        let preview = NodeData(type: .preview, position: CGPoint(x: 510, y: 0))
        return NodeGraph(nodes: [input, negative, preview], connections: [
            Connection(fromNodeId: input.id, fromOutput: "Image", toNodeId: negative.id, toInput: "Input"),
            Connection(fromNodeId: negative.id, fromOutput: "Output", toNodeId: preview.id, toInput: "Input")])
    }

    private func writeFixture(_ url: URL, orientation: Int = 1) throws {
        let width = 256, height = 128
        var pixels = [SIMD4<Float>]()
        for y in 0..<height {
            for x in 0..<width {
                let density = 0.1 + 1.8 * Double(x) / Double(width - 1)
                let t = Float(pow(10, -density))
                let tint: Float = y < height / 2 ? 1 : 0.5
                pixels.append(SIMD4(0.8 * t, 0.4 * t * tint, 0.2 * t, 1))
            }
        }
        let data = pixels.withUnsafeBytes { Data($0) }
        let image = CIImage(bitmapData: data, bytesPerRow: width * 16, size: CGSize(width: width, height: height),
            format: .RGBAf, colorSpace: NegativeImageIO.colorSpace)
        let cg = try #require(try context().ciContext.createCGImage(image, from: image.extent, format: .RGBA16, colorSpace: NegativeImageIO.colorSpace))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cg, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
    }

    private func floatPixels(_ image: CGImage, context: CIContext) -> [Float] {
        var result = [Float](repeating: 0, count: image.width * image.height * 4)
        context.render(CIImage(cgImage: image), toBitmap: &result, rowBytes: image.width * 16,
            bounds: CGRect(x: 0, y: 0, width: image.width, height: image.height), format: .RGBAf, colorSpace: NegativeImageIO.colorSpace)
        return result
    }

    @Test func `Preview equals resampled full export with matching profile orientation and crop`() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("orange.tiff")
        try writeFixture(input, orientation: 6)
        let kit = RawrKit()
        kit.maxPreviewDimension = 64
        let flow = graph(input)
        try #require(await kit.executeGraph(flow))
        let preview = try #require(kit.processedPreviewImage)
        #expect(preview.width == 32 && preview.height == 64)
        let url = root.appendingPathComponent("positive.tiff")
        try #require(await kit.exportImage(flow, to: url))
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let exported = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(exported.width == 128 && exported.height == 256)
        #expect(exported.bitsPerComponent == 16)
        #expect(!exported.bitmapInfo.contains(.floatComponents))
        let profile = try #require(exported.colorSpace)
        #expect(profile.model == .rgb)
        #expect(CGColorSpaceCopyICCData(profile) != nil) // ImageIO rehydrates an ICC profile with no built-in name.
        let ctx = try context()
        let scaled = CIImage(cgImage: exported).applyingFilter("CILanczosScaleTransform",
            parameters: [kCIInputScaleKey: 0.25, kCIInputAspectRatioKey: 1])
        let resampled = try #require(ctx.ciContext.createCGImage(scaled, from: scaled.extent, format: .RGBA16,
            colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!))
        let actual = floatPixels(preview, context: ctx.ciContext)
        let expected = floatPixels(resampled, context: ctx.ciContext)
        let error = zip(actual, expected).map { abs($0 - $1) }.max() ?? 0
        #expect(error <= 4.0 / 65535.0)
        // Compare full-size develop pixels to an independently oriented source
        // so a matching but inverted preview/export pair cannot pass unnoticed.
        let originalSource = try #require(CGImageSourceCreateWithURL(input as CFURL, nil))
        let original = try #require(CGImageSourceCreateImageAtIndex(originalSource, 0, nil))
        let oriented = CIImage(cgImage: original).oriented(forExifOrientation: 6)
        var negativePixels = [Float](repeating: 0, count: exported.width * exported.height * 4)
        ctx.ciContext.render(oriented, toBitmap: &negativePixels, rowBytes: exported.width * 16,
            bounds: oriented.extent, format: .RGBAf, colorSpace: NegativeImageIO.colorSpace)
        let positivePixels = floatPixels(exported, context: ctx.ciContext)
        var orientationError = 0.0
        for i in stride(from: 0, to: negativePixels.count, by: 4) {
            for (c, channel) in ["R", "G", "B"].enumerated() {
                orientationError = max(orientationError, abs(Double(positivePixels[i + c]) - reference(negativePixels[i + c], channel: channel, values: flow.nodes[1].parameters)))
            }
        }
        #expect(orientationError < 4.0 / 65535.0)
        Attachment.record("Preview/full max error: \(error); orientation/reference max error: \(orientationError)", named: "preview-export-error")
        // Exercise the folder source with exactly the same linear decode contract.
        let folder = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: input, to: folder.appendingPathComponent("orange.tiff"))
        try #require(await kit.executeGraph(graph(folder, folder: true)))
        #expect(kit.processedPreviewImage?.width == 32)
    }

    @Test func `Camera RAW uses characterized linear float path at native size`() async throws {
        let ctx = try context()
        let bundle = Bundle(for: NegativeTestBundle.self)
        let url = try #require(bundle.url(forResource: "sensor", withExtension: "dng", subdirectory: "Fixtures")
            ?? bundle.url(forResource: "sensor", withExtension: "dng"))
        let input = try NegativeImageIO.load(url: url, context: ctx)
        #expect(input.texture.width == 256 && input.texture.height == 256)
        #expect(input.texture.pixelFormat == .rgba32Float)
        #expect(input.cgImage == nil)
        var node = NodeData(type: .negativeDevelop, position: .zero)
        node.parameters["baseR"] = 0.8
        let output = await NegativeDevelopProcessor(context: ctx).process(inputs: ["Input": input], node: node, context: ctx)
        #expect(output?["Output"]?.texture.width == 256)
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let kit = RawrKit()
        kit.maxPreviewDimension = 64
        try #require(await kit.executeGraph(graph(url)))
        try #require(await kit.exportImage(graph(url), to: root.appendingPathComponent("raw-positive.tiff")))
        let exported = try ImageDecoder(context: ctx.ciContext).decode(url: root.appendingPathComponent("raw-positive.tiff"))
        #expect(exported.width == 256 && exported.height == 256)
    }

    @Test func `Negative node and preview render headlessly`() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("orange.tiff")
        try writeFixture(input)
        let flow = graph(input)
        let kit = RawrKit()
        try #require(await kit.executeGraph(flow))
        var document = RawrDocument()
        document.flowDocument = FlowDocument(version: "1.0", sourceFile: nil, metadata: DocumentMetadata(), nodeGraph: flow)
        let panel = PreviewSectionView(document: .constant(document), showExportDialog: .constant(false), exportFormat: .constant(.tiff), rawrKit: kit)
        let node = flow.nodes[1]
        let view = HStack(alignment: .top, spacing: 16) {
            VStack {
                Label("Negative Develop", systemImage: node.type.icon)
                NegativeDevelopControls(parameters: node.parameters, onChange: { _ in })
            }.frame(width: 230).padding().background(.background)
            panel.beforePreviewView.frame(width: 330, height: 300)
            panel.afterPreviewView.frame(width: 330, height: 300)
        }.padding().frame(width: 1030, height: 450)
        // Native numeric fields are AppKit-backed and cannot be flattened by
        // ImageRenderer. An offscreen hosting view captures them without opening
        // or ordering a window, launching Rawr, or changing the active app.
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: 1030, height: 450)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        Attachment.record(try #require(bitmap.representation(using: .png, properties: [:])), named: "negative-develop.png")
    }
}

private final class NegativeTestBundle {}
