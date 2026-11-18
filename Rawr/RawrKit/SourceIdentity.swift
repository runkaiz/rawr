import Foundation

/// File replacement must invalidate cached GPU data even when the URL is stable.
struct SourceIdentity: Equatable {
    let url: URL
    let modified: Date?
    let size: UInt64?
    let inode: UInt64?

    init(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        self.url = url.standardizedFileURL
        modified = attributes[.modificationDate] as? Date
        size = (attributes[.size] as? NSNumber)?.uint64Value
        inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
    }
}
