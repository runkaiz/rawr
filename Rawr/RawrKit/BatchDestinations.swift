import Foundation
import Darwin

/// Deterministic, case-insensitive reservations, including files already on disk.
enum BatchDestinations {
    /// Install in one filesystem operation without replacing a late-arriving file.
    /// The temporary file lives beside the destination, so no cross-volume move is needed.
    static func install(temporary: URL, destination: URL) throws {
        guard renamex_np(temporary.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    static func plan(inputs: [URL], folder: URL, extension fileExtension: String) throws -> [URL] {
        var reserved = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path).map { $0.lowercased() })
        return inputs.map { input in
            let stem = input.deletingPathExtension().lastPathComponent + "_processed"
            var name = "\(stem).\(fileExtension)"
            var suffix = 2
            while reserved.contains(name.lowercased()) {
                name = "\(stem)_\(suffix).\(fileExtension)"
                suffix += 1
            }
            reserved.insert(name.lowercased())
            return folder.appendingPathComponent(name)
        }
    }
}
