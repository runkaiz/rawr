import Testing
import Foundation
import CoreImage
import ImageIO
import Metal
import UniformTypeIdentifiers

@Suite(.serialized)
struct PerformanceTests {
    @MainActor
    @Test func `Long rolls retain recent logs with an advancing scroll identity`() async {
        let kit = RawrKit()
        for index in 0..<750 { kit.log("line \(index)") }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(kit.logs.count == 500)
        #expect(kit.logs.first?.message == "line 250")
        let lastID = kit.logs.last?.id
        kit.log("final frame")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(kit.logs.count == 500)
        #expect(kit.logs.last?.id != lastID)
        #expect(kit.logs.last?.message == "final frame")
    }

    @Test func `Canvas moves preserve the processing revision while image edits invalidate it`() {
        let input = NodeData(type: .imageInput, position: .zero)
        let effect = NodeData(type: .exposure, position: .zero)
        var graph = NodeGraph(nodes: [input, effect])
        let initial = graph.processingRevision
        graph.nodes[0].position = CGPoint(x: 100, y: 200)
        graph.nodes[1].position = CGPoint(x: -50, y: 300)
        #expect(graph.processingRevision == initial)
        graph.nodes[1].parameters["stops"] = 1
        let edited = graph.processingRevision
        #expect(edited != initial)
        graph.connections = [Connection(fromNodeId: input.id, fromOutput: "Image", toNodeId: effect.id, toInput: "Input")]
        #expect(graph.processingRevision != edited)
        let wired = graph.processingRevision
        graph.nodes[0].imageURL = URL(fileURLWithPath: "/another/source.tiff")
        #expect(graph.processingRevision != wired)
    }

