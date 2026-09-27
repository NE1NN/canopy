import Foundation

/// Commands a repo commits in `.canopy/config.json` to prepare a new row and to clean one up.
public struct RepoConfig: Codable, Sendable, Equatable {
    public static let relativePath = ".canopy/config.json"

    public var setup: [String]
    public var teardown: [String]

    public init(setup: [String] = [], teardown: [String] = []) {
        self.setup = setup
        self.teardown = teardown
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        setup = try container.decodeIfPresent([String].self, forKey: .setup) ?? []
        teardown = try container.decodeIfPresent([String].self, forKey: .teardown) ?? []
    }

    /// Reads the row's own checkout, so each branch runs the commands it commits. No file means nothing to run.
    public static func load(from folder: String) throws -> RepoConfig {
        let path = (folder as NSString).appendingPathComponent(relativePath)
        guard let data = FileManager.default.contents(atPath: path) else { return RepoConfig() }
        do {
            return try JSONDecoder().decode(RepoConfig.self, from: data)
        } catch {
            throw WorkspaceError.badConfig(path, reason: reason(error))
        }
    }

    static func reason(_ error: any Error) -> String {
        switch error as? DecodingError {
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .keyNotFound(_, let context),
            .dataCorrupted(let context):
            let field = context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
            return field.isEmpty ? context.debugDescription : "\(field): \(context.debugDescription)"
        default:
            return "\(error)"
        }
    }
}
