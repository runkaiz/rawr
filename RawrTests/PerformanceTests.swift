import Testing
import Foundation
import CoreImage
import ImageIO
import Metal
import UniformTypeIdentifiers

@Suite(.serialized)
struct PerformanceTests {
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
        var first: TextureLease? = try #require(pool.texture(format: .rgba32Float, width: 32, height: 32))
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
        var lease: TextureLease? = try #require(context.resources.texture(format: .rgba32Float, width: 8, height: 8))
        let result = ImageData(lease: try #require(lease), metadata: ImageMetadata())
        lease = nil
        let other = try #require(context.resources.texture(format: .rgba32Float, width: 8, height: 8))
        #expect(ObjectIdentifier(result.texture) != ObjectIdentifier(other.texture))
        withExtendedLifetime(result) {}
    }

    @Test func `Buffer pool respects storage and does not recycle live summaries`() throws {
        let pool = try context().resources
        var scratch: BufferLease? = try #require(pool.buffer(length: 4096))
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
        var scratch: BufferLease? = try #require(pool.buffer(length: 768 * 1024))
        var output: BufferLease? = try #require(pool.buffer(length: 512 * 1024))
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
    @Test func `Streamed legacy TIFF export preserves values above display white`() async throws {
        let context = try context()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("linear.tiff")
        let colorSpace = CGColorSpace(name: CGColorSpace.linearSRGB)!
        let color = try #require(CIColor(red: 0.75, green: 0.5, blue: 0.25, colorSpace: colorSpace))
        let image = CIImage(color: color)
            .cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        try context.linearCIContext.writeTIFFRepresentation(of: image, to: url, format: .RGBAh, colorSpace: colorSpace, options: [:])
        var source = NodeData(type: .imageInput, position: .zero)
        source.imageURL = url
        var exposure = NodeData(type: .exposure, position: .zero)
        exposure.parameters["stops"] = 1
        let preview = NodeData(type: .preview, position: .zero)
        let graph = NodeGraph(nodes: [source, exposure, preview], connections: [
            Connection(fromNodeId: source.id, fromOutput: "Image", toNodeId: exposure.id, toInput: "Input"),
            Connection(fromNodeId: exposure.id, fromOutput: "Output", toNodeId: preview.id, toInput: "Input")
        ])
        let exported = root.appendingPathComponent("positive.tiff")
        let kit = RawrKit()
        try #require(await kit.exportImage(graph, to: exported))
        let result = try ImageDecoder(context: context.linearCIContext).decode(url: exported)
        var pixel = SIMD4<Float>.zero
        context.linearCIContext.render(CIImage(cgImage: result), toBitmap: &pixel, rowBytes: 16,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: colorSpace)
        #expect(abs(pixel.x - 1.5) < 0.003)
        #expect(abs(pixel.y - 1) < 0.003)
        #expect(abs(pixel.z - 0.5) < 0.003)
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
