import Foundation

/// Who made a change: the user in Canopy's window, an agent or script through `canopy`, or something outside Canopy.
public enum ActivitySource: String, Codable, Sendable {
    /// Canopy's window, including what is typed in its terminals.
    case ui
    /// A `canopy` command.
    case cli
    /// A change Canopy noticed rather than made, such as git run in any terminal, or a PR changing on GitHub.
    case git

    /// Who is acting now. The control API runs each request as `.cli`, and work a request starts inherits it.
    @TaskLocal public static var current = ActivitySource.ui
}

public enum ActivityType {
    public static let repoAdded = "repo.added"
    public static let repoRemoved = "repo.removed"
    public static let rowCreated = "row.created"
    public static let rowAdopted = "row.adopted"
    public static let rowRemoved = "row.removed"
    public static let rowBranchChanged = "row.branch_changed"
    public static let rowMoved = "row.moved"
    public static let groupCreated = "group.created"
    public static let groupRenamed = "group.renamed"
    public static let groupRemoved = "group.removed"
    public static let prOpened = "pr.opened"
    public static let prStateChanged = "pr.state_changed"
    public static let termOpened = "term.opened"
    public static let termExited = "term.exited"
    public static let termCommand = "term.command"
    public static let cliCall = "cli.call"
    public static let webOpened = "web.opened"
    public static let webClosed = "web.closed"
    public static let pluginEnabled = "plugin.enabled"
    public static let pluginDisabled = "plugin.disabled"
    public static let pluginRowCreated = "plugin.row.created"
    public static let pluginRowRemoved = "plugin.row.removed"

    /// `agent.working`, `agent.waiting`, and `agent.done`, or `agent.cleared` when the state goes to none.
    public static func agent(_ state: AgentState) -> String {
        state == .none ? "agent.cleared" : "agent.\(state.rawValue)"
    }
}

extension Calendar {
    /// Log files are named by local date in the Gregorian calendar, whatever calendar the user picked.
    static func localGregorian(in zone: TimeZone = .current) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }
}

/// One line of the activity log.
public struct ActivityEvent: Codable, Sendable, Equatable {
    /// Local time with milliseconds and the UTC offset, such as 2026-09-27T21:15:03.123+10:00.
    public var ts: String
    public var type: String
    public var repo: String?
    public var row: String?
    public var path: String?
    public var source: ActivitySource
    public var data: [String: JSONValue]

    public init(
        date: Date, type: String, repo: String? = nil, row: String? = nil, path: String? = nil,
        source: ActivitySource, data: [String: JSONValue] = [:]
    ) {
        self.ts = date.formatted(Self.timestamp(in: .current))
        self.type = type
        self.repo = repo
        self.row = row
        self.path = path
        self.source = source
        self.data = data
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ts = try container.decode(String.self, forKey: .ts)
        type = try container.decode(String.self, forKey: .type)
        repo = try container.decodeIfPresent(String.self, forKey: .repo)
        row = try container.decodeIfPresent(String.self, forKey: .row)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        source = try container.decode(ActivitySource.self, forKey: .source)
        data = try container.decodeIfPresent([String: JSONValue].self, forKey: .data) ?? [:]
    }

    public var date: Date? {
        try? Self.timestamp(in: .gmt).parse(ts)
    }

    /// How `ts` is written. Reading it back honors the offset it carries, whatever the zone here.
    static func timestamp(in zone: TimeZone) -> Date.ISO8601FormatStyle {
        Date.ISO8601FormatStyle(timeZoneSeparator: .colon, includingFractionalSeconds: true, timeZone: zone)
    }

    /// The event as one line of JSON, with its fields in a fixed order so the files read well.
    func jsonLine() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        func json(_ value: some Encodable) throws -> String {
            String(decoding: try encoder.encode(value), as: UTF8.self)
        }
        var fields = [("ts", try json(ts)), ("type", try json(type))]
        for (key, value) in [("repo", repo), ("row", row), ("path", path)] {
            if let value { fields.append((key, try json(value))) }
        }
        fields += [("source", try json(source)), ("data", try json(data))]
        return "{" + fields.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",") + "}"
    }
}
