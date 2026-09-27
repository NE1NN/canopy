import Foundation

@testable import CanopyCore

/// A temporary folder that is deleted when the value is released. Paths are canonical.
final class TempDir: Sendable {
    let path: String

    init() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "canopy-tests-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        path = Paths.canonical(url.path)
    }

    func sub(_ name: String) -> String {
        path + "/" + name
    }

    deinit {
        try? FileManager.default.removeItem(atPath: path)
    }
}
