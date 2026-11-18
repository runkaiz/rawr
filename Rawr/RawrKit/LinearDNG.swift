import Foundation
import CoreImage

/// A narrow, checked adapter for uncompressed four-plane LinearRaw DNGs.
/// ReductionMatrix1 maps *all four* camera channels into three dimensions;
/// the same reduction is applied to ColorMatrix1. Apple then performs the
/// ordinary DNG colour conversion, white balance, crop and orientation.
/// No stored sample is interpreted as display alpha or inferred infrared.
enum LinearDNG {
    enum LayoutError: LocalizedError {
        case unsupported, corrupt
        var errorDescription: String? {
            switch self {
            case .unsupported: return "Unsupported four-plane DNG calibration or storage. Export a calibrated three-channel linear DNG/TIFF; no alpha or infrared has been inferred."
            case .corrupt: return "The four-plane DNG contains invalid tags, levels, calibration or pixel data."
            }
        }
    }

    private struct Tag {
        let type: Int
        let count: Int
        let bytes: Data
    }

    static func filter(url: URL) throws -> CIRAWFilter? {
        guard url.pathExtension.lowercased() == "dng" else { return nil }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let repaired = try threePlaneData(data) else { return nil }
        guard let filter = CIRAWFilter(imageData: repaired, identifierHint: "com.adobe.raw-image") else {
            throw LayoutError.unsupported
        }
        return filter
    }

