import Foundation

public enum StateLoadResult: Sendable, Equatable {
    case fresh(AppState)
    case loaded(AppState)
    case recovered(AppState, backup: URL)

    public var state: AppState {
        switch self {
        case .fresh(let state), .loaded(let state), .recovered(let state, _): state
        }
    }
}

public struct StateStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load(now: Date = Date()) -> StateLoadResult {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .fresh(AppState())
        }
        if let data = try? Data(contentsOf: url),
            let state = try? JSONDecoder().decode(AppState.self, from: data),
            state.version <= AppState.currentVersion
        {
            return .loaded(state)
        }
        let backup = url.deletingLastPathComponent()
            .appending(path: "\(url.lastPathComponent).broken-\(Int(now.timeIntervalSince1970))")
        try? FileManager.default.moveItem(at: url, to: backup)
        return .recovered(AppState(), backup: backup)
    }

    public func save(_ state: AppState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(state).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
