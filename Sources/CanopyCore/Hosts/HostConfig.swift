import Foundation

/// A host from config.json's `hosts`, keyed by its ssh alias.
public struct HostEntry: Codable, Sendable, Equatable {
    public static let defaultIdleDetachMinutes = 30

    /// Registered repos' names, each to its clone's absolute path on the host.
    public var repos: [String: String]
    /// Run on this Mac with the login shell when the host cannot be reached, such as a command that starts it.
    public var wake: String?
    /// Panes detach after this many minutes with nothing running and nothing typed. 0 never detaches.
    public var idleDetachMinutes: Int
    /// canopy-box runs the host's rows, panes, and agents, since `canopy host upgrade`.
    public var box: Bool
    /// What a task from the phone runs there, set by `host add --agent` or `phone agent --on`. Nil for the standard one.
    public var agentCommand: String?

    public init(
        repos: [String: String] = [:], wake: String? = nil, idleDetachMinutes: Int = defaultIdleDetachMinutes,
        box: Bool = false, agentCommand: String? = nil
    ) {
        self.repos = repos
        self.wake = wake
        self.idleDetachMinutes = idleDetachMinutes
        self.box = box
        self.agentCommand = agentCommand
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        repos = try container.decode([String: String].self, forKey: .repos)
        wake = try container.decodeIfPresent(String.self, forKey: .wake)
        let minutes = try container.decodeIfPresent(Int.self, forKey: .idleDetachMinutes)
        idleDetachMinutes = minutes.map { $0 < 0 ? Self.defaultIdleDetachMinutes : $0 } ?? Self.defaultIdleDetachMinutes
        box = try container.decodeIfPresent(Bool.self, forKey: .box) ?? false
        agentCommand = try container.decodeIfPresent(String.self, forKey: .agentCommand)
    }

    /// The clone of a registered repo: the one saved under its name, or else under a name its path ends in, since
    /// display names grow a parent folder while two registered repos share a folder name.
    public func clonePath(repoName: String, repoPath: String) -> String? {
        repoKey(repoName: repoName, repoPath: repoPath).flatMap { repos[$0] }
    }

    /// The name the host knows a registered repo by, as `clonePath` finds it, which canopy-box names its rows by.
    public func repoKey(repoName: String, repoPath: String) -> String? {
        if repos[repoName] != nil { return repoName }
        return repos.keys.sorted().first { repoPath.hasSuffix("/" + $0) }
    }
}

/// Every host config.json names. A host whose section cannot be read is left out with a warning, and the rest load.
public struct HostsConfig: Sendable, Equatable {
    public var hosts: [String: HostEntry]
    public var warnings: [String]

    public init(hosts: [String: HostEntry] = [:], warnings: [String] = []) {
        self.hosts = hosts
        self.warnings = warnings
    }

    public static func load(from file: URL) -> HostsConfig {
        guard let data = try? Data(contentsOf: file),
            let json = try? JSONDecoder().decode(JSONValue.self, from: data),
            case .object(let top) = json, case .object(let sections)? = top["hosts"]
        else { return HostsConfig() }
        var config = HostsConfig()
        for (alias, section) in sections.sorted(by: { $0.key < $1.key }) {
            do {
                config.hosts[alias] = try section.decode(HostEntry.self)
            } catch {
                config.warnings.append("config.json's host \(alias) could not be read, so Canopy left it out: \(error)")
            }
        }
        return config
    }
}

/// config.json as `host add` and `host rm` write it: only the host's own section changes.
public struct HostsConfigFile: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func save(_ alias: String, _ entry: HostEntry) throws {
        try change { hosts in
            var section = OrderedJSON.object([])
            section["repos"] = OrderedJSON(.object(entry.repos.mapValues(JSONValue.string)))
            if let wake = entry.wake { section["wake"] = .string(wake) }
            section["idleDetachMinutes"] = .number(String(entry.idleDetachMinutes))
            section["box"] = entry.box ? .bool(true) : nil
            section["agentCommand"] = entry.agentCommand.map { .string($0) }
            hosts[alias] = section
        }
    }

    public func remove(_ alias: String) throws {
        try change { $0[alias] = nil }
    }

    private func change(_ edit: (inout OrderedJSON) -> Void) throws {
        try ConfigFile(url: url).change { json in
            var hosts = OrderedJSON.object([])
            if let existing = json["hosts"], case .object = existing { hosts = existing }
            edit(&hosts)
            json["hosts"] = hosts
        }
    }
}

/// config.json, changed in place: only what `edit` touches changes, and an unreadable file stays as it is.
struct ConfigFile: Sendable {
    let url: URL

    func change(_ edit: (inout OrderedJSON) -> Void) throws {
        do {
            try file.update { json in
                var json = json
                edit(&json)
                return json
            }
        } catch JSONFileError.unreadable(let reason) {
            throw WorkspaceError.configInvalid(url.path, reason: reason)
        } catch JSONFileError.writeFailed(let reason) {
            throw WorkspaceError.configWriteFailed(url.path, reason: reason)
        }
    }

    private var file: JSONFile {
        JSONFile(
            url: url,
            validate: { json in
                guard case .object = json else {
                    throw OrderedJSONError(offset: 0, reason: "The settings are not a JSON object")
                }
                return json
            }, newFileMode: 0o600)
    }
}
