import CanopyCore
import Foundation

/// A temporary folder that is deleted when the value is released. Paths are canonical.
final class TempDir: Sendable {
    let path: String

    init() throws {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "canopy-tickets-\(UUID().uuidString.prefix(8))")
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

/// Polls until `condition` holds or the timeout passes, and returns whether it held. The condition runs on the caller's
/// actor, so main-actor tests can read main-actor state.
func eventually(
    timeout: Duration = .seconds(20),
    isolation: isolated (any Actor)? = #isolation,
    _ condition: () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

/// ticket-manager's own response fixtures, copied into this target's resources.
enum APIFixture {
    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/canopy-api")
        else { throw CocoaError(.fileNoSuchFile) }
        return try Data(contentsOf: url)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try JSONDecoder().decode(type, from: data(name))
    }
}

/// The code the control API answers with for `error`.
func errorCode(_ error: any Error) -> String? {
    switch error {
    case let error as ControlError: error.code
    case let error as WorkspaceError: error.code
    default: nil
    }
}
