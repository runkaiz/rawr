import Foundation
import Testing
import Metal
import CoreImage
import SwiftUI
import AppKit

@Suite(.serialized)
@MainActor
struct NegativeMeteringTests {
    private func context() throws -> ProcessingContext {
        let device = try #require(MTLCreateSystemDefaultDevice())
        return ProcessingContext(device: device, commandQueue: try #require(device.makeCommandQueue()),
            ciContext: CIContext(mtlDevice: device))
    }

    private let automatic: [String: Double] = ["autoBase": 1, "autoEndpoints": 1, "autoBalance": 1]

    @Test func `Thin scanner strips survive black holder and textured broad borders`() async throws {
        let ctx = try context(), w = 512, h = 512
        let base = SIMD3<Double>(0.60,0.20,0.09)
        var pixels = [SIMD4<Float>](), polluted = [SIMD4<Float>](), noBorder = [SIMD4<Float>]()
        func grain(_ x:Int,_ y:Int,_ channel:Int) -> Double {
            var n=UInt32(truncatingIfNeeded:(x+y*w)*374761393+channel*668265263)
            n=(n ^ (n >> 13)) &* 1274126177; n ^= n >> 16
            return Double(n & 65535)/32767.5-1
        }
        for y in 0..<h { for x in 0..<w {
            let u = Double(x)/Double(w), v = Double(y)/Double(h)
            let holder = u<0.006 || v<0.006 || u>0.994 || v>0.994
            let clear = !holder && (u<0.014 || v<0.014 || u>0.986 || v>0.986)
            let g = 0.15+1.1*u+0.3*v
            let chroma = 0.05*sin(Double(x*7+y*11))
            let density = clear ? SIMD3<Double>(repeating:0) : SIMD3(0.08+1.04*g+chroma,g,-0.03+0.96*g-chroma)
            let noise=SIMD3(1+0.10*grain(x,y,0),1+0.16*grain(x,y,1),1+0.24*grain(x,y,2))
            let value = SIMD4<Float>(Float(base.x*pow(10,-density.x)*noise.x),Float(base.y*pow(10,-density.y)*noise.y),Float(base.z*pow(10,-density.z)*noise.z),1)
            pixels.append(holder ? SIMD4(0,0,0,1):value)
            let scene=SIMD3(0.08+1.04*g+chroma,g,-0.03+0.96*g-chroma)
            noBorder.append(SIMD4(Float(base.x*pow(10,-scene.x)*noise.x),Float(base.y*pow(10,-scene.y)*noise.y),Float(base.z*pow(10,-scene.z)*noise.z),1))
            polluted.append(SIMD4(Float(0.3+0.2*sin(Double(x))),Float(0.2+0.1*cos(Double(y))),Float(0.1+0.05*sin(Double(x+y))),1))
        } }
        let result = try #require(await NegativeMetering(context:ctx).analyze(try image(pixels,width:w,height:h,context:ctx),parameters:automatic)).result
        for c in 0..<3 { #expect(abs(Double(result.base[c])/base[c]-1)<0.025) }
        #expect(result.base.w>0.5 && result.low.w>0.5)
        #expect(result.offset.w>0.1)
        let bad = try #require(await NegativeMetering(context:ctx).analyze(try image(polluted,width:w,height:h,context:ctx),parameters:automatic)).result
        #expect(bad.base.w<0.5)
        let missing = try #require(await NegativeMetering(context:ctx).analyze(try image(noBorder,width:w,height:h,context:ctx),parameters:automatic)).result
        #expect(missing.base.w<0.2)
        Attachment.record("Thin scanner border: \(result); textured bad input: \(bad)",named:"scanner-border-confidence")
    }

    private func fixture(width: Int = 256, height: Int = 256, border: Bool = true, clipped: Bool = false) -> [SIMD4<Float>] {
        var pixels = [SIMD4<Float>]()
        pixels.reserveCapacity(width * height)
        for y in 0..<height {
            for x in 0..<width {
                let edge = Double(x) < Double(width)*0.05 || Double(x) >= Double(width)*0.95 ||
                    Double(y) < Double(height)*0.05 || Double(y) >= Double(height)*0.95
                let g = 0.2 + 2 * Double(x) / Double(width-1)
                let densities = border && edge ? SIMD3<Double>(repeating: 0) : SIMD3(0.12 + 1.1*g, g, -0.05 + 0.9*g)
                let p = SIMD4<Float>(Float(0.8*pow(10,-densities.x)), Float(0.4*pow(10,-densities.y)), Float(0.2*pow(10,-densities.z)), 1)
                pixels.append(clipped && (x+y*width)%10 != 0 ? SIMD4(1,1,1,1) : p)
            }
        }
        return pixels
    }

    private func image(_ pixels: [SIMD4<Float>], width: Int, height: Int, context: ProcessingContext) throws -> ImageData {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        let texture = try #require(context.device.makeTexture(descriptor: descriptor))
        pixels.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0,0,width,height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width*16)
        }
        var metadata = ImageMetadata(width: width, height: height)
        metadata.domain = .linearTransmittance
        return ImageData(texture: texture, metadata: metadata)
    }

    // Float64 oracle uses sorted exact samples and scalar least squares, with no
    // production helpers, histograms or GPU summary readback in its computation.
    private func reference(_ pixels: [SIMD4<Float>], width: Int, height: Int) -> (SIMD3<Double>, Double, Double, SIMD3<Double>, SIMD3<Double>) {
        var border: [SIMD3<Double>] = [], interior: [SIMD3<Double>] = []
        for y in 0..<height {
            for x in 0..<width {
                let p = pixels[y*width+x]
                guard (0..<3).allSatisfy({ p[$0].isFinite && p[$0] > 1e-6 && p[$0] < 0.99999 }), p.w >= 0.99 else { continue }
                let v = SIMD3(Double(p.x),Double(p.y),Double(p.z))
                if Double(x) < Double(width)*0.05 || Double(x) >= Double(width)*0.95 ||
                    Double(y) < Double(height)*0.05 || Double(y) >= Double(height)*0.95 { border.append(v) }
                else { interior.append(v) }
            }
        }
        func q(_ values: [Double], _ fraction: Double) -> Double {
            let sorted = values.sorted()
            return sorted[max(0,Int(ceil(Double(sorted.count)*fraction))-1)]
        }
        let base = SIMD3(q(border.map(\.x),0.9),q(border.map(\.y),0.9),q(border.map(\.z),0.9))
        let density = interior.map { v in SIMD3(-log10(v.x/base.x),-log10(v.y/base.y),-log10(v.z/base.z)) }
        let low = SIMD3(q(density.map(\.x),0.01),q(density.map(\.y),0.01),q(density.map(\.z),0.01))
        let high = SIMD3(q(density.map(\.x),0.99),q(density.map(\.y),0.99),q(density.map(\.z),0.99))
        let selected = density.filter { v in
            let n = (v-low)/(high-low)
            return (0..<3).allSatisfy { n[$0] >= 0.1 && n[$0] <= 0.9 } &&
                max(n.x,n.y,n.z)-min(n.x,n.y,n.z) <= 0.12
        }
        let n = Double(selected.count)
        let mean = selected.reduce(SIMD3<Double>(repeating:0),+) / n
        let variance = selected.reduce(0.0) { $0 + pow($1.y-mean.y,2) }
        let r = selected.reduce(0.0) { $0 + ($1.y-mean.y)*($1.x-mean.x) }/variance
        let b = selected.reduce(0.0) { $0 + ($1.y-mean.y)*($1.z-mean.z) }/variance
        let slope = SIMD3(r,1,b)
        return (base,low.y,high.y,mean-slope*mean.y,slope)
    }

    @Test func `GPU base percentiles and neutral axis recover a known cast and match Float64`() async throws {
        let ctx = try context(), pixels = fixture()
        let input = try image(pixels,width:256,height:256,context:ctx)
        let output = try #require(await NegativeMetering(context:ctx).analyze(input,parameters:automatic))
        let r = output.result, cpu = reference(pixels,width:256,height:256)
        for c in 0..<3 {
            #expect(abs(Double(r.base[c])-cpu.0[c]) < 0.004)
            #expect(abs(Double(r.offset[c])-cpu.3[c]) < 0.006)
            #expect(abs(Double(r.slope[c])-cpu.4[c]) < 0.004)
        }
        #expect(abs(Double(r.low.y)-cpu.1) < 0.005)
        #expect(abs(Double(r.high.y)-cpu.2) < 0.005)
        #expect(abs(r.offset.x-0.12) < 0.006)
        #expect(abs(r.offset.z+0.05) < 0.006)
        #expect(abs(r.slope.x-1.1) < 0.004)
        #expect(abs(r.slope.z-0.9) < 0.004)
        #expect(r.base.w > 0.9 && r.low.w > 0.9 && r.offset.w > 0.9)
        Attachment.record("GPU summary: \(r); Float64 base/endpoints/axis: \(cpu)",named:"metering-reference")
    }

    @Test func `Missing border clipping and invalid samples reduce confidence`() async throws {
        let ctx = try context(), meter = NegativeMetering(context:ctx)
        let good = try #require(await meter.analyze(try image(fixture(),width:256,height:256,context:ctx),parameters:automatic)).result
        let noBorder = try #require(await meter.analyze(try image(fixture(border:false),width:256,height:256,context:ctx),parameters:automatic)).result
        let clipped = try #require(await meter.analyze(try image(fixture(clipped:true),width:256,height:256,context:ctx),parameters:automatic)).result
        #expect(noBorder.base.w < 0.2 && noBorder.base.w < good.base.w)
        #expect(noBorder.low.w < good.low.w*0.5 && noBorder.offset.w < good.offset.w*0.5)
        #expect(clipped.base.w < good.base.w*0.2)
        #expect(clipped.low.w < good.low.w*0.2)
        #expect(clipped.offset.w < good.offset.w*0.2)
        let invalid = [SIMD4<Float>](repeating:SIMD4(.nan,0,.infinity,0),count:64*64)
        let bad = try #require(await meter.analyze(try image(invalid,width:64,height:64,context:ctx),parameters:automatic)).result
        #expect(bad.base.w == 0 && bad.low.w == 0 && bad.offset.w == 0)
        for vector in [bad.base,bad.low,bad.high,bad.offset,bad.slope,bad.quality] {
            #expect((0..<4).allSatisfy { vector[$0].isFinite })
        }
    }

    @Test func `Cache follows source identity and effective base but reuses curve edits`() async throws {
        let ctx = try context(), meter = NegativeMetering(context:ctx)
        let input = try image(fixture(),width:256,height:256,context:ctx)
        let a = try #require(await meter.analyze(input,parameters:automatic))
        var changed = automatic
        changed.merge(["exposure":2,"toe":0.2,"autoEndpoints":0,"autoBalance":0,"balanceR":0.1]) { _,new in new }
        let b = try #require(await meter.analyze(input,parameters:changed))
        #expect(a.buffer === b.buffer)
        #expect(await meter.computationCount == 1)
        changed["autoBase"] = 0; changed["baseR"] = 0.7
        let c = try #require(await meter.analyze(input,parameters:changed))
        #expect(c.buffer !== a.buffer)
        let replacement = try image(fixture(border:false),width:256,height:256,context:ctx)
        _ = await meter.analyze(replacement,parameters:automatic)
        #expect(await meter.computationCount == 3)
    }

    @Test func `Manual overrides win and locking survives a document roundtrip`() async throws {
        let ctx = try context(), input = try image(fixture(),width:256,height:256,context:ctx)
        let r = try #require(await NegativeMetering(context:ctx).analyze(input,parameters:automatic)).result
        var node = NodeData(type:.negativeDevelop,position:.zero)
        node.parameters = automatic.merging(["baseR":0.7,"baseG":0.3,"baseB":0.15,
            "autoBase":0,"autoEndpoints":0,"autoBalance":0,"lowR":0.1,"highR":3,
            "balanceR":0.2,"slopeR":1.2]) { _,new in new }
        let output = try #require(await NegativeDevelopProcessor(context:ctx).process(inputs:["Input":input],node:node,context:ctx)?["Output"])
        let buffer = try #require(ctx.device.makeBuffer(length:256*256*16))
        let command = try #require(ctx.commandQueue.makeCommandBuffer()), blit = try #require(command.makeBlitCommandEncoder())
        blit.copy(from:output.texture,sourceSlice:0,sourceLevel:0,sourceOrigin:MTLOrigin(),sourceSize:MTLSize(width:256,height:256,depth:1),to:buffer,destinationOffset:0,destinationBytesPerRow:256*16,destinationBytesPerImage:256*256*16)
        blit.endEncoding(); command.commit(); await command.completed()
        let actual = buffer.contents().assumingMemoryBound(to:SIMD4<Float>.self)[128*256+128]
        let p = fixture()[128*256+128]
        let expected = max(0,min(1,((-log10(Double(p.x)/0.7)-0.2)/1.2-0.1)/2.9))
        #expect(abs(Double(actual.x)-expected) < 1e-5)
        #expect(output.cgImage == nil)
        var locked = automatic
        for group in ["Endpoints","Base","Balance"] { locked = r.locking(group,in:locked) }
        node.parameters = locked
        let decoded = try JSONDecoder().decode(NodeData.self,from:JSONEncoder().encode(node))
        #expect(decoded.parameters == locked.merging(NegativeDevelopParameters.defaults) { saved,_ in saved })
        #expect(decoded.parameters["autoBase"] == 0 && decoded.parameters["autoEndpoints"] == 0 && decoded.parameters["autoBalance"] == 0)
        #expect(decoded.parameters["baseR"] == Double(r.base.x))
        #expect(decoded.parameters["balanceR"] == Double(r.offset.x))
    }

    @Test func `Automatic development neutralizes the cast and source edits invalidate summaries`() async throws {
        let ctx = try context(), pixels = fixture()
        let input = try image(pixels,width:256,height:256,context:ctx)
        let node = NodeData(type:.negativeDevelop,position:.zero)
        let output = try #require(await NegativeDevelopProcessor(context:ctx).process(inputs:["Input":input],node:node,context:ctx)?["Output"])
        let buffer = try #require(ctx.device.makeBuffer(length:256*256*16))
        let command = try #require(ctx.commandQueue.makeCommandBuffer()), blit = try #require(command.makeBlitCommandEncoder())
        blit.copy(from:output.texture,sourceSlice:0,sourceLevel:0,sourceOrigin:MTLOrigin(),sourceSize:MTLSize(width:256,height:256,depth:1),to:buffer,destinationOffset:0,destinationBytesPerRow:256*16,destinationBytesPerImage:256*256*16)
        blit.endEncoding(); command.commit(); await command.completed()
        let actual = buffer.contents().assumingMemoryBound(to:SIMD4<Float>.self)
        for x in 40..<210 {
            let v = actual[128*256+x]
            #expect(abs(v.x-v.y) < 0.0001 && abs(v.z-v.y) < 0.0001)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MeterCache-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let url = root.appendingPathComponent("source.tiff")
        func write(_ pixels: [SIMD4<Float>]) throws {
            let data = pixels.withUnsafeBytes { Data($0) }
            let image = CIImage(bitmapData:data,bytesPerRow:256*16,size:CGSize(width:256,height:256),format:.RGBAf,colorSpace:NegativeImageIO.colorSpace)
            try ctx.linearCIContext.writeTIFFRepresentation(of:image,to:url,format:.RGBAf,colorSpace:NegativeImageIO.colorSpace)
        }
        try write(pixels)
        let kit = RawrKit()
        let a = try #require(kit.loadNegativeSource(at:url,context:ctx))
        let b = try #require(kit.loadNegativeSource(at:url,context:ctx))
        #expect(a.contentID == b.contentID && a.texture === b.texture)
        // Same-size edits less than one second apart must not reuse stale data.
        let t = Date(timeIntervalSince1970:1_700_000_000.1)
        try FileManager.default.setAttributes([.modificationDate:t],ofItemAtPath:url.path)
        let c = try #require(kit.loadNegativeSource(at:url,context:ctx))
        try FileManager.default.setAttributes([.modificationDate:t.addingTimeInterval(0.1)],ofItemAtPath:url.path)
        let d = try #require(kit.loadNegativeSource(at:url,context:ctx))
        #expect(c.contentID != d.contentID)
        kit.clearSourceImageCache()
        let e = try #require(kit.loadNegativeSource(at:url,context:ctx))
        #expect(e.contentID != d.contentID)
    }

    @Test func `24 megapixel metering records cold warm and cached timings`() async throws {
        let ctx = try context()
        // Fixture generation/upload is deliberately excluded from analysis timing.
        let input = try image(fixture(width:6000,height:4000),width:6000,height:4000,context:ctx)
        var wall: [Double] = [], gpu: [Double] = []
        for _ in 0..<6 {
            let meter = NegativeMetering(context:ctx), start = Date()
            let result = try #require(await meter.analyze(input,parameters:automatic))
            wall.append(Date().timeIntervalSince(start)*1000); gpu.append(result.gpuSeconds*1000)
            #expect(result.result.base.w > 0.9)
        }
        let meter = NegativeMetering(context:ctx)
        _ = await meter.analyze(input,parameters:automatic)
        let start = Date()
        for _ in 0..<100 { _ = await meter.analyze(input,parameters:automatic) }
        Attachment.record("24 MP (6000x4000); analysis grid 512x512; cold then warm wall ms: \(wall); GPU ms: \(gpu); cached mean ms: \(Date().timeIntervalSince(start)*10); device: \(ctx.device.name)",named:"metering-24mp-performance")
    }

    @Test func `Automatic controls render headlessly with confidence and manual locks`() async throws {
        let ctx = try context(), input = try image(fixture(),width:256,height:256,context:ctx)
        let statistics = try #require(await NegativeMetering(context:ctx).analyze(input,parameters:automatic)).result
        let view = HStack(alignment:.top,spacing:24) {
            VStack { Text("Automatic metering"); NegativeDevelopControls(parameters:automatic,statistics:statistics,onChange:{ _ in }) }.frame(width:260)
            VStack { Text("Locked manual values"); NegativeDevelopControls(parameters:statistics.locking("Balance",in:statistics.locking("Endpoints",in:statistics.locking("Base",in:automatic))),statistics:statistics,onChange:{ _ in }) }.frame(width:260)
        }.padding().frame(width:600,height:720).environment(\.colorScheme,.light)
        let host = NSHostingView(rootView:view)
        host.frame = CGRect(x:0,y:0,width:600,height:720); host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in:host.bounds))
        host.cacheDisplay(in:host.bounds,to:bitmap)
        // Flatten the offscreen view over an opaque light background. Transparent
        // black labels otherwise disappear in dark attachment viewers.
        let cg = try #require(bitmap.cgImage)
        let canvas = try #require(CGContext(data:nil,width:cg.width,height:cg.height,bitsPerComponent:8,
            bytesPerRow:cg.width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,
            bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        canvas.setFillColor(CGColor(gray:1,alpha:1))
        canvas.fill(CGRect(x:0,y:0,width:cg.width,height:cg.height))
        canvas.draw(cg,in:CGRect(x:0,y:0,width:cg.width,height:cg.height))
        let flattened = NSBitmapImageRep(cgImage:try #require(canvas.makeImage()))
        Attachment.record(try #require(flattened.representation(using:.png,properties:[:])),named:"automatic-negative-metering.png")
    }
}