    static func threePlaneData(_ data: Data) throws -> Data? {
        guard data.count >= 8 else { return nil }
        let little = data[0] == 73 && data[1] == 73
        guard little || (data[0] == 77 && data[1] == 77) else { return nil }
        func integer(_ bytes: Data, _ offset: Int, _ size: Int) throws -> Int {
            guard offset >= 0, size > 0, offset <= bytes.count - size else { throw LayoutError.corrupt }
            var v: UInt64 = 0
            for k in 0..<size { v |= UInt64(bytes[offset+k]) << (8 * (little ? k : size-k-1)) }
            guard v <= UInt64(Int.max) else { throw LayoutError.corrupt }
            return Int(v)
        }
        guard try integer(data, 2, 2) == 42 else { return nil }
        var pending = [try integer(data, 4, 4)], seen = Set<Int>(), directories = [[Int: Tag]]()
        while let offset = pending.popLast(), offset != 0 {
            guard seen.insert(offset).inserted, seen.count <= 64 else { throw LayoutError.corrupt }
            let count = try integer(data, offset, 2)
            guard count <= 4096 else { throw LayoutError.corrupt }
            var tags = [Int: Tag]()
            for i in 0..<count {
                let e = offset + 2 + i*12
                let tag = try integer(data,e,2), type = try integer(data,e+2,2), n = try integer(data,e+4,4)
                let size = [1:1,2:1,3:2,4:4,5:8,7:1,9:4,10:8,11:4,12:8][type]
                guard let size, n <= 1_000_000 else { throw LayoutError.corrupt }
                let length = n*size, start = length <= 4 ? e+8 : try integer(data,e+8,4)
                guard start <= data.count-length else { throw LayoutError.corrupt }
                tags[tag] = Tag(type:type,count:n,bytes:Data(data[start..<start+length]))
            }
            directories.append(tags)
            let next = try integer(data,offset+2+count*12,4)
            if next != 0 { pending.append(next) }
            if let sub = tags[330], sub.type == 4 {
                for i in 0..<sub.count { pending.append(try integer(sub.bytes,i*4,4)) }
            }
        }
        func values(_ tag: Tag?) throws -> [Double] {
            guard let tag else { return [] }
            return try (0..<tag.count).map { i in
                switch tag.type {
                case 1,3,4: return Double(try integer(tag.bytes,i*(tag.type == 3 ? 2 : tag.type == 4 ? 4 : 1),tag.type == 3 ? 2 : tag.type == 4 ? 4 : 1))
                case 5,10:
                    let a = try integer(tag.bytes,i*8,4), b = try integer(tag.bytes,i*8+4,4)
                    let numerator = tag.type == 10 ? Double(Int32(bitPattern:UInt32(a))) : Double(a)
                    let denominator = tag.type == 10 ? Double(Int32(bitPattern:UInt32(b))) : Double(b)
                    guard denominator != 0 else { throw LayoutError.corrupt }
                    return numerator/denominator
                default: throw LayoutError.unsupported
                }
            }
        }
        // The sensor may be a SubIFD; never repair the thumbnail instead.
        let candidates = try directories.filter { try values($0[277]) == [4] && values($0[262]) == [34892] }
        guard let raw = try candidates.max(by: { a,b in
            (try values(a[256]).first ?? 0)*(try values(a[257]).first ?? 0) <
                (try values(b[256]).first ?? 0)*(try values(b[257]).first ?? 0)
        }) else { return nil }
        let common = directories[0].merging(raw) { _, sensor in sensor }
        let w = Int(try values(raw[256]).first ?? 0), h = Int(try values(raw[257]).first ?? 0)
        try ImageDecoder.validateDimensions(width:Double(w),height:Double(h))
        let bits = try values(raw[258]), compression = try values(raw[259])
        let planar = try values(raw[284]), sampleFormat = try values(raw[339])
        guard bits == [16,16,16,16], compression == [1],
              planar.isEmpty || planar == [1],
              sampleFormat.allSatisfy({ $0 == 1 }), raw[338] == nil,
              common[50722] == nil, common[50723] == nil, common[50724] == nil,
              common[50727] == nil, common[50964] == nil, common[50965] == nil,
              common[51008] == nil, common[51009] == nil, common[51022] == nil else { throw LayoutError.unsupported }
        let color = try values(common[50721]), reduction = try values(common[50725])
        guard color.count == 12, reduction.count == 12 else { throw LayoutError.unsupported }
        var reducedColor = [Double](repeating:0,count:9)
        for r in 0..<3 { for c in 0..<3 { for k in 0..<4 {
            reducedColor[r*3+c] += reduction[r*4+k]*color[k*3+c]
        } } }
        let determinant = reducedColor[0]*(reducedColor[4]*reducedColor[8]-reducedColor[5]*reducedColor[7]) -
            reducedColor[1]*(reducedColor[3]*reducedColor[8]-reducedColor[5]*reducedColor[6]) +
            reducedColor[2]*(reducedColor[3]*reducedColor[7]-reducedColor[4]*reducedColor[6])
        guard determinant.isFinite, abs(determinant)>1e-8 else { throw LayoutError.corrupt }
        let black = try values(raw[50714]), white = try values(raw[50717])
        guard [0,1,4].contains(black.count), [0,1,4].contains(white.count),
              raw[50715] == nil, raw[50716] == nil, raw[50712] == nil else { throw LayoutError.unsupported }
        let blacks = (0..<4).map { black.isEmpty ? 0 : black[min($0,black.count-1)] }
        let whites = (0..<4).map { white.isEmpty ? 65535 : white[min($0,white.count-1)] }
        guard zip(blacks,whites).allSatisfy({ $0 >= 0 && $1 <= 65535 && $1 > $0 }) else { throw LayoutError.corrupt }
        let rows = Int(try values(raw[278]).first ?? 0)
        let offsets = try values(raw[273]).map(Int.init), lengths = try values(raw[279]).map(Int.init)
        guard rows > 0, offsets.count == (h+rows-1)/rows, lengths.count == offsets.count else { throw LayoutError.unsupported }
        for s in offsets.indices {
            let required = min(rows,h-s*rows)*w*8
            guard lengths[s] >= required, offsets[s] <= data.count-required else { throw LayoutError.corrupt }
        }
        var pixels = Data(count:w*h*6)
        var clipped = false
        data.withUnsafeBytes { source in pixels.withUnsafeMutableBytes { (dest: UnsafeMutableRawBufferPointer) in
            let input = source.bindMemory(to:UInt8.self), output = dest.bindMemory(to:UInt16.self)
            for y in 0..<h { for x in 0..<w {
                let start = offsets[y/rows]+((y%rows)*w+x)*8
                var samples = SIMD4<Double>()
                for k in 0..<4 {
                    let a = UInt16(input[start+k*2]), b = UInt16(input[start+k*2+1])
                    let value = Double(little ? a | b<<8 : a<<8 | b)
                    samples[k] = max(0,(value-blacks[k])/(whites[k]-blacks[k]))
                }
                for r in 0..<3 {
                    var value = 0.0
                    for k in 0..<4 { value += reduction[r*4+k]*samples[k] }
                    if !value.isFinite || value < -0.001 || value > 1.001 { clipped = true }
                    output[(y*w+x)*3+r] = UInt16(max(0,min(65535,(value*65535).rounded()))).littleEndian
                }
            } }
        } }
        guard !clipped else { throw LayoutError.unsupported }
        // Write a self-contained three-plane LinearRaw DNG, retaining only tags
        // whose semantics survive dimensionality reduction.
        func encoded(_ values: [Int], size: Int) -> Data {
            Data(values.flatMap { v in (0..<size).map { UInt8(truncatingIfNeeded:v >> ($0*8)) } })
        }
        var tags: [Int:Tag] = [:]
        func add(_ tag:Int,_ type:Int,_ count:Int,_ bytes:Data) { tags[tag] = Tag(type:type,count:count,bytes:bytes) }
        func short(_ tag:Int,_ v:[Int]) { add(tag,3,v.count,encoded(v,size:2)) }
        func long(_ tag:Int,_ v:[Int]) { add(tag,4,v.count,encoded(v,size:4)) }
        long(254,[0]); long(256,[w]); long(257,[h]); short(258,[16,16,16]); short(259,[1]); short(262,[34892])
        long(273,[0]); short(277,[3]); long(278,[h]); long(279,[pixels.count]); short(284,[1])
        add(50706,1,4,Data([1,4,0,0])); add(50707,1,4,Data([1,1,0,0]))
        let model = Data("Rawr Reduced LinearRaw\0".utf8); add(50708,2,model.count,model)
        add(50721,10,9,encoded(reducedColor.flatMap { [Int(($0*1_000_000).rounded()),1_000_000] },size:4))
        long(50717,[65535])
        // Rational tags from the original must be rewritten in little endian.
        for tag in [274,50718,50719,50720,50729,50778] {
            guard let original = common[tag] else { continue }
            let unit = original.type == 3 ? 2 : 4
            guard [3,4,5].contains(original.type) else { throw LayoutError.unsupported }
            let v = try stride(from:0,to:original.bytes.count,by:unit).map { try integer(original.bytes,$0,unit) }
            add(tag,original.type,original.count,encoded(v,size:unit))
        }
        if common[50729] == nil, let neutral = common[50728] {
            let v = try values(neutral)
            guard v.count == 4 else { throw LayoutError.corrupt }
            var n = [Double](repeating:0,count:3)
            for r in 0..<3 { for k in 0..<4 { n[r] += reduction[r*4+k]*v[k] } }
            guard n.allSatisfy({ $0 > 0 }) else { throw LayoutError.corrupt }
            add(50728,5,3,encoded(n.flatMap { [Int(($0*1_000_000).rounded()),1_000_000] },size:4))
        }
        var result = Data([73,73,42,0,8,0,0,0])
        result.append(encoded([tags.count],size:2))
        let sorted = tags.keys.sorted(), auxiliaryStart = 8+2+tags.count*12+4
        var auxiliary = Data()
        for tag in sorted {
            let t = tags[tag]!
            result.append(encoded([tag,t.type],size:2)); result.append(encoded([t.count],size:4))
            if t.bytes.count <= 4 { result.append(t.bytes); result.append(Data(count:4-t.bytes.count)) }
            else { result.append(encoded([auxiliaryStart+auxiliary.count],size:4)); auxiliary.append(t.bytes) }
        }
        result.append(Data(count:4)); result.append(auxiliary)
        let location = 8+2+sorted.firstIndex(of:273)!*12+8
        result.replaceSubrange(location..<location+4,with:encoded([result.count],size:4))
        result.append(pixels)
        return result
    }
}
