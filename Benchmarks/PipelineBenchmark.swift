import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Darwin

/// Generated fixtures contain no private photographs. Invoke the binary directly;
/// this has no NSApplication, SwiftUI scene, window, or keychain access.
@main
struct PipelineBenchmark {
    struct Sample: Codable {
        let scenario: String
        let seconds: Double
        let events: [PipelineTrace.Event]
        let peakRSSBytes: Int
        let metalBytes: Int
        let batchWorkers: Int?
    }
    struct Report: Codable {
        var schema = 1
        let device: String
        let recommendedWorkingSetBytes: UInt64
        let physicalMemoryBytes: UInt64
        let os: String
        let width: Int
        let height: Int
        let frames: Int
        let samples: [Sample]
    }

    @MainActor
    static func main() async throws {
        let args = CommandLine.arguments
        func value(_ flag: String, _ fallback: String) -> String {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return fallback }
            return args[i + 1]
        }
        let width = Int(value("--width", "6000")) ?? 6000
        let height = Int(value("--height", "4000")) ?? 4000
        let frames = Int(value("--frames", "36")) ?? 36
        let iterations = Int(value("--iterations", "5")) ?? 5
        guard width > 0, height > 0, width * height <= 128_000_000,
              frames > 0, frames <= 4096, iterations > 0 else { throw CocoaError(.validationMissingMandatoryProperty) }
        let output = URL(fileURLWithPath: value("--output", "benchmark.json"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawr-benchmark-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let inputs = root.appendingPathComponent("inputs")
        let exports = root.appendingPathComponent("exports")
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        let kit = RawrKit()
        guard let context = kit.processingContext else { throw CocoaError(.featureUnsupported) }
        let fixture = inputs.appendingPathComponent("frame-000.tiff")
        let ir = root.appendingPathComponent("infrared.tiff")
        try writeFixture(fixture, width: width, height: height, infrared: false, context: context)
        try writeFixture(ir, width: width, height: height, infrared: true, context: context)
        for index in 1..<frames {
            try FileManager.default.linkItem(at: fixture, to: inputs.appendingPathComponent(String(format: "frame-%03d.tiff", index)))
        }
        context.trace.enabled = true
        var samples: [Sample] = []
        func measure(_ name: String, _ body: () async -> Bool) async throws {
            _ = context.trace.drain()
            let start = ProcessInfo.processInfo.systemUptime
            guard await body() else {
                fputs("Benchmark failed: \(name)\n", stderr)
                for entry in kit.logs.suffix(20) { fputs(entry.message + "\n", stderr) }
                throw CocoaError(.coderInvalidValue)
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            let workerMessage = kit.logs.last { $0.message.hasPrefix("Batch workers:") }?.message
            let workerCount = workerMessage.flatMap { $0.split(separator: " ").dropFirst(2).first }.flatMap { Int($0) }
            samples.append(Sample(scenario: name, seconds: elapsed, events: context.trace.drain(),
                peakRSSBytes: Int(usage.ru_maxrss), metalBytes: context.device.currentAllocatedSize,
                batchWorkers: name == "roll-export" ? workerCount : nil))
            print("\(name): \(elapsed) seconds")
            fflush(stdout)
        }
        var single = graph(fixture, infrared: ir)
        try await measure("cold-preview") { await kit.executeGraph(single) }
        for index in 0..<iterations {
            single.nodes[2].parameters["exposure"] = Double(index + 1) * 0.1
            try await measure("slider-\(index)") { await kit.executeGraph(single) }
        }
        try await measure("single-export") {
            await kit.exportImage(single, to: exports.appendingPathComponent("single.tiff"))
        }
        try FileManager.default.removeItem(at: exports.appendingPathComponent("single.tiff"))
        let roll = graph(inputs, infrared: ir, folder: true)
        try await measure("roll-export") { await kit.exportFolderBatch(roll, to: exports) }
        // Roll calibration intentionally measures a direct, uncleaned source.
        var calibration = roll
        calibration.nodes.remove(at: 1)
        calibration.connections = [
            Connection(fromNodeId: calibration.nodes[0].id, fromOutput: "Image", toNodeId: calibration.nodes[1].id, toInput: "Input"),
            Connection(fromNodeId: calibration.nodes[1].id, fromOutput: "Output", toNodeId: calibration.nodes[2].id, toInput: "Input")
        ]
        if frames >= 3 {
            try await measure("roll-metering") {
                await kit.measureRoll(calibration, nodeID: calibration.nodes[1].id) != nil
            }
        }
        let report = Report(device: context.device.name,
            recommendedWorkingSetBytes: context.device.recommendedMaxWorkingSetSize,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory, os: ProcessInfo.processInfo.operatingSystemVersionString,
            width: width, height: height, frames: frames, samples: samples)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: output, options: .atomic)
    }

    static func graph(_ url: URL, infrared: URL, folder: Bool = false) -> NodeGraph {
        var input = NodeData(type: folder ? .folderInput : .imageInput, position: .zero)
        input.imageURL = url
        var dust = NodeData(type: .dustRemoval, position: .zero)
        dust.infraredURL = infrared
        let develop = NodeData(type: .negativeDevelop, position: .zero)
        let preview = NodeData(type: .preview, position: .zero)
        let nodes = [input, dust, develop, preview]
        return NodeGraph(nodes: nodes, connections: (1..<nodes.count).map { i in
            Connection(fromNodeId: nodes[i-1].id, fromOutput: i == 1 ? "Image" : "Output", toNodeId: nodes[i].id, toInput: "Input")
        })
    }

    static func writeFixture(_ url: URL, width: Int, height: Int, infrared: Bool, context: ProcessingContext) throws {
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CIColor {
            CIColor(red: r, green: g, blue: b, colorSpace: NegativeImageIO.colorSpace)!
        }
        let gradient = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: CGFloat(width), y: CGFloat(height)),
            "inputColor0": infrared ? color(0.65, 0.65, 0.65) : color(0.008, 0.004, 0.002),
            "inputColor1": infrared ? color(0.85, 0.85, 0.85) : color(0.72, 0.36, 0.18)
        ])!.outputImage!
        // A real base-estimation fixture needs a flat clear border. A gradient
        // touching every edge correctly fails the roll's confidence gate.
        let base = CIImage(color: infrared ? color(0.8, 0.8, 0.8) : color(0.8, 0.4, 0.2)).cropped(to: bounds)
        let interior = bounds.insetBy(dx: bounds.width * 0.05, dy: bounds.height * 0.05)
        let image = gradient.cropped(to: interior).composited(over: base)
        let cg = context.linearCIContext.createCGImage(image, from: image.extent, format: .RGBA16, colorSpace: NegativeImageIO.colorSpace)!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, cg, [kCGImagePropertyTIFFCompression: 1] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}
