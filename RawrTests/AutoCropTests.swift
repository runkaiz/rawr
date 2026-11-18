import Foundation
import Testing
import Metal
import CoreImage
import ImageIO
import SwiftUI
import AppKit
import UniformTypeIdentifiers

@Suite(.serialized)
@MainActor
struct AutoCropTests {
    private func context() throws -> ProcessingContext {
        let device = try #require(MTLCreateSystemDefaultDevice())
        return ProcessingContext(device: device, commandQueue: try #require(device.makeCommandQueue()), ciContext: CIContext(mtlDevice: device))
    }

    /// Independent CPU fixture construction, using inverse pixel-space affine
    /// coordinates. The detector never receives the ground-truth rectangle.
    private func fixture(_ context: ProcessingContext, degrees: Double = 0, camera: Bool = false,
                         defects: Bool = true, centerX: Double = 0.5, url: URL? = nil) throws -> ImageData {
        let w = 640, h = 480
        let a = degrees * .pi / 180
        var pixels = [SIMD4<Float>](repeating: .zero, count: w*h)
        for y in 0..<h {
            for x in 0..<w {
                let px = Double(x) + 0.5 - centerX * Double(w), py = Double(y) + 0.5 - Double(h)/2
                let u = (cos(a)*px + sin(a)*py)/Double(w)
                let v = (-sin(a)*px + cos(a)*py)/Double(h)
                var rgb = SIMD3<Float>(0.8,0.4,0.2)
                if abs(u)<0.36 && abs(v)<0.29 {
                    let t = Float(0.16 + 0.30*(u+0.36)/0.72 + 0.05*sin(v*18))
                    rgb *= t
                } else if abs(u)>0.455 || abs(v)>0.445 {
                    rgb = camera ? SIMD3(repeating: 1) : SIMD3(repeating: 0.006)
                } else if defects {
                    if abs(v)>0.35 && abs(v)<0.40 && abs(u)<0.43 && Int((u+0.5)*80)%8<3 {
                        rgb = SIMD3(repeating: 1) // sprocket holes beyond exposure
                    }
                    if u < -0.32 && v < -0.25 { rgb = SIMD3(0.95,0.6,0.3) } // corner leak
                }
                pixels[y*w+x] = SIMD4(rgb.x,rgb.y,rgb.z,1)
            }
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        let texture = try #require(context.device.makeTexture(descriptor: d))
        pixels.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0,0,w,h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w*16) }
        var metadata = ImageMetadata(width: w,height: h)
        metadata.domain = .linearTransmittance
        metadata.sourceURL = url
        return ImageData(texture: texture, metadata: metadata)
    }

    @Test(arguments: [-5.25, 0, 3.5, 6.25])
    func `Rotated scans reject holders sprockets and corner leaks`(angle: Double) async throws {
        let ctx = try context()
        let input = try fixture(ctx, degrees: angle)
        let result = try #require(await AutoCropDetector(context: ctx).analyze(input))
        Attachment.record("angle=\(angle), proposal=\(result.proposal), confidence=\(result.confidence), GPU seconds=\(result.gpuSeconds)", named: "crop-detection")
        #expect(result.accepted)
        #expect(abs(result.proposal.centerX - 0.5) < 0.015)
        #expect(abs(result.proposal.centerY - 0.5) < 0.015)
        #expect(abs(result.proposal.width - 0.708) < 0.025)
        #expect(abs(result.proposal.height - 0.568) < 0.025)
        #expect(abs(result.proposal.degrees - angle) <= 0.5)
        #expect(result.borderBase.w == 1)
        #expect(abs(result.borderBase.x - 0.8) < 0.01)
    }

    @Test func `Camera scan and off-center exposure retain position and rotation`() async throws {
        let ctx = try context()
        let result = try #require(await AutoCropDetector(context: ctx).analyze(fixture(ctx, degrees: -2.75, camera: true, centerX: 0.525)))
        #expect(result.accepted)
        #expect(abs(result.proposal.centerX - 0.525) < 0.015)
        #expect(abs(result.proposal.degrees + 2.75) <= 0.5)
        #expect(abs(result.proposal.width - 0.708) < 0.025)
    }

