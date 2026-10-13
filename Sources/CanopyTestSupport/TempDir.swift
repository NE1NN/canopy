import CanopySystem
import Foundation

/// A temporary folder that is deleted when the value is released. Paths are canonical.
public final class TempDir: Sendable {
    public let path: String

    public init() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "canopy-tests-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        path = Paths.canonical(url.path)
    }

    /// A folder in `parent`, such as /tmp, where Unix sockets inside it fit their path's length limit.
    public init(in parent: String) throws {
        let folder = parent + "/ct-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        path = Paths.canonical(folder)
    }

    public func sub(_ name: String) -> String {
        path + "/" + name
    }

    deinit {
        try? FileManager.default.removeItem(atPath: path)
    }
}
