import Foundation

/// Deterministic, case-insensitive reservations, including files already on disk.
enum BatchDestinations {
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
