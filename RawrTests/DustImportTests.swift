import Testing
import Foundation
import CoreImage
import Metal
import ImageIO
import UniformTypeIdentifiers

@Suite(.serialized)
@MainActor
struct DustImportTests {
    private func context() throws -> ProcessingContext {
        let d = try #require(MTLCreateSystemDefaultDevice())
        return ProcessingContext(device: d, commandQueue: try #require(d.makeCommandQueue()), ciContext: CIContext(mtlDevice: d))
    }

    /// Independent baseline TIFF fixture writer. IR is an unspecified extra
    /// channel, not alpha. Both endian variants exercise the file boundary.
    private func scanner(_ url: URL, little: Bool, extra: Int = 0, compression: Int = 1, orientation: Int = 1) throws {
        let w=32, h=24
        let entries: [(Int, Int, [Int])] = [
            (256,4,[w]), (257,4,[h]), (258,3,[16,16,16,16]), (259,3,[compression]), (262,3,[2]),
            (273,4,[0]), (274,3,[orientation]), (277,3,[4]), (278,4,[h]), (279,4,[w*h*8]),
            (284,3,[1]), (338,3,[extra]), (339,3,[1,1,1,1])]
        var data=Data()
        func append(_ value: Int, bytes: Int) {
            for i in 0..<bytes { data.append(UInt8((value >> (8*(little ? i : bytes-i-1))) & 255)) }
        }
        data.append(contentsOf: little ? [73,73] : [77,77])
        append(42,bytes:2); append(8,bytes:4); append(entries.count,bytes:2)
        let auxiliary=8+2+entries.count*12+4
        for (tag,type,values) in entries {
            append(tag,bytes:2); append(type,bytes:2); append(values.count,bytes:4)
            if values.count>1 { append(tag == 258 ? auxiliary : auxiliary+8,bytes:4) }
            else { append(values[0],bytes:type==3 ? 2 : 4); if type==3 { append(0,bytes:2) } }
        }
        append(0,bytes:4)
        for v in [16,16,16,16,1,1,1,1] { append(v,bytes:2) }
        // Patch StripOffsets after writing the variable-length IFD payload.
        let stripEntry=8+2+5*12+8
        let offset=data.count
        for i in 0..<4 { data[stripEntry+i]=UInt8((offset >> (8*(little ? i : 3-i))) & 255) }
        for y in 0..<h { for x in 0..<w {
            let dirty=x==10 && y==10
            for v in [dirty ? 8000 : 28000, dirty ? 8000 : 28000, dirty ? 8000 : 28000,
                extra == 2 ? 65535 : (dirty ? 8000 : 54000)] { append(v,bytes:2) }
        } }
        try data.write(to:url)
    }

    @Test(arguments: [true,false])
    func `Scanner fourth channel is IR while alpha is never auto interpreted`(little: Bool) async throws {
        let ctx=try context()
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let url=root.appendingPathComponent("scanner.tiff")
        try scanner(url,little:little,orientation:6)
        let source=try NegativeImageIO.load(url:url,context:ctx)
        #expect(source.infraredTexture != nil)
        #expect(source.texture.width==24 && source.texture.height==32)
        #expect(source.infraredTexture?.width==24 && source.infraredTexture?.height==32)
        let ir=try #require(source.infraredTexture)
        let buffer=try #require(ctx.device.makeBuffer(length:ir.width*ir.height*4))
        let command=try #require(ctx.commandQueue.makeCommandBuffer()), blit=try #require(command.makeBlitCommandEncoder())
        blit.copy(from:ir,sourceSlice:0,sourceLevel:0,sourceOrigin:MTLOrigin(),
            sourceSize:MTLSize(width:ir.width,height:ir.height,depth:1),to:buffer,destinationOffset:0,
            destinationBytesPerRow:ir.width*4,destinationBytesPerImage:ir.width*ir.height*4)
        blit.endEncoding(); command.commit(); await command.completed()
        try #require(command.status == .completed)
        let samples=Array(UnsafeBufferPointer(start:buffer.contents().assumingMemoryBound(to:Float.self),count:ir.width*ir.height))
        #expect(abs(try #require(samples.max())-54000.0/65535.0)<0.0001)
        #expect(abs(try #require(samples.min())-8000.0/65535.0)<0.0001)
        let alpha=root.appendingPathComponent("alpha.tiff")
        try scanner(alpha,little:little,extra:2,orientation:6)
        #expect(try InfraredImageIO.scannerTIFF(url:alpha,context:ctx)==nil)
        let ordinary=try NegativeImageIO.load(url:alpha,context:ctx)
        let scannerImage=try #require(NegativeImageIO.boundaryImage(source.texture,context:ctx.linearCIContext))
        let ordinaryImage=try #require(NegativeImageIO.boundaryImage(ordinary.texture,context:ctx.linearCIContext))
        let scannerBytes=try #require(scannerImage.dataProvider?.data) as Data
        let ordinaryBytes=try #require(ordinaryImage.dataProvider?.data) as Data
        #expect(scannerBytes==ordinaryBytes, "Embedded IR extraction must retain ImageIO orientation and RGB values")
        let unsupported=root.appendingPathComponent("compressed.tiff")
        try scanner(unsupported,little:little,compression:5)
        #expect(throws: InfraredImageIO.ScannerError.self) { try InfraredImageIO.scannerTIFF(url:unsupported,context:ctx) }
        let malformed=root.appendingPathComponent("truncated.tiff")
        try Data(contentsOf:url).prefix(200).write(to:malformed)
        #expect(throws: (any Error).self) { try InfraredImageIO.scannerTIFF(url:malformed,context:ctx) }
    }

    @Test func `Graph cleanup precedes development and separate IR survives flow encoding`() async throws {
        let ctx=try context(), kit=RawrKit()
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let url=root.appendingPathComponent("scanner.tiff")
        try scanner(url,little:true)
        let loaded=try NegativeImageIO.load(url:url,context:ctx)
        let ir=try #require(loaded.infraredTexture)
        let separate=root.appendingPathComponent("ir.tiff")
        let cg=try #require(NegativeImageIO.boundaryImage(ir,context:ctx.linearCIContext))
        let dest=try #require(CGImageDestinationCreateWithURL(separate as CFURL,UTType.tiff.identifier as CFString,1,nil))
        CGImageDestinationAddImage(dest,cg,nil)
        try #require(CGImageDestinationFinalize(dest))
        var input=NodeData(type:.imageInput,position:.zero); input.imageURL=url
        var dust=NodeData(type:.dustRemoval,position:.zero)
        dust.infraredURL=separate
        dust.infraredBookmark=RawrKit.createSecurityBookmark(for:separate)
        let develop=NodeData(type:.negativeDevelop,position:.zero)
        let preview=NodeData(type:.preview,position:.zero)
        let graph=NodeGraph(nodes:[input,dust,develop,preview],connections:[
            Connection(fromNodeId:input.id,fromOutput:"Image",toNodeId:dust.id,toInput:"Input"),
            Connection(fromNodeId:dust.id,fromOutput:"Output",toNodeId:develop.id,toInput:"Input"),
            Connection(fromNodeId:develop.id,fromOutput:"Output",toNodeId:preview.id,toInput:"Input")])
        var restored=try JSONDecoder().decode(NodeGraph.self,from:JSONEncoder().encode(graph))
        #expect(restored.nodes[1].infraredURL==separate)
        #expect(restored.nodes[1].infraredBookmark==dust.infraredBookmark)
        try #require(await kit.executeGraph(restored))
        #expect(kit.logs.contains { $0.message.contains("infrared ratio") })
        let normalPreview=try #require(kit.processedPreviewImage?.dataProvider?.data) as Data
        try #require(await kit.exportImage(restored,to:root.appendingPathComponent("positive.tiff")))
        restored.nodes[1].parameters["maskPreview"]=1
        try #require(await kit.executeGraph(restored))
        let maskPreview=try #require(kit.processedPreviewImage?.dataProvider?.data) as Data
        #expect(maskPreview != normalPreview)
        try #require(await kit.exportImage(restored,to:root.appendingPathComponent("mask-toggle-export.tiff")))
        func exportedPixels(_ name: String) throws -> Data {
            let s=try #require(CGImageSourceCreateWithURL(root.appendingPathComponent(name) as CFURL,nil))
            let image=try #require(CGImageSourceCreateImageAtIndex(s,0,nil))
            return try #require(image.dataProvider?.data) as Data
        }
        #expect(try exportedPixels("positive.tiff") == exportedPixels("mask-toggle-export.tiff"))
        var noIR=restored
        noIR.nodes[1].infraredURL=nil; noIR.nodes[1].infraredBookmark=nil
        noIR.nodes[1].parameters["useIR"]=0
        try #require(await kit.executeGraph(noIR))
        #expect(kit.logs.contains { $0.message.contains("RGB fallback") })
    }

    @Test func `24 MP optical infrared and manual GPU timings`() async throws {
        let ctx=try context(), w=6000, h=4000
        func texture(_ format: MTLPixelFormat) throws -> MTLTexture {
            let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:format,width:w,height:h,mipmapped:false)
            d.storageMode = .private; d.usage=[.shaderRead,.shaderWrite]
            return try #require(ctx.device.makeTexture(descriptor:d))
        }
        let rgb=try texture(.rgba32Float), ir=try texture(.r32Float)
        let fixture=try #require(ctx.shaderLibrary?.makeFunction(name:"dustBenchmarkFixture"))
        let pipeline=try await ctx.device.makeComputePipelineState(function:fixture)
        let command=try #require(ctx.commandQueue.makeCommandBuffer()), encoder=try #require(command.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline); encoder.setTexture(rgb,index:0); encoder.setTexture(ir,index:1)
        encoder.dispatchThreads(MTLSize(width:w,height:h,depth:1),threadsPerThreadgroup:MTLSize(width:32,height:4,depth:1))
        encoder.endEncoding(); command.commit(); await command.completed()
        try #require(command.status == .completed)
        var metadata=ImageMetadata(width:w,height:h); metadata.domain = .linearTransmittance
        let processor=DustRemovalProcessor(context:ctx)
        var rows=[String]()
        for mode in ["optical","infrared","manual"] {
            var node=NodeData(type:.dustRemoval,position:.zero)
            if mode=="manual" { node.healSpots=[HealSpot(x:0.2,y:0.3,radius:0.002)] }
            let start=ContinuousClock.now
            let result=try #require(await processor.process(inputs:["Input":ImageData(texture:rgb,metadata:metadata,
                infraredTexture:mode=="infrared" ? ir : nil)],node:node,context:ctx))
            let duration=start.duration(to:.now)
            #expect(result["Output"]?.cgImage==nil)
            #expect(result["Output"]?.texture.width==w)
            rows.append("\(mode): wall \(duration); GPU \(processor.lastGPUTime.map { String(format: "%.3f ms", $0*1000) } ?? "unavailable")")
        }
        Attachment.record("Device: \(ctx.device.name); 6000x4000 (24 MP), full-res, no intermediate image readbacks\n"+rows.joined(separator:"\n"),named:"dust-24mp-timings")
    }
}
