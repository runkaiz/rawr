import Foundation
import Testing
import CoreImage
import Metal

@Suite(.serialized)
@MainActor
struct RealScanRegressionTests {
    /// Independent TIFF/DNG writer; no source photo or private metadata.
    private func dng(extra: UInt16 = 8000, usesExtra: Bool = false, compression: Int = 1,
                     black: Int = 4080, orientation: Int = 6) -> Data {
        func bytes(_ values: [Int], _ size: Int) -> Data {
            Data(values.flatMap { v in (0..<size).map { UInt8(truncatingIfNeeded:v >> ($0*8)) } })
        }
        var entries: [(Int,Int,Int,Data)] = []
        func short(_ tag:Int,_ values:[Int]) { entries.append((tag,3,values.count,bytes(values,2))) }
        func long(_ tag:Int,_ values:[Int]) { entries.append((tag,4,values.count,bytes(values,4))) }
        func rational(_ tag:Int,_ values:[Int], signed:Bool = false) {
            entries.append((tag,signed ? 10:5,values.count,bytes(values.flatMap{[$0,10000]},4)))
        }
        long(256,[256]); long(257,[272]); short(258,[16,16,16,16]); short(259,[compression]); short(262,[34892])
        long(273,[0]); short(274,[orientation]); short(277,[4]); long(278,[272]); long(279,[256*272*8]); short(284,[1])
        entries.append((50706,1,4,Data([1,4,0,0])))
        let model = Data("Rawr Synthetic Four Plane\0".utf8); entries.append((50708,2,model.count,model))
        rational(50721,[10000,0,0,0,10000,0,0,0,10000,0,10000,0],signed:true)
        rational(50725,[10000,0,0,0,0,usesExtra ? 8000:10000,0,usesExtra ? 2000:0,0,0,10000,0],signed:true)
        short(50713,[1,1]); rational(50714,[black*10000]); long(50717,[65535])
        rational(50729,[3127,3290]); short(50778,[21])
        entries.sort{$0.0<$1.0}
        var result = Data([73,73,42,0,8,0,0,0]); result.append(bytes([entries.count],2))
        var auxiliary = Data()
        let start = 8+2+entries.count*12+4
        for (tag,type,count,value) in entries {
            result.append(bytes([tag,type],2)); result.append(bytes([count],4))
            if value.count<=4 { result.append(value); result.append(Data(count:4-value.count)) }
            else { result.append(bytes([start+auxiliary.count],4)); auxiliary.append(value) }
        }
        result.append(Data(count:4)); result.append(auxiliary)
        let offset = 8+2+entries.firstIndex(where:{$0.0==273})!*12+8
        result.replaceSubrange(offset..<offset+4,with:bytes([result.count],4))
        for y in 0..<272 { for x in 0..<256 {
            result.append(bytes([black+6000+x*90,black+9000+y*80,black+12000+x*60,Int(extra)],2))
        } }
        return result
    }

    private func average(_ data:Data) throws -> [Float] {
        let filter = try #require(CIRAWFilter(imageData:data,identifierHint:"com.adobe.raw-image"))
        filter.exposure = 0; filter.baselineExposure = 0; filter.boostAmount = 0
        let image = try #require(filter.outputImage)
        let context = CIContext()
        try ImageDecoder.validateContent(image,context:context)
        let mean = image.applyingFilter("CIAreaAverage",parameters:[kCIInputExtentKey:CIVector(cgRect:image.extent)])
        var pixels = [Float](repeating:0,count:4)
        pixels.withUnsafeMutableBytes { context.render(mean,toBitmap:$0.baseAddress!,rowBytes:16,
            bounds:CGRect(x:0,y:0,width:1,height:1),format:.RGBAf,colorSpace:NegativeImageIO.colorSpace) }
        return pixels
    }

