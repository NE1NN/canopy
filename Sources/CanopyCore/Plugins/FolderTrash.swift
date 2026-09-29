import Foundation

/// Where a removed plugin row's folder goes. Agents may have left notes there, so it is never deleted outright.
public protocol FolderTrash: Sendable {
    /// Moves the folder away and returns where it went.
    func trash(_ folder: URL) throws -> URL?
}

/// The user's Trash, as Finder's Move to Trash does it.
public struct SystemTrash: FolderTrash {
    public init() {}

    public func trash(_ folder: URL) throws -> URL? {
        var result: NSURL?
        try FileManager.default.trashItem(at: folder, resultingItemURL: &result)
        return result as URL?
    }
}

/// Moves folders into a folder of its own instead of the Trash, so tests and dev builds on a throwaway home never touch
/// the user's.
public struct FolderMovingTrash: FolderTrash {
    public let folder: String

    public init(into folder: String) {
        self.folder = folder
    }

    public func trash(_ url: URL) throws -> URL? {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let destination = URL(fileURLWithPath: folder).appending(path: "\(url.lastPathComponent)-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }
}
