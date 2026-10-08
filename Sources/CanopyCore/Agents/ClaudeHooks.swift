import Foundation

/// Canopy's hooks in a Claude Code settings file, which run `canopy agent-hook` from Canopy's terminals.
public enum ClaudeHooks {
    /// Runs the CLI of the Canopy that owns the terminal, and nothing outside Canopy. It never fails, so nothing shows
    /// in Claude's transcript.
    public static let command = #"[ -z "$CANOPY_CLI" ] || "$CANOPY_CLI" agent-hook >/dev/null 2>&1 || true"#

    /// What `canopy hooks` says when run through a host's relay. The host's settings file is out of this Mac's reach,
    /// and `host add` installs the hooks there.
    public static func keptByHostAdd(on host: String) -> String {
        "Canopy's hooks on \(host) are kept by `canopy host add`."
    }

    public enum Status: String, Codable, Sendable {
        case installed
        /// Some of Canopy's hooks are missing or differ, as after an older Canopy installed them.
        case outdated
        case notInstalled = "not_installed"
    }

    enum Timing {
        /// Claude goes on without waiting.
        case background
        /// Claude waits, so the report arrives before a `claude -p` exits. The timeout only caps a hang.
        case inline
        /// Like inline, with no timeout of its own, so Claude Code keeps its short budget for `SessionEnd` hooks.
        case end
    }

    struct Entry {
        let event: String
        let matcher: String?
        let timing: Timing
    }

    static let entries = [
        Entry(event: "SessionStart", matcher: nil, timing: .background),
        Entry(event: "UserPromptSubmit", matcher: nil, timing: .background),
        Entry(event: "PreToolUse", matcher: "AskUserQuestion|ExitPlanMode", timing: .background),
        Entry(event: "PermissionRequest", matcher: nil, timing: .background),
        Entry(event: "PostToolUse", matcher: nil, timing: .background),
        Entry(event: "PostToolUseFailure", matcher: nil, timing: .background),
        Entry(
            event: "Notification",
            matcher: "permission_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input",
            timing: .background),
        Entry(event: "Elicitation", matcher: nil, timing: .background),
        Entry(event: "ElicitationResult", matcher: nil, timing: .background),
        Entry(event: "Stop", matcher: nil, timing: .inline),
        Entry(event: "StopFailure", matcher: nil, timing: .inline),
        Entry(event: "SessionEnd", matcher: nil, timing: .end),
    ]

    static func handler(_ timing: Timing) -> OrderedJSON {
        var members = [OrderedJSON.Member("type", .string("command")), .init("command", .string(command))]
        switch timing {
        case .background: members.append(.init("async", .bool(true)))
        case .inline: members.append(.init("timeout", .number("5")))
        case .end: break
        }
        return .object(members)
    }

    static func group(_ entry: Entry) -> OrderedJSON {
        var group = OrderedJSON.object([])
        if let matcher = entry.matcher {
            group["matcher"] = .string(matcher)
        }
        group["hooks"] = .array([handler(entry.timing)])
        return group
    }

    /// A handler that runs `canopy agent-hook`, from this Canopy or an older one.
    static func isCanopy(_ handler: OrderedJSON) -> Bool {
        guard case .string(let command) = handler["command"] else { return false }
        return command.contains("CANOPY_CLI") && command.contains("agent-hook")
    }

    public static func status(of settings: OrderedJSON) -> Status {
        let groups = canopyGroups(in: settings)
        if groups.isEmpty { return .notInstalled }
        let wanted = entries.map { (event: $0.event, group: group($0)) }
        let matches =
            groups.count == wanted.count
            && wanted.allSatisfy { entry in groups.contains { $0.event == entry.event && $0.group == entry.group } }
        return matches ? .installed : .outdated
    }

    /// Adds Canopy's hooks after replacing any that differ. Settings that already have them come back unchanged.
    public static func installing(into settings: OrderedJSON) -> OrderedJSON {
        guard status(of: settings) != .installed else { return settings }
        var settings = uninstalling(from: settings)
        var hooks = settings["hooks"] ?? .object([])
        for entry in entries {
            var groups: [OrderedJSON] = []
            if case .array(let existing) = hooks[entry.event] { groups = existing }
            hooks[entry.event] = .array(groups + [group(entry)])
        }
        settings["hooks"] = hooks
        return settings
    }

    /// Removes every Canopy handler, then the matcher groups, events, and `hooks` key that removing them emptied.
    public static func uninstalling(from settings: OrderedJSON) -> OrderedJSON {
        guard case .object(let events) = settings["hooks"] else { return settings }
        var kept: [OrderedJSON.Member] = []
        var removedAny = false
        for event in events {
            guard case .array(let groups) = event.value else {
                kept.append(event)
                continue
            }
            var keptGroups: [OrderedJSON] = []
            for group in groups {
                guard case .array(let handlers) = group["hooks"], handlers.contains(where: isCanopy) else {
                    keptGroups.append(group)
                    continue
                }
                removedAny = true
                let rest = handlers.filter { !isCanopy($0) }
                if !rest.isEmpty {
                    var group = group
                    group["hooks"] = .array(rest)
                    keptGroups.append(group)
                }
            }
            if !keptGroups.isEmpty || groups.isEmpty {
                kept.append(.init(event.key, .array(keptGroups)))
            }
        }
        guard removedAny else { return settings }
        var settings = settings
        settings["hooks"] = kept.isEmpty ? nil : .object(kept)
        return settings
    }

