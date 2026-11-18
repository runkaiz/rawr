import Foundation
import Metal

/// Opt-in instrumentation. GPU durations come from completed command buffers;
/// wall durations include scheduling and CPU work and must not be added to GPU time.
final class PipelineTrace {
    struct Event: Codable {
        let stage: String
        let wallSeconds: Double
        let gpuSeconds: Double?
        let allocatedBytes: Int
    }
    private let lock = NSLock()
    private var storage: [Event] = []
    var enabled = false

    func record(_ stage: String, since start: Double, device: MTLDevice, command: MTLCommandBuffer? = nil) {
        guard enabled else { return }
        let gpu = command.flatMap { $0.gpuEndTime > $0.gpuStartTime ? $0.gpuEndTime - $0.gpuStartTime : nil }
        let event = Event(stage: stage, wallSeconds: ProcessInfo.processInfo.systemUptime - start,
            gpuSeconds: gpu, allocatedBytes: device.currentAllocatedSize)
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    func drain() -> [Event] {
        lock.lock()
        defer { lock.unlock() }
        let events = storage
        storage.removeAll(keepingCapacity: true)
        return events
    }
}