    @Test func `Four camera planes are reduced using calibration and never become alpha or IR`() throws {
        let a = try #require(try LinearDNG.threePlaneData(dng(extra:0)))
        let b = try #require(try LinearDNG.threePlaneData(dng(extra:60000)))
        #expect(a == b, "A zero reduction weight explicitly excludes the fourth colour plane")
        let first = try average(a)
        #expect(first[3]>0.99 && first[0]>0.01)
        let weighted = try #require(try LinearDNG.threePlaneData(dng(extra:60000,usesExtra:true)))
        #expect(weighted != a)
        let second = try average(weighted)
        #expect(abs(first[1]-second[1])>0.01, "Nonzero fourth-plane weights must contribute to colour")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let url = root.appendingPathComponent("four-plane.dng")
        try dng(extra:0).write(to:url)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let ctx = ProcessingContext(device:device,commandQueue:try #require(device.makeCommandQueue()),ciContext:CIContext(mtlDevice:device))
        let image = try NegativeImageIO.load(url:url,context:ctx)
        #expect(image.texture.width == 272 && image.texture.height == 256)
        #expect(image.infraredTexture == nil)
        let ordinary = try ImageDecoder(context:ctx.ciContext).decode(url:url)
        #expect(ordinary.width == 272 && ordinary.height == 256)
        #expect(throws: LinearDNG.LayoutError.self) { try LinearDNG.threePlaneData(dng(compression:5)) }
        #expect(throws: (any Error).self) { try LinearDNG.threePlaneData(Data(dng().dropLast(16))) }
    }

    @Test func `DNG black level is subtracted before colour reduction`() throws {
        let withBlack = try #require(try LinearDNG.threePlaneData(dng(black:4080)))
        let noBlack = try #require(try LinearDNG.threePlaneData(dng(black:0)))
        let a = try average(withBlack), b = try average(noBlack)
        // Both fixtures have identical signal above black; normalization differs
        // only by the documented white-minus-black denominator.
        #expect(a[0]>b[0])
        #expect(a[0]/b[0]<1.15)
    }

    @Test func `160 MP admission has a bounded preview and actionable export ceiling`() throws {
        let scale = try ImageDecoder.workingScale(width:15492,height:10332,allowDownscale:true)
        #expect(scale>0 && scale<1)
        #expect(15492*10332*Double(scale)*Double(scale)<24_010_000)
        #expect(throws: (any Error).self) {
            try ImageDecoder.workingScale(width:15492,height:10332,allowDownscale:false)
        }
        #expect(try ImageDecoder.workingScale(width:10000,height:10700,allowDownscale:false)==1)
        #expect(throws: (any Error).self) { try ImageDecoder.workingScale(width:.infinity,height:1,allowDownscale:true) }
    }

    @Test func `Invisible and opaque black RAW outputs fail decode acceptance`() throws {
        let ctx = CIContext()
        for color in [CIColor.clear,CIColor.black] {
            let image = CIImage(color:color).cropped(to:CGRect(x:0,y:0,width:32,height:32))
            #expect(throws: (any Error).self) { try ImageDecoder.validateContent(image,context:ctx) }
        }
    }

    @Test func `Base and endpoint roll evidence survives missing shared balance`() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let ctx = ProcessingContext(device:device,commandQueue:try #require(device.makeCommandQueue()),ciContext:CIContext(mtlDevice:device))
        var good = NegativeMeteringResult()
        good.base = SIMD4(0.6,0.2,0.1,0.9); good.low = SIMD4(0.1,0.1,0.1,0.9)
        good.high = SIMD4(1.2,1.2,1.2,0.9); good.quality = SIMD4(0.98,1,0,500)
        good.offset.w = 0.02
        let reduction = try #require(await RollReduction.reduce([good,good,good],context:ctx))
        #expect(reduction.statistics.quality.x==3)
        #expect(reduction.statistics.base.w>0.8 && reduction.statistics.offset.w==0)
        let insufficient = try #require(await RollReduction.reduce([good,good],context:ctx))
        #expect(insufficient.statistics.base.w==0)
    }
}