    /// Every matcher group holding a Canopy handler, with its event.
    static func canopyGroups(in settings: OrderedJSON) -> [(event: String, group: OrderedJSON)] {
        guard case .object(let events) = settings["hooks"] else { return [] }
        return events.flatMap { event -> [(event: String, group: OrderedJSON)] in
            guard case .array(let groups) = event.value else { return [] }
            return groups.compactMap { group in
                guard case .array(let handlers) = group["hooks"], handlers.contains(where: isCanopy) else {
                    return nil
                }
                return (event.key, group)
            }
        }
    }
}

extension OrderedJSON {
    /// The settings, if they have the shape Claude Code reads: an object, whose `hooks` is an object of events, each
    /// an array of matcher groups holding an array of handlers.
    public func validSettings() throws -> OrderedJSON {
        func invalid(_ reason: String) -> OrderedJSONError {
            OrderedJSONError(offset: 0, reason: reason)
        }
        guard case .object = self else { throw invalid("The settings are not a JSON object") }
        guard let hooks = self["hooks"] else { return self }
        guard case .object(let events) = hooks else { throw invalid("\"hooks\" is not an object") }
        for event in events {
            guard case .array(let groups) = event.value else { throw invalid("\"\(event.key)\" is not an array") }
            for group in groups {
                guard case .object = group else { throw invalid("A \"\(event.key)\" hook is not an object") }
                if let handlers = group["hooks"], case .array = handlers {
                    continue
                } else if group["hooks"] != nil {
                    throw invalid("A \"\(event.key)\" group's \"hooks\" is not an array")
                }
            }
        }
        return self
    }
}

/// Claude Code's user settings file, where Canopy's hooks go.
public struct ClaudeSettingsFile: Sendable {
    /// The file as named. It may be a symbolic link.
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// `explicit` when given, else `settings.json` in Claude Code's config folder, which is where Claude Code looks.
    public static func resolve(explicit: String?, environment: [String: String], homeDirectory: String)
        -> ClaudeSettingsFile
    {
        if let explicit, !explicit.isEmpty {
            return ClaudeSettingsFile(url: URL(fileURLWithPath: NSString(string: explicit).expandingTildeInPath))
        }
        return ClaudeSettingsFile(
            url: configFolder(environment: environment, homeDirectory: homeDirectory).appending(path: "settings.json"))
    }

    /// `CLAUDE_CONFIG_DIR`, else `~/.claude`.
    public static func configFolder(environment: [String: String], homeDirectory: String) -> URL {
        if let folder = environment["CLAUDE_CONFIG_DIR"], !folder.isEmpty {
            return URL(fileURLWithPath: NSString(string: folder).expandingTildeInPath)
        }
        return URL(fileURLWithPath: homeDirectory).appending(path: ".claude")
    }

    /// The settings, or an empty object when the file does not exist yet.
    public func read() throws -> OrderedJSON {
        try settingsErrors { try file.read() }
    }

    public func status() throws -> ClaudeHooks.Status {
        ClaudeHooks.status(of: try read())
    }

    public func disablesAllHooks() throws -> Bool {
        try read()["disableAllHooks"] == .bool(true)
    }

    /// Returns whether the file changed.
    @discardableResult
    public func install() throws -> Bool {
        try update { ClaudeHooks.installing(into: $0) }
    }

    /// Returns whether the file changed.
    @discardableResult
    public func uninstall() throws -> Bool {
        try update { ClaudeHooks.uninstalling(from: $0) }
    }

    /// Rewrites the file with `transform`'s result, unless it changed nothing. A file changed by someone else while
    /// this ran is read again and transformed again. Returns whether the file changed.
    @discardableResult
    public func update(_ transform: (OrderedJSON) throws -> OrderedJSON) throws -> Bool {
        try settingsErrors { try file.update(transform) }
    }

    private var file: JSONFile {
        JSONFile(url: url, validate: { try $0.validSettings() }, newFileMode: 0o644)
    }

    private func settingsErrors<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch JSONFileError.unreadable(let reason) {
            throw WorkspaceError.settingsInvalid(url.path, reason: reason)
        } catch JSONFileError.writeFailed(let reason) {
            throw WorkspaceError.settingsWriteFailed(url.path, reason: reason)
        }
    }
}

/// Whether Canopy offers to install its hooks on launch: once, to people who use Claude Code, while the hooks are not
/// installed and the settings can be read.
public enum ClaudeHooksOffer {
    public static func shouldOffer(alreadyOffered: Bool, settings: ClaudeSettingsFile, configFolder: URL) -> Bool {
        guard !alreadyOffered, FileManager.default.fileExists(atPath: configFolder.path),
            let status = try? settings.status()
        else { return false }
        return status != .installed
    }
}
