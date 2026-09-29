import Foundation

@testable import CanopyCore

/// Moves folders into a test's own folder, so tests never touch the user's Trash.
struct MovingTrash: FolderTrash {
    let folder: String

    init(into folder: String) {
        self.folder = folder
    }

    func trash(_ url: URL) throws -> URL? {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let destination = URL(fileURLWithPath: folder).appending(path: "\(url.lastPathComponent)-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }
}
