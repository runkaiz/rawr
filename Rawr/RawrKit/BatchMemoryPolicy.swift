import Foundation
import Metal
import ImageIO

enum BatchMemoryPolicy {
    /// Reserve at least half of the recommended GPU working set for the editor,
    /// decode/CI caches and other applications; never start more than two frames.
    static func workers(pixels: UInt64, recommendedBytes: UInt64, physicalBytes: UInt64) -> Int {
        let budget = min(recommendedBytes / 2, physicalBytes / 3)
        // Conservative RGB32 input/output + IR, dust intermediates, rendering,
        // decoder storage, and metering. At least 256 MiB of fixed overhead.
        let frame = pixels * 96 + 256 * 1024 * 1024
        return max(1, min(2, Int(budget / max(1, frame))))
    }

    static func workerCount(urls: [URL], graph: NodeGraph, device: MTLDevice) -> Int {
        var maximum: UInt64 = 0
        for url in urls {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let w = props[kCGImagePropertyPixelWidth] as? NSNumber,
                  let h = props[kCGImagePropertyPixelHeight] as? NSNumber else { return 1 }
            // RAW containers can report embedded preview sizes; fail conservative.
            if ImageDecoder.rawExtensions.contains(url.pathExtension.lowercased()) { return 1 }
            guard w.uint64Value > 0, h.uint64Value > 0,
                  w.uint64Value <= 16384, h.uint64Value <= 16384 else { return 1 }
            maximum = max(maximum, w.uint64Value * h.uint64Value)
        }
        // Additional full-resolution graph branches/effects increase live memory.
        let effects = graph.nodes.filter { $0.type != .imageInput && $0.type != .folderInput && $0.type != .preview }.count
        let adjusted = maximum * UInt64(max(1, effects)) / 2
        return workers(pixels: max(maximum, adjusted), recommendedBytes: device.recommendedMaxWorkingSetSize,
            physicalBytes: ProcessInfo.processInfo.physicalMemory)
    }
}
