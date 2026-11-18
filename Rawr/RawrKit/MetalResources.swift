import Foundation
import Metal

/// A lease must live until every encoded use has completed. ImageData retains
/// output leases; callers using its textures must retain the ImageData as well.
final class TextureLease {
    let texture: MTLTexture
    private let recycle: (MTLTexture) -> Void
    init(_ texture: MTLTexture, recycle: @escaping (MTLTexture) -> Void) {
        self.texture = texture
        self.recycle = recycle
    }
    deinit { recycle(texture) }
}

final class BufferLease {
    let buffer: MTLBuffer
    private let recycle: (MTLBuffer) -> Void
    init(_ buffer: MTLBuffer, recycle: @escaping (MTLBuffer) -> Void) {
        self.buffer = buffer
        self.recycle = recycle
    }
    deinit { recycle(buffer) }
}

/// Shared by independent batch sessions, with an explicit bound on idle storage.
/// Live leases are never handed out twice. No heap aliasing or purgeable storage
/// is used, so resource reuse cannot invalidate an in-flight frame.
final class MetalResources {
    private struct TextureKey: Hashable {
        let format: UInt
        let width: Int
        let height: Int
    }
    private struct BufferKey: Hashable {
        let length: Int
        let options: UInt
    }
    let device: MTLDevice
    let library: MTLLibrary?
    let idleByteLimit: Int
    private let lock = NSLock()
    private var pipelines: [String: MTLComputePipelineState] = [:]
    private var textures: [TextureKey: [MTLTexture]] = [:]
    private var buffers: [BufferKey: [MTLBuffer]] = [:]
    private var idleBytes = 0
    private(set) var textureAllocations = 0
    private(set) var bufferAllocations = 0

    init(device: MTLDevice, idleByteLimit: Int? = nil) {
        self.device = device
        self.library = try? device.makeDefaultLibrary(bundle: Bundle(for: RawrKit.self))
        self.idleByteLimit = idleByteLimit ?? min(512 * 1024 * 1024, Int(device.recommendedMaxWorkingSetSize / 4))
    }

    func pipeline(_ name: String) -> MTLComputePipelineState? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = pipelines[name] { return cached }
        guard let function = library?.makeFunction(name: name),
              let pipeline = try? device.makeComputePipelineState(function: function) else { return nil }
        pipelines[name] = pipeline
        return pipeline
    }

    func texture(format: MTLPixelFormat, width: Int, height: Int) -> TextureLease? {
        let key = TextureKey(format: format.rawValue, width: width, height: height)
        lock.lock()
        var texture = textures[key]?.popLast()
        if let texture { idleBytes -= texture.allocatedSize }
        if texture == nil {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            descriptor.storageMode = .private
            descriptor.usage = [.shaderRead, .shaderWrite]
            texture = device.makeTexture(descriptor: descriptor)
            if texture != nil { textureAllocations += 1 }
        }
        lock.unlock()
        guard let texture else { return nil }
        return TextureLease(texture) { [weak self] in self?.recycle($0, key: key) }
    }

    func buffer(length: Int, options: MTLResourceOptions = .storageModePrivate) -> BufferLease? {
        let key = BufferKey(length: length, options: options.rawValue)
        lock.lock()
        var buffer = buffers[key]?.popLast()
        if let buffer { idleBytes -= buffer.allocatedSize }
        if buffer == nil {
            buffer = device.makeBuffer(length: length, options: options)
            if buffer != nil { bufferAllocations += 1 }
        }
        lock.unlock()
        guard let buffer else { return nil }
        return BufferLease(buffer) { [weak self] in self?.recycle($0, key: key) }
    }

    private func recycle(_ texture: MTLTexture, key: TextureKey) {
        lock.lock()
        defer { lock.unlock() }
        guard idleBytes + texture.allocatedSize <= idleByteLimit else { return }
        textures[key, default: []].append(texture)
        idleBytes += texture.allocatedSize
    }

    private func recycle(_ buffer: MTLBuffer, key: BufferKey) {
        lock.lock()
        defer { lock.unlock() }
        guard idleBytes + buffer.allocatedSize <= idleByteLimit else { return }
        buffers[key, default: []].append(buffer)
        idleBytes += buffer.allocatedSize
    }

    func trim() {
        lock.lock()
        defer { lock.unlock() }
        textures.removeAll()
        buffers.removeAll()
        idleBytes = 0
    }
}