    @Test func `Uniform input has low confidence and bypasses automatic crop`() async throws {
        let ctx = try context()
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: 128, height: 128, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        let texture = try #require(ctx.device.makeTexture(descriptor: d))
        let pixels = [SIMD4<Float>](repeating: SIMD4(0.4,0.2,0.1,1),count: 128*128)
        pixels.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0,0,128,128), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 128*16) }
        var metadata = ImageMetadata(width: 128,height: 128)
        metadata.domain = .linearTransmittance
        let input = ImageData(texture: texture, metadata: metadata)
        let result = try #require(await AutoCropDetector(context: ctx).analyze(input))
        #expect(!result.accepted)
        #expect(result.borderBase.w == 0)
        let processor = AutoCropProcessor(context: ctx)
        var node = NodeData(type: .autoCrop, position: .zero)
        let output = try #require(await processor.process(inputs: ["Input": input], node: node, context: ctx)?["Output"])
        #expect(output.contentID == input.contentID)
        node.autoCrop?.rollSize = CropGeometry(width: 0.7,height: 0.5)
        #expect(await processor.process(inputs: ["Input": input], node: node, context: ctx) == nil)
    }

    @Test func `Crop document preserves manual rotation roll size and per-frame offsets`() throws {
        var node = NodeData(type: .autoCrop, position: .zero)
        node.autoCrop?.manual = CropGeometry(centerX: 0.51, centerY: 0.49,width: 0.7,height: 0.5,degrees: 3)
        node.autoCrop?.rollSize = CropGeometry(width: 0.7,height: 0.5)
        node.autoCrop?.rollSourceWidth = 640
        node.autoCrop?.rollSourceHeight = 480
        let url = URL(fileURLWithPath: "/fixtures/frame.tiff")
        node.autoCrop?.frameOffsets[url.path] = CropOffset(x: 0.01,y: -0.02,degrees: 0.5)
        let document = FlowDocument(version: "1.0", sourceFile: nil, metadata: DocumentMetadata(), nodeGraph: NodeGraph(nodes: [node]))
        let restored = try JSONDecoder().decode(FlowDocument.self, from: JSONEncoder().encode(document))
        #expect(restored.nodeGraph.nodes == [node])
        let settings = try #require(restored.nodeGraph.nodes.first?.autoCrop)
        let rect = settings.geometry(proposal: CropGeometry(centerX: 0.48,centerY: 0.52,width: 0.8,height: 0.6,degrees: 2), source: url,sourceWidth: 800,sourceHeight: 600)
        #expect(abs(rect.width * 800 - 448) < 1e-8)
        #expect(abs(rect.height * 600 - 240) < 1e-8)
        #expect(abs(rect.centerX - 0.49) < 1e-8)
        #expect(abs(rect.centerY - 0.5) < 1e-8)
        #expect(rect.degrees == 2.5)
        #expect(!CropGeometry(width: 0.99,height: 0.99,degrees: 10).isValid(width: 640,height: 480))
        #expect(!CropGeometry(centerX: .nan).isValid(width: 640,height: 480))
    }

    @Test func `Crop is GPU resident aligns infrared and feeds detected film base`() async throws {
        let ctx = try context()
        let input = try fixture(ctx, degrees: 3.5)
        let withIR = ImageData(texture: input.texture, metadata: input.metadata, infraredTexture: input.texture)
        let node = NodeData(type: .autoCrop, position: .zero)
        let cropped = try #require(await AutoCropProcessor(context: ctx).process(inputs: ["Input": withIR], node: node, context: ctx)?["Output"])
        #expect(cropped.cgImage == nil)
        #expect(cropped.texture.width > 435 && cropped.texture.width < 465)
        #expect(cropped.texture.height > 260 && cropped.texture.height < 285)
        #expect(cropped.infraredTexture?.width == cropped.texture.width)
        #expect(cropped.infraredTexture?.height == cropped.texture.height)
        #expect(cropped.metadata.cropFilmBase?.w == 1)
        let metered = try #require(await NegativeMetering(context: ctx).analyze(cropped, parameters: ["autoBase": 1]))
        #expect(abs(metered.result.base.x - 0.8) < 0.01)
        #expect(abs(metered.result.base.y - 0.4) < 0.01)
        #expect(abs(metered.result.base.z - 0.2) < 0.01)
        let manual = try #require(await NegativeMetering(context: ctx).analyze(cropped, parameters: ["autoBase": 0, "baseR": 0.6]))
        // The automatic summary is ignored by develop when autoBase is off;
        // manual controls continue to own the print calibration.
        #expect(manual.result.base != metered.result.base)
    }

    @Test func `Saved manual crop controls preview export and pixel orientation`() async throws {
        let ctx = try context()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CropTests-\(UUID())")
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try fixture(ctx, degrees: 0,defects: false)
        let cg = try #require(NegativeImageIO.boundaryImage(input.texture, context: ctx.linearCIContext))
        let url = root.appendingPathComponent("scan.tiff")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL,UTType.tiff.identifier as CFString,1,nil))
        CGImageDestinationAddImage(destination,cg,nil)
        try #require(CGImageDestinationFinalize(destination))
        var source = NodeData(type: .imageInput,position: .zero)
        source.imageURL = url
        var crop = NodeData(type: .autoCrop,position: .zero)
        crop.autoCrop?.manual = CropGeometry(width: 0.5,height: 0.4)
        let preview = NodeData(type: .preview,position: .zero)
        let graph = NodeGraph(nodes: [source,crop,preview], connections: [
            Connection(fromNodeId: source.id,fromOutput: "Image",toNodeId: crop.id,toInput: "Input"),
            Connection(fromNodeId: crop.id,fromOutput: "Output",toNodeId: preview.id,toInput: "Input")])
        let restored = try JSONDecoder().decode(NodeGraph.self,from: JSONEncoder().encode(graph))
        let kit = RawrKit()
        kit.maxPreviewDimension = 160
        try #require(await kit.executeGraph(restored))
        #expect(kit.processedPreviewImage?.width == 160)
        #expect(kit.processedPreviewImage?.height == 96)
        let outputURL = root.appendingPathComponent("cropped.tiff")
        try #require(await kit.exportImage(restored,to: outputURL))
        let exported = try ImageDecoder(context: ctx.ciContext).decode(url: outputURL)
        #expect(exported.width == 320)
        #expect(exported.height == 192)
        let expected = try #require(cg.cropping(to: CGRect(x: 160,y: 144,width: 320,height: 192)))
        var actualBytes = [Float](repeating: 0,count: 320*192*4)
        var expectedBytes = actualBytes
        ctx.linearCIContext.render(CIImage(cgImage: exported),toBitmap: &actualBytes,rowBytes: 320*16,
            bounds: CGRect(x: 0,y: 0,width: 320,height: 192),format: .RGBAf,colorSpace: NegativeImageIO.colorSpace)
        ctx.linearCIContext.render(CIImage(cgImage: expected),toBitmap: &expectedBytes,rowBytes: 320*16,
            bounds: CGRect(x: 0,y: 0,width: 320,height: 192),format: .RGBAf,colorSpace: NegativeImageIO.colorSpace)
        let error = zip(actualBytes,expectedBytes).map { abs($0-$1) }.max() ?? 1
        #expect(error < 0.0002)
    }

    @Test func `Auto Crop controls render headlessly`() async throws {
        let ctx = try context()
        let result = try #require(await AutoCropDetector(context: ctx).analyze(fixture(ctx,degrees: 3.5)))
        var settings = AutoCropSettings()
        settings.rollSize = result.proposal
        let view = HStack(alignment: .top,spacing: 24) {
            VStack { Label("Auto Crop",systemImage: "crop.rotate"); AutoCropControls(settings: settings,result: result,onChange: { _ in }) }
                .frame(width: 245)
            VStack {
                Text("Source frame and straightened crop").font(.headline)
                CropOutline(geometry: result.proposal,sourceWidth: 640,sourceHeight: 480).frame(width: 400,height: 300)
                Text("Synthetic holder, sprocket and light-leak fixture").font(.caption)
            }
        }.padding().background(.background).frame(width: 740,height: 760)
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(x: 0,y: 0,width: 740,height: 760)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds,to: bitmap)
        Attachment.record(try #require(bitmap.representation(using: .png,properties: [:])),named: "auto-crop-controls.png")
    }
}
