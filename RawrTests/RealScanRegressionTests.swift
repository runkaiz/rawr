import Foundation
import Testing
import CoreImage
import Metal

private final class ScanFixtureBundle {}

@Suite(.serialized)
@MainActor
struct RealScanRegressionTests {
    /// Independent TIFF/DNG writer; no source photo or private metadata.
    private func dng(extra: UInt16 = 8000, usesExtra: Bool = false, compression: Int = 1,
                     black: Int = 4080, orientation: Int = 6, illuminant: Bool = true,
                     planes: Int = 4, privateBytes: Int = 0) -> Data {
        func bytes(_ values: [Int], _ size: Int) -> Data {
            Data(values.flatMap { v in (0..<size).map { UInt8(truncatingIfNeeded:v >> ($0*8)) } })
        }
        var entries: [(Int,Int,Int,Data)] = []
        func short(_ tag:Int,_ values:[Int]) { entries.append((tag,3,values.count,bytes(values,2))) }
        func long(_ tag:Int,_ values:[Int]) { entries.append((tag,4,values.count,bytes(values,4))) }
        func rational(_ tag:Int,_ values:[Int], signed:Bool = false) {
            entries.append((tag,signed ? 10:5,values.count,bytes(values.flatMap{[$0,10000]},4)))
        }
        long(256,[256]); long(257,[272]); short(258,Array(repeating:16,count:planes)); short(259,[compression]); short(262,[34892])
        long(273,[0]); short(274,[orientation]); short(277,[planes]); long(278,[272]); long(279,[256*272*planes*2]); short(284,[1])
        entries.append((50706,1,4,Data([1,4,0,0])))
        entries.append((50707,1,4,Data([1,1,0,0])))
        let model = Data("Rawr Synthetic Four Plane\0".utf8); entries.append((50708,2,model.count,model))
        rational(50721,Array([10000,0,0,0,10000,0,0,0,10000,0,10000,0].prefix(planes*3)),signed:true)
        if planes==4 { rational(50725,[10000,0,0,0,0,usesExtra ? 8000:10000,0,usesExtra ? 2000:0,0,0,10000,0],signed:true) }
        short(50713,[1,1]); rational(50714,Array(repeating:black*10000,count:planes)); long(50717,[65535])
        rational(50729,[3127,3290]); if illuminant { short(50778,[21]) }
        if privateBytes>0 {
            var payload=Data("Rawr Tests\0".utf8);payload.append(Data(count:privateBytes-payload.count))
            entries.append((50740,1,payload.count,payload))
        }
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
            result.append(bytes(Array([black+6000+x*90,black+9000+y*80,black+12000+x*60,Int(extra)].prefix(planes)),2))
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
        let scanner = try #require(try LinearDNG.threePlaneData(dng(black:0,illuminant:false)))
        let scannerMean = try average(scanner)
        #expect(scannerMean[3]>0.99 && scannerMean[0]>0.01)
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

    @Test func `Large opaque vendor metadata does not reject a three-plane DNG`() throws {
        let data=dng(planes:3,privateBytes:1_000_001)
        #expect(try LinearDNG.threePlaneData(data)==nil)
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
        let budget=NegativeImageIO.nativePixelLimit(physicalBytes:4*1024*1024*1024)
        #expect(budget>24_000_000 && budget<107_000_000)
        let memoryScale=try ImageDecoder.workingScale(width:10000,height:10700,allowDownscale:true,nativePixelLimit:budget)
        #expect(memoryScale<1 && 107_000_000*Double(memoryScale)*Double(memoryScale)<24_010_000)
        #expect(throws:(any Error).self) {
            try ImageDecoder.workingScale(width:10000,height:10700,allowDownscale:false,nativePixelLimit:budget)
        }
    }

    @Test func `An oversized synthetic sensor decodes a working preview before texture allocation`() throws {
        let bundle = Bundle(for:ScanFixtureBundle.self)
        let fixture = try #require(bundle.url(forResource:"sensor",withExtension:"dng",subdirectory:"Fixtures") ??
            bundle.url(forResource:"sensor",withExtension:"dng"))
        var header = try Data(contentsOf:fixture)
        func read(_ offset:Int,_ size:Int) -> Int {
            (0..<size).reduce(0) { $0 | Int(header[offset+$1]) << ($1*8) }
        }
        func write(_ offset:Int,_ value:Int) {
            for i in 0..<4 { header[offset+i] = UInt8(truncatingIfNeeded:value >> (i*8)) }
        }
        let count = read(8,2)
        let subEntry = try #require((0..<count).map{10+$0*12}.first(where:{read($0,2)==330}))
        let sub = read(subEntry+8,4), subCount = read(sub,2)
        let entries = Dictionary(uniqueKeysWithValues:(0..<subCount).map{ i in
            let offset=sub+2+i*12;return (read(offset,2),offset)
        })
        let w=12900, h=10000
        let pixelStart = read(try #require(entries[273])+8,4)
        write(try #require(entries[256])+8,w);write(try #require(entries[257])+8,h)
        write(try #require(entries[278])+8,h);write(try #require(entries[279])+8,w*h*2)
        let crop = read(try #require(entries[50720])+8,4)
        write(crop,w);write(crop+4,h)
        header = Data(header.prefix(pixelStart))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let url = root.appendingPathComponent("129mp-synthetic.dng")
        try header.write(to:url)
        let file = try FileHandle(forWritingTo:url)
        try file.seekToEnd()
        var row = Data(count:w*2)
        for x in 0..<w {
            let v = 10000+x*2
            row[x*2] = UInt8(truncatingIfNeeded:v);row[x*2+1] = UInt8(truncatingIfNeeded:v >> 8)
        }
        for _ in 0..<h { try file.write(contentsOf:row) }
        try file.close()
        let device = try #require(MTLCreateSystemDefaultDevice())
        let ctx = ProcessingContext(device:device,commandQueue:try #require(device.makeCommandQueue()),ciContext:CIContext(mtlDevice:device))
        let kit = RawrKit()
        let image = try #require(kit.loadNegativeSource(at:url,context:ctx))
        #expect(image.metadata.sourceWasDownscaled)
        #expect(image.texture.width*image.texture.height<=24_010_000)
        #expect(image.texture.width>1000)
        #expect(throws:(any Error).self) { try NegativeImageIO.load(url:url,context:ctx,allowDownscale:false) }
        kit.isFullResolutionMode = true
        #expect(kit.loadNegativeSource(at:url,context:ctx) == nil, "A cached working preview must never satisfy a full-resolution request")
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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let url = root.appendingPathComponent("frame.dng"); try Data([0]).write(to:url)
        var calibration = good.locking("Base",in:NegativeDevelopParameters.defaults)
        calibration = good.locking("Endpoints",in:calibration)
        calibration["autoBalance"] = 1
        let roll = RollBaseline(folder:root,calibration:calibration,confidence:0.9,
            frames:[try RollFrame(url:url,included:true,densityShift:0)])
        let effective = try #require(roll.parameters(for:url,node:["autoBase":1,"autoEndpoints":1,"autoBalance":1]))
        #expect(effective["autoBase"]==0 && effective["autoEndpoints"]==0)
        #expect(effective["autoBalance"]==1)
        #expect(roll.statistics?.offset.w==0)
        var frame = NegativeMeteringResult()
        frame.offset = SIMD4(0.1,0,-0.1,0.75)
        let displayed = try #require(roll.displayStatistics(frame:frame))
        #expect(displayed.offset==frame.offset)
        #expect(displayed.base.x==good.base.x)
    }
}
