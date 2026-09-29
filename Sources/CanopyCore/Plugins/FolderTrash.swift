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
