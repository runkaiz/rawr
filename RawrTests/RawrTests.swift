import Foundation
import Testing
import CoreImage
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

private final class TestBundleLocator {}

@Suite(.serialized)
@MainActor
struct RawrTests {
    private func fixture() throws -> URL {
        let bundle = Bundle(for: TestBundleLocator.self)
        return try #require(bundle.url(forResource: "sensor", withExtension: "dng", subdirectory: "Fixtures")
            ?? bundle.url(forResource: "sensor", withExtension: "dng"))
    }

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("RawrTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func graph(_ url: URL?, folder: Bool = false) -> NodeGraph {
        var input = NodeData(type: folder ? .folderInput : .imageInput, position: .zero)
        input.imageURL = url
        let preview = NodeData(type: .preview, position: CGPoint(x: 300, y: 0))
        return NodeGraph(nodes: [input, preview], connections: [
            Connection(fromNodeId: input.id, fromOutput: "Image", toNodeId: preview.id, toInput: "Input")
        ])
    }

    private func ordinaryImage(at url: URL, width: Int = 64, height: Int = 32, orientation: Int = 1) throws {
        let context = CIContext()
        let image = try #require(context.createCGImage(CIImage(color: CIColor(red: 0.2, green: 0.4, blue: 0.6)),
            from: CGRect(x: 0, y: 0, width: width, height: height)))
        let type = url.pathExtension == "png" ? UTType.png : UTType.tiff
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
    }

    @Test func `RAW URL and data decode the sensor instead of embedded preview`() throws {
        let url = try fixture()
        let data = try Data(contentsOf: url)
        let raw = try #require(CIRAWFilter(imageData: data, identifierHint: "com.adobe.raw-image"))
        #expect(!raw.decoderVersion.rawValue.isEmpty)
        #expect(raw.nativeSize == CGSize(width: 256, height: 256))
        let decoder = ImageDecoder(context: CIContext())
        let images = [try decoder.decode(url: url),
                      try decoder.decode(data: data, typeHint: "com.adobe.raw-image")]
        for image in images {
            #expect(image.width == 256)
            #expect(image.height == 256)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RAWR_NEF_FIXTURE"] != nil))
    func `Original Nikon regression decodes and exports the full sensor`() async throws {
        // Optional external NASA fixture; the always-on RAW tests use the small
        // generated DNG. Keep this large photograph out of the source repository.
        let input = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["RAWR_NEF_FIXTURE"]))
        let bytes = try Data(contentsOf: input)
        let source = try #require(CGImageSourceCreateWithData(bytes as CFData, nil))
        let embedded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(embedded.width == 160)
        #expect(embedded.height == 120)
        let decoder = ImageDecoder(context: CIContext())
        let fromURL = try decoder.decode(url: input)
        let fromData = try decoder.decode(data: bytes, typeHint: "com.nikon.raw-image")
        for image in [fromURL, fromData] {
            #expect(image.width == 4256)
            #expect(image.height == 2832)
        }
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let kit = RawrKit()
        #expect(await kit.executeGraph(graph(input)))
        #expect(kit.processedPreviewImage?.width == 1920)
        let output = root.appendingPathComponent("nikon-full.tiff")
        #expect(await kit.exportImage(graph(input), to: output))
        let exported = try decoder.decode(url: output)
        #expect(exported.width == 4256)
        #expect(exported.height == 2832)
    }

    @Test func `RAW preview cache does not reduce full size exports`() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let kit = RawrKit()
        kit.maxPreviewDimension = 64
        let input = try fixture()
        let flow = graph(input)
        #expect(await kit.executeGraph(flow))
        #expect(kit.processedPreviewImage?.width == 64)
        let output = root.appendingPathComponent("full.tiff")
        #expect(await kit.exportImage(flow, to: output))
        let exported = try ImageDecoder(context: CIContext()).decode(url: output)
        #expect(exported.width == 256)
        #expect(exported.height == 256)
        #expect(await kit.executeGraph(flow))
        #expect(kit.processedPreviewImage?.width == 64)
        #expect(!kit.isProcessing)
        #expect(!kit.isFullResolutionMode)
    }

    @Test func `Folder and legacy RAW loaders share full size decoding`() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("raw.dng")
        try FileManager.default.copyItem(at: fixture(), to: input)
        let kit = RawrKit()
        #expect(await kit.loadRawFile(from: input))
        #expect(kit.previewImage?.width == 256)
        #expect(await kit.executeGraph(graph(root, folder: true)))
        #expect(kit.processedPreviewImage?.width == 256)
        let destination = root.appendingPathComponent("exports")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        #expect(await kit.exportFolderBatch(graph(root, folder: true), to: destination))
        let exported = try ImageDecoder(context: CIContext()).decode(url: destination.appendingPathComponent("raw_processed.tiff"))
        #expect(exported.width == 256)
        #expect(exported.height == 256)
    }

    @Test func `Ordinary images preserve dimensions and EXIF orientation`() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let decoder = ImageDecoder(context: CIContext())
        for ext in ["png", "tiff"] {
            let input = root.appendingPathComponent("ordinary.\(ext)")
            try ordinaryImage(at: input)
            let image = try decoder.decode(url: input)
            #expect(image.width == 64)
            #expect(image.height == 32)
        }
        let rotated = root.appendingPathComponent("rotated.tiff")
        try ordinaryImage(at: rotated, orientation: 6)
        let image = try decoder.decode(url: rotated)
        #expect(image.width == 32)
        #expect(image.height == 64)
    }

    @Test func `Invalid data and missing files fail without fallback thumbnails`() throws {
        let decoder = ImageDecoder(context: CIContext())
        #expect(throws: (any Error).self) { try decoder.decode(data: Data([1, 2, 3]), typeHint: UTType.png.identifier) }
        #expect(throws: (any Error).self) { try decoder.decode(data: Data([1, 2, 3]), typeHint: "com.nikon.raw-image") }
        #expect(throws: (any Error).self) { try decoder.decode(url: URL(fileURLWithPath: "/missing/rawr-image.nef")) }
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let disguised = root.appendingPathComponent("ordinary.nef")
        try ordinaryImage(at: disguised)
        #expect(throws: (any Error).self) { try decoder.decode(url: disguised) }
        #expect(throws: (any Error).self) {
            try decoder.decode(data: Data(contentsOf: disguised), typeHint: "com.nikon.raw-image")
        }
    }

    @Test(arguments: [(0.0, 10.0), (-1.0, 10.0), (Double.infinity, 10.0), (Double.nan, 10.0), (16385.0, 1.0), (16384.0, 16384.0)])
    func `Invalid or excessive dimensions are rejected`(size: (Double, Double)) {
        #expect(throws: (any Error).self) { try ImageDecoder.validateDimensions(width: size.0, height: size.1) }
    }

    @Test func `Batch exports preserve same stems and existing destinations`() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("exports")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try ordinaryImage(at: root.appendingPathComponent("same.png"), width: 64)
        try ordinaryImage(at: root.appendingPathComponent("same.tiff"), width: 80)
        let existing = output.appendingPathComponent("SAME_processed.png")
        let sentinel = Data("keep me".utf8)
        try sentinel.write(to: existing)
        let kit = RawrKit()
        #expect(await kit.exportFolderBatch(graph(root, folder: true), to: output, format: .png))
        #expect(try Data(contentsOf: existing) == sentinel)
        let decoder = ImageDecoder(context: CIContext())
        #expect(try decoder.decode(url: output.appendingPathComponent("same_processed_2.png")).width == 64)
        #expect(try decoder.decode(url: output.appendingPathComponent("same_processed_3.png")).width == 80)
        #expect(await kit.exportFolderBatch(graph(root, folder: true), to: output, format: .png))
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).count == 5)
    }

    @Test func `Missing inputs report failure after execution`() async throws {
        let kit = RawrKit()
        #expect(await kit.executeGraph(graph(nil)) == false)
        #expect(await kit.executeGraph(graph(URL(fileURLWithPath: "/missing/rawr.png"))) == false)
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(await kit.executeGraph(graph(root, folder: true)) == false)
        #expect(await kit.exportFolderBatch(graph(root, folder: true), to: root) == false)
        #expect(await kit.exportImage(graph(nil), to: root.appendingPathComponent("bad.png"), format: .png) == false)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("bad.png").path))
    }

    @Test func `A destination created after preflight is never replaced`() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = try #require(BatchDestinations.plan(inputs: [root.appendingPathComponent("same.png")], folder: root, extension: "png").first)
        let temporary = root.appendingPathComponent("staged")
        let sentinel = Data("late arrival".utf8)
        try sentinel.write(to: destination)
        try Data("processed".utf8).write(to: temporary)
        #expect(throws: (any Error).self) { try BatchDestinations.install(temporary: temporary, destination: destination) }
        #expect(try Data(contentsOf: destination) == sentinel)
        try FileManager.default.removeItem(at: destination)
        try BatchDestinations.install(temporary: temporary, destination: destination)
        #expect(try Data(contentsOf: destination) == Data("processed".utf8))
        #expect(!FileManager.default.fileExists(atPath: temporary.path))
    }

    @Test func `Cyclic documents are rejected before processing including disconnected cycles`() async throws {
        let a = NodeData(type: .inversion, position: .zero)
        let b = NodeData(type: .exposure, position: .zero)
        var flow = graph(try fixture())
        flow.nodes += [a, b]
        flow.connections += [Connection(fromNodeId: a.id, fromOutput: "Output", toNodeId: b.id, toInput: "Input"),
                             Connection(fromNodeId: b.id, fromOutput: "Output", toNodeId: a.id, toInput: "Input")]
        let document = FlowDocument(version: "1.0", sourceFile: nil, metadata: DocumentMetadata(), nodeGraph: flow)
        let decoded = try JSONDecoder().decode(FlowDocument.self, from: JSONEncoder().encode(document))
        #expect(decoded.nodeGraph.validationError()?.contains("cycle") == true)
        let kit = RawrKit()
        #expect(await kit.executeGraph(decoded.nodeGraph) == false)
        #expect(kit.processedPreviewImage == nil)
        let selfCycle = NodeGraph(nodes: [a], connections: [Connection(fromNodeId: a.id, fromOutput: "Output", toNodeId: a.id, toInput: "Input")])
        #expect(selfCycle.validationError()?.contains("cycle") == true)
        await Task.yield()
        #expect(kit.logs.contains { $0.message.contains("cycle detected") })
    }

    @Test func `Malformed graph references and duplicate IDs are rejected`() throws {
        let flow = graph(try fixture())
        #expect(NodeGraph(nodes: [flow.nodes[0], flow.nodes[0]]).validationError()?.contains("duplicate") == true)
        var broken = flow
        broken.nodes.removeFirst()
        #expect(broken.validationError()?.contains("missing") == true)
        broken = flow
        broken.connections.append(flow.connections[0])
        #expect(broken.validationError()?.contains("multiple") == true)
    }

    @Test func `Queued callers receive their own completed result`() async throws {
        let kit = RawrKit()
        kit.maxPreviewDimension = 64
        let flow = graph(try fixture())
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        async let first = kit.executeGraph(flow)
        async let invalid = kit.executeGraph(graph(nil))
        async let exported = kit.exportImage(flow, to: root.appendingPathComponent("queued.tiff"))
        async let last = kit.executeGraph(flow)
        let results = await (first, invalid, exported, last)
        #expect(results.0)
        #expect(!results.1)
        #expect(results.2)
        #expect(results.3)
        #expect(!kit.isProcessing)
        let image = try ImageDecoder(context: CIContext()).decode(url: root.appendingPathComponent("queued.tiff"))
        #expect(image.width == 256)
    }

    @Test func `Render the affected preview panel headlessly`() async throws {
        let kit = RawrKit()
        let flow = graph(try fixture())
        #expect(await kit.executeGraph(flow))
        var document = RawrDocument()
        document.flowDocument = FlowDocument(version: "1.0", sourceFile: nil, metadata: DocumentMetadata(), nodeGraph: flow)
        let panel = PreviewSectionView(document: .constant(document), showExportDialog: .constant(false),
            exportFormat: .constant(.tiff), rawrKit: kit)
        // ImageRenderer cannot flatten AppKit's HSplitView. Render its real SwiftUI
        // pane contents in a fixed layout without opening an application window.
        let view = HStack(spacing: 1) {
            panel.beforePreviewView
            panel.afterPreviewView
            panel.logsView
        }.frame(width: 1100, height: 300)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("raw-preview.png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        Attachment.record(try Data(contentsOf: url), named: "raw-preview.png")
    }
}