    private func context() throws -> ProcessingContext {
        let device = try #require(MTLCreateSystemDefaultDevice())
        return ProcessingContext(device: device, commandQueue: try #require(device.makeCommandQueue()), ciContext: CIContext(mtlDevice: device))
    }

    private func input(_ context: ProcessingContext, width: Int = 16, height: Int = 16) throws -> ImageData {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite]
        let texture = try #require(context.device.makeTexture(descriptor: descriptor))
        let pixels = [SIMD4<Float>](repeating: SIMD4(0.4, 0.3, 0.2, 1), count: width * height)
        pixels.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                withBytes: $0.baseAddress!, bytesPerRow: width * 16)
        }
        var metadata = ImageMetadata(width: width, height: height)
        metadata.domain = .linearTransmittance
        return ImageData(texture: texture, metadata: metadata)
    }

    @Test func `Live texture leases never alias and released textures are reused`() throws {
        let context = try context()
        let pool = context.resources
        var first: TextureLease? = pool.texture(format: .rgba32Float, width: 32, height: 32)
        let identity = ObjectIdentifier(try #require(first).texture)
        let second = try #require(pool.texture(format: .rgba32Float, width: 32, height: 32))
        #expect(identity != ObjectIdentifier(second.texture))
        first = nil
        let recycled = try #require(pool.texture(format: .rgba32Float, width: 32, height: 32))
        #expect(ObjectIdentifier(recycled.texture) == identity)
        #expect(pool.textureAllocations == 2)
        let distinct = try #require(pool.texture(format: .r32Float, width: 32, height: 32))
        #expect(distinct.texture.pixelFormat == .r32Float)
        #expect(context.resources.pipeline("negativeDevelop") === context.resources.pipeline("negativeDevelop"))
    }

    @Test func `Image results retain their pooled textures`() throws {
        let context = try context()
        var lease: TextureLease? = context.resources.texture(format: .rgba32Float, width: 8, height: 8)
        let result = ImageData(lease: try #require(lease), metadata: ImageMetadata())
        lease = nil
        let other = try #require(context.resources.texture(format: .rgba32Float, width: 8, height: 8))
        #expect(ObjectIdentifier(result.texture) != ObjectIdentifier(other.texture))
        withExtendedLifetime(result) {}
    }

    @Test func `Published CPU image stays immutable when its pooled GPU texture is reused`() async throws {
        let context = try context()
        var lease: TextureLease? = context.resources.texture(format: .rgba32Float, width: 8, height: 8)
        let identity = ObjectIdentifier(try #require(lease).texture)
        func fill(_ texture: MTLTexture, red: CGFloat, blue: CGFloat) async throws {
            let command = try #require(context.commandQueue.makeCommandBuffer())
            context.linearCIContext.render(CIImage(color: CIColor(red: red, green: 0, blue: blue)),
                to: texture, commandBuffer: command, bounds: CGRect(x: 0, y: 0, width: 8, height: 8),
                colorSpace: NegativeImageIO.colorSpace)
            command.commit()
            await command.completed()
            try #require(command.status == .completed)
        }
        let firstTexture = try #require(lease).texture
        try await fill(firstTexture, red: 1, blue: 0)
        let snapshot = try #require(MetalNodeProcessor(nodeType: .preview).createCGImage(
            from: firstTexture, context: context.linearCIContext))
        lease = nil
        let recycled = try #require(context.resources.texture(format: .rgba32Float, width: 8, height: 8))
        #expect(ObjectIdentifier(recycled.texture) == identity)
        try await fill(recycled.texture, red: 0, blue: 1)
        var pixel = SIMD4<Float>.zero
        context.linearCIContext.render(CIImage(cgImage: snapshot), toBitmap: &pixel, rowBytes: 16,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: NegativeImageIO.colorSpace)
        #expect(abs(pixel.x - 1) < 1e-5)
        #expect(abs(pixel.z) < 1e-5)
        withExtendedLifetime(recycled) {}
    }

    @Test func `Buffer pool respects storage and does not recycle live summaries`() throws {
        let pool = try context().resources
        var scratch: BufferLease? = pool.buffer(length: 4096)
        let identity = ObjectIdentifier(try #require(scratch).buffer)
        scratch = nil
        let reused = try #require(pool.buffer(length: 4096))
        #expect(ObjectIdentifier(reused.buffer) == identity)
        let shared = try #require(pool.buffer(length: 4096, options: .storageModeShared))
        #expect(shared.buffer.storageMode == .shared)
        #expect(ObjectIdentifier(shared.buffer) != identity)
        #expect(pool.bufferAllocations == 2)
    }

    @Test func `Idle pool evicts scratch so large preview outputs can be reused`() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let pool = MetalResources(device: device, idleByteLimit: 1024 * 1024)
        var scratch: BufferLease? = pool.buffer(length: 768 * 1024)
        var output: BufferLease? = pool.buffer(length: 512 * 1024)
        let identity = ObjectIdentifier(try #require(output).buffer)
        scratch = nil
        output = nil
        let recycled = try #require(pool.buffer(length: 512 * 1024))
        #expect(ObjectIdentifier(recycled.buffer) == identity)
        #expect(pool.bufferAllocations == 2)
        withExtendedLifetime(scratch) {}
    }

    @Test func `Dust cache reuses unchanged cleanup and invalidates repair and input changes`() async throws {
        let context = try context()
        let processor = DustRemovalProcessor(context: context)
        let image = try input(context)
        var node = NodeData(type: .dustRemoval, position: .zero)
        let first = try #require(await processor.process(inputs: ["Input": image], node: node, context: context)?["Output"])
        node.position.x = 200 // Canvas placement does not change pixels.
        let reused = try #require(await processor.process(inputs: ["Input": image], node: node, context: context)?["Output"])
        #expect(first.contentID == reused.contentID)
        node.healSpots = [HealSpot(x: 0.5, y: 0.5, radius: 0.04)]
        let repaired = try #require(await processor.process(inputs: ["Input": image], node: node, context: context)?["Output"])
        #expect(repaired.contentID != first.contentID)
        let changed = try #require(await processor.process(inputs: ["Input": input(context)], node: node, context: context)?["Output"])
        #expect(changed.contentID != repaired.contentID)
        processor.clearCache()
        let cleared = try #require(await processor.process(inputs: ["Input": image], node: node, context: context)?["Output"])
        #expect(cleared.contentID != repaired.contentID)
    }

    @Test func `Graph mask demand skips unused color output and invalidates the cleanup cache`() async throws {
        let context = try context(), image = try input(context)
        let processor = DustRemovalProcessor(context: context)
        var node = NodeData(type: .dustRemoval, position: .zero)
        context.requestedMasks = []
        let rgb = try #require(await processor.process(inputs: ["Input": image], node: node, context: context))
        #expect(rgb["Mask"] == nil)
        #expect(rgb["Output"]?.metadata.dustMaskPreview == nil)
        context.requestedMasks = [node.id]
        let mask = try #require(await processor.process(inputs: ["Input": image], node: node, context: context))
        #expect(mask["Mask"]?.texture.width == image.texture.width)
        #expect(mask["Output"]?.contentID != rgb["Output"]?.contentID)
        context.requestedMasks = []
        node.parameters["maskPreview"] = 1
        let overlay = try #require(await processor.process(inputs: ["Input": image], node: node, context: context))
        #expect(overlay["Output"]?.metadata.dustMaskPreview?.width == image.texture.width)
    }

    @Test(arguments: [0.0, 1.0])
    func `Tiled infrared closing and repair match whole frame at seams and image edges`(ghost: Double) async throws {
        let context = try context(), w = 64, h = 557
        var rgb = [SIMD4<Float>](repeating: .zero, count: w * h)
        var infrared = [Float](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w {
            let t: Float = 0.45 + 0.04 * sin(Float(x) / 8) + 0.03 * cos(Float(y) / 11)
            rgb[y*w+x] = SIMD4(0.8*t, 0.4*t, 0.2*t, 1)
            infrared[y*w+x] = 0.85 - 0.3 * Float(y) / Float(h) + 0.015 * sin(Float(x) / 7)
        } }
        for y in [0, 16, 17, 32, 33, 510, 511, 512, 513, 555, 556] {
            rgb[y*w+w/2] = SIMD4(0.008, 0.004, 0.002, 1)
            infrared[y*w+w/2] *= 0.948
        }
        func upload(_ format: MTLPixelFormat, bytes: UnsafeRawBufferPointer, row: Int) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
            d.storageMode = .shared
            d.usage = [.shaderRead, .shaderWrite]
            let texture = try #require(context.device.makeTexture(descriptor: d))
            texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: bytes.baseAddress!, bytesPerRow: row)
            return texture
        }
        let visible = try rgb.withUnsafeBytes { try upload(.rgba32Float, bytes: $0, row: w * 16) }
        let ir = try infrared.withUnsafeBytes { try upload(.r32Float, bytes: $0, row: w * 4) }
        var metadata = ImageMetadata(width: w, height: h)
        metadata.domain = .linearTransmittance
        let image = ImageData(texture: visible, metadata: metadata, infraredTexture: ir)
        var node = NodeData(type: .dustRemoval, position: .zero)
        node.parameters["irGhost"] = ghost
        node.parameters["sensitivity"] = 1
        node.healSpots = [HealSpot(x: 0.5, y: 1 - 512.5 / Double(h), radius: 0.04)]
        func bytes(_ texture: MTLTexture) async throws -> Data {
            let row = w * (texture.pixelFormat == .rgba16Float ? 8 : 16)
            let buffer = try #require(context.device.makeBuffer(length: row * h, options: .storageModeShared))
            let command = try #require(context.commandQueue.makeCommandBuffer())
            let blit = try #require(command.makeBlitCommandEncoder())
            blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: w, height: h, depth: 1), to: buffer, destinationOffset: 0,
                destinationBytesPerRow: row, destinationBytesPerImage: row * h)
            blit.endEncoding()
            command.commit()
            await command.completed()
            try #require(command.status == .completed)
            return Data(bytes: buffer.contents(), count: row * h)
        }
        let reference = try #require(await DustRemovalProcessor(context: context, rowsPerTile: h).process(
            inputs: ["Input": image], node: node, context: context))
        for rows in [17, 512] {
            let tiled = try #require(await DustRemovalProcessor(context: context, rowsPerTile: rows).process(
                inputs: ["Input": image], node: node, context: context))
            defer { withExtendedLifetime([reference, tiled]) {} }
            for port in ["Output", "Mask"] {
                let expectedImage = try #require(reference[port])
                let actualImage = try #require(tiled[port])
                let expected = try await bytes(expectedImage.texture)
                let actual = try await bytes(actualImage.texture)
                #expect(actual == expected, "Tile halos must preserve every output and mask bit")
            }
        }
        let output = try #require(reference["Output"])
        let repaired = try await bytes(output.texture)
        let value = repaired.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: (512*w+w/2)*16, as: Float.self) }
        #expect(abs(value - rgb[512*w+w/2].x) > 0.01, "The fixture must exercise repair")
    }

    @Test func `Legacy effects produce GPU resident results without CPU images`() async throws {
        let context = try context()
        let image = try input(context)
        let processors: [NodeProcessor] = [InversionProcessor(context: context), ExposureProcessor(context: context),
            GammaProcessor(context: context), DenoiseProcessor(context: context), SharpeningProcessor(context: context),
            CombinationProcessor(context: context)]
        for processor in processors {
            let node = NodeData(type: processor.nodeType, position: .zero)
            let inputs = processor.nodeType == .combination ? ["Input A": image, "Input B": image] : ["Input": image]
            let output = try #require(await processor.process(inputs: inputs, node: node, context: context)?["Output"])
            #expect(output.cgImage == nil)
            #expect(output.texture.storageMode == .private)
            #expect(output.metadata.legacyFloatOutput)
            #expect(!output.textureLeases.isEmpty)
            let boundary = try #require(MetalNodeProcessor(nodeType: node.type).createCGImage(
                from: output.texture, context: context.linearCIContext))
            #expect(boundary.width == image.texture.width)
            #expect(boundary.bitsPerComponent == 32)
        }
    }

    @Test func `Roll concurrency is limited by image memory rather than frame count`() {
        let gib: UInt64 = 1024 * 1024 * 1024
        #expect(BatchMemoryPolicy.workers(pixels: 24_000_000, recommendedBytes: 12 * gib, physicalBytes: 16 * gib) == 2)
        #expect(BatchMemoryPolicy.workers(pixels: 24_000_000, recommendedBytes: 3 * gib, physicalBytes: 4 * gib) == 1)
        #expect(BatchMemoryPolicy.workers(pixels: 128_000_000, recommendedBytes: 12 * gib, physicalBytes: 16 * gib) == 1)
        #expect(BatchMemoryPolicy.workers(pixels: 1, recommendedBytes: 0, physicalBytes: 0) == 1)
    }

    @Test func `Linear crop and cleanup reuse memory while branches reserve extra frames`() {
        let nodes = [NodeData(type: .folderInput, position: .zero), NodeData(type: .autoCrop, position: .zero),
            NodeData(type: .dustRemoval, position: .zero), NodeData(type: .negativeDevelop, position: .zero),
            NodeData(type: .exposure, position: .zero), NodeData(type: .preview, position: .zero)]
        var graph = NodeGraph(nodes: nodes, connections: (1..<nodes.count).map { i in
            Connection(fromNodeId: nodes[i-1].id, fromOutput: i == 1 ? "Image" : "Output", toNodeId: nodes[i].id, toInput: "Input")
        })
        #expect(BatchMemoryPolicy.peakPixels(24_000_000, graph: graph) == 24_000_000)
        let combination = NodeData(type: .combination, position: .zero)
        graph.nodes[4] = combination
        graph.connections.removeLast(2)
        graph.connections += [
            Connection(fromNodeId: nodes[3].id, fromOutput: "Output", toNodeId: combination.id, toInput: "Input A"),
            Connection(fromNodeId: nodes[0].id, fromOutput: "Image", toNodeId: combination.id, toInput: "Input B"),
            Connection(fromNodeId: combination.id, fromOutput: "Output", toNodeId: nodes[5].id, toInput: "Input")
        ]
        #expect(graph.validationError() == nil)
        #expect(BatchMemoryPolicy.peakPixels(24_000_000, graph: graph) == 48_000_000)
    }

    @MainActor
    @Test func `Source replacement and preview resolution invalidate legacy GPU upload`() async throws {
        let context = try context()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("source.tiff")
        try PipelineFixture.write(url, width: 64, context: context)
        let kit = RawrKit()
        let first = try #require(await kit.loadLegacySource(at: url))
        let cached = try #require(await kit.loadLegacySource(at: url))
        #expect(first.contentID == cached.contentID)
        kit.maxPreviewDimension = 32
        let scaled = try #require(await kit.loadLegacySource(at: url))
        #expect(scaled.texture.width == 32)
        #expect(scaled.contentID != first.contentID)
        let replacement = root.appendingPathComponent("replacement.tiff")
        try PipelineFixture.write(replacement, width: 80, context: context)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: replacement)
        kit.maxPreviewDimension = 1920
        let replaced = try #require(await kit.loadLegacySource(at: url))
        #expect(replaced.texture.width == 80)
        #expect(replaced.contentID != first.contentID)
    }

    @MainActor
    @Test(arguments: [false, true])
    func `Export reuses native film sources while preserving full image dimensions`(crop: Bool) async throws {
        let kit = RawrKit()
        let context = try #require(kit.processingContext)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("negative.tiff")
        try PipelineFixture.write(input, width: 64, context: context)
        var source = NodeData(type: .imageInput, position: .zero)
        source.imageURL = input
        let develop = NodeData(type: .negativeDevelop, position: .zero)
        let preview = NodeData(type: .preview, position: .zero)
        var nodes = [source]
        if crop {
            var geometry = NodeData(type: .autoCrop, position: .zero)
            geometry.autoCrop?.manual = CropGeometry(width: 0.75, height: 0.75)
            nodes.append(geometry)
        }
        nodes += [develop, preview]
        let graph = NodeGraph(nodes: nodes, connections: (1..<nodes.count).map { i in
            Connection(fromNodeId: nodes[i-1].id, fromOutput: i == 1 ? "Image" : "Output", toNodeId: nodes[i].id, toInput: "Input")
        })
        kit.maxPreviewDimension = 16
        try #require(await kit.executeGraph(graph))
        let before = try #require(kit.loadNegativeSource(at: input, context: context))
        #expect(kit.processedPreviewImage?.width == 16)
        let output = root.appendingPathComponent("positive.tiff")
        try #require(await kit.exportImage(graph, to: output))
        let after = try #require(kit.loadNegativeSource(at: input, context: context))
        #expect(after.contentID == before.contentID)
        let exported = try ImageDecoder(context: context.linearCIContext).decode(url: output)
        #expect(exported.width == (crop ? 48 : 64) && exported.height == (crop ? 24 : 32))
        #expect(!kit.isFullResolutionMode)
    }

    @MainActor
    @Test(arguments: [false, true])
    func `Streamed legacy TIFF export preserves values above display white`(negative: Bool) async throws {
        let context = try context()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("linear.tiff")
        let colorSpace = CGColorSpace(name: CGColorSpace.linearSRGB)!
        let color = try #require(CIColor(red: negative ? 0.1 : 0.75, green: negative ? 0.1 : 0.5,
            blue: negative ? 0.1 : 0.25, colorSpace: colorSpace))
        let image = CIImage(color: color)
            .cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        try context.linearCIContext.writeTIFFRepresentation(of: image, to: url, format: .RGBAh, colorSpace: colorSpace, options: [:])
        var source = NodeData(type: .imageInput, position: .zero)
        source.imageURL = url
        var exposure = NodeData(type: .exposure, position: .zero)
        exposure.parameters["stops"] = negative ? 2 : 1
        let preview = NodeData(type: .preview, position: .zero)
        var nodes = [source]
        if negative {
            var develop = NodeData(type: .negativeDevelop, position: .zero)
            for key in ["autoBase", "autoEndpoints", "autoBalance"] { develop.parameters[key] = 0 }
            for channel in ["R", "G", "B"] {
                develop.parameters["base" + channel] = 1
                develop.parameters["low" + channel] = 0
                develop.parameters["high" + channel] = 2
            }
            nodes.append(develop)
        }
        nodes += [exposure, preview]
        let graph = NodeGraph(nodes: nodes, connections: (1..<nodes.count).map { index in
            Connection(fromNodeId: nodes[index-1].id, fromOutput: index == 1 ? "Image" : "Output",
                toNodeId: nodes[index].id, toInput: "Input")
        })
        let exported = root.appendingPathComponent("positive.tiff")
        let kit = RawrKit()
        try #require(await kit.exportImage(graph, to: exported))
        let result = try ImageDecoder(context: context.linearCIContext).decode(url: exported)
        var pixel = SIMD4<Float>.zero
        context.linearCIContext.render(CIImage(cgImage: result), toBitmap: &pixel, rowBytes: 16,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: NegativeImageIO.colorSpace)
        #expect(abs(pixel.x - (negative ? 2 : 1.5)) < 0.003)
        #expect(abs(pixel.y - (negative ? 2 : 1)) < 0.003)
        #expect(abs(pixel.z - (negative ? 2 : 0.5)) < 0.003)
    }

    @MainActor
    @Test func `Interactive slider bursts render only the latest pending graph`() async throws {
        let context = try context()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("source.tiff")
        try PipelineFixture.write(url, width: 64, context: context)
        var input = NodeData(type: .imageInput, position: .zero)
        input.imageURL = url
        let preview = NodeData(type: .preview, position: .zero)
        let graph = NodeGraph(nodes: [input, preview], connections: [
            Connection(fromNodeId: input.id, fromOutput: "Image", toNodeId: preview.id, toInput: "Input")
        ])
        let kit = RawrKit()
        var unblock: CheckedContinuation<Void, Never>?
        let blocker = Task { await kit.enqueue {
            await withCheckedContinuation { unblock = $0 }
            return true
        } }
        while unblock == nil { await Task.yield() }
        var submitted = 0
        let requests = (0..<8).map { _ in Task { @MainActor in
            submitted += 1
            return await kit.executeInteractivePreview(graph)
        } }
        while submitted < requests.count { await Task.yield() }
        unblock?.resume()
        _ = await blocker.value
        var rendered = 0, superseded = 0
        for request in requests {
            switch await request.value {
            case .rendered: rendered += 1
            case .superseded: superseded += 1
            case .failed: Issue.record("The current preview failed")
            }
        }
        #expect(rendered == 1)
        #expect(superseded == 7)
        #expect(kit.processedPreviewImage?.width == 64)
    }

    @Test func `Replacing an infrared file invalidates cached dust output`() async throws {
        let context = try context()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("ir.tiff")
        try PipelineFixture.write(url, width: 16, context: context)
        let processor = DustRemovalProcessor(context: context)
        var node = NodeData(type: .dustRemoval, position: .zero)
        node.infraredURL = url
        let image = try input(context, width: 16, height: 8)
        let first = try #require(await processor.process(inputs: ["Input": image], node: node, context: context)?["Output"])
        let reused = try #require(await processor.process(inputs: ["Input": image], node: node, context: context)?["Output"])
        #expect(first.contentID == reused.contentID)
        let replacement = root.appendingPathComponent("new-ir.tiff")
        try PipelineFixture.write(replacement, width: 16, context: context)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: replacement)
        let changed = try #require(await processor.process(inputs: ["Input": image], node: node, context: context)?["Output"])
        #expect(first.contentID != changed.contentID)
    }
}

private enum PipelineFixture {
    static func write(_ url: URL, width: Int, context: ProcessingContext) throws {
        let image = CIImage(color: CIColor(red: 0.6, green: 0.4, blue: 0.2))
        let cg = try #require(context.ciContext.createCGImage(image, from: CGRect(x: 0, y: 0, width: width, height: width / 2)))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cg, nil)
        try #require(CGImageDestinationFinalize(destination))
    }
}
