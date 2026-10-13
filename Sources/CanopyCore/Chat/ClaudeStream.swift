import Foundation

/// A slash command or skill Claude Code offers, as `initialize` lists it.
public struct ClaudeCommand: Equatable, Sendable, Decodable {
    public var name: String
    public var description: String
    public var argumentHint: String

    public init(name: String, description: String, argumentHint: String) {
        self.name = name
        self.description = description
        self.argumentHint = argumentHint
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = (try? container.decodeIfPresent(String.self, forKey: .description)) ?? ""
        argumentHint = (try? container.decodeIfPresent(String.self, forKey: .argumentHint)) ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case name, description, argumentHint
    }
}

/// A model Claude Code offers, as `initialize` lists it.
public struct ClaudeModel: Equatable, Sendable, Decodable {
    public var value: String
    public var displayName: String

    public init(value: String, displayName: String) {
        self.value = value
        self.displayName = displayName
    }

    /// Claude Code's own aliases, offered before it has started.
    public static let aliases = [
        ClaudeModel(value: "opus", displayName: "Opus"), ClaudeModel(value: "sonnet", displayName: "Sonnet"),
        ClaudeModel(value: "haiku", displayName: "Haiku"),
    ]
}

public enum ClaudeStreamError: Error, Equatable, Sendable {
    case notRunning
    case timedOut
    case refused(String)
}

/// How a chat starts Claude Code: headless, speaking stream-json both ways, with permission prompts sent to Canopy.
public enum ClaudeLaunch {
    /// Without a model, Claude Code uses the one its settings name.
    public static func arguments(model: String?, mode: String, resume: String? = nil) -> [String] {
        var arguments = [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--include-partial-messages", "--replay-user-messages", "--permission-prompt-tool", "stdio",
            // Lets the mode chip switch to Bypass permissions later; it does not turn bypass on.
            "--allow-dangerously-skip-permissions",
        ]
        if let model { arguments += ["--model", model] }
        arguments += ["--permission-mode", mode]
        if let resume { arguments += ["--resume", resume] }
        return arguments
    }

    /// Claude Code as a chat pane starts it: through the author's login shell, with the environment a terminal pane
    /// gets, so its hooks report to the pane and every `canopy` command works, in the row's folder.
    public static func terminalLaunch(
        settings: ShellSettings, context: PaneContext, pane: PaneID, model: String?, mode: String, resume: String?
    ) -> TerminalLaunch {
        let environment = PaneEnvironment.build(settings: settings, context: context, pane: pane)
        let folder =
            FileManager.default.fileExists(atPath: context.rowPath)
            ? context.rowPath : settings.baseEnvironment["HOME"] ?? NSHomeDirectory()
        return settings.script(
            script(arguments: arguments(model: model, mode: mode, resume: resume), command: command(settings)),
            environment: environment, directory: folder)
    }

    /// The line a login shell runs, so `claude` is found on the author's PATH and replaces the shell. `command` stands
    /// in for `claude`, as fixtures' stand-in does.
    /// `claude`, or in a debug build the stand-in that UI fixtures, e2e runs, and tests name in CANOPY_CLAUDE.
    public static func command(_ settings: ShellSettings) -> String {
        #if DEBUG
            if let standIn = settings.baseEnvironment["CANOPY_CLAUDE"], !standIn.isEmpty {
                return SetupScript.quoted(standIn)
            }
        #endif
        return "claude"
    }

    public static func script(arguments: [String], command: String = "claude") -> String {
        (["exec " + command] + arguments.map(SetupScript.quoted)).joined(separator: " ")
    }
}

/// One `claude -p` process: lines in and out, and control requests matched to their answers.
@MainActor
public final class ClaudeStream {
    /// Every event, in order, on the main actor.
    public var onEvent: (ClaudeEvent) -> Void = { _ in }
    /// The exit code and the last lines of stderr.
    public var onExit: (Int32, [String]) -> Void = { _, _ in }
    public private(set) var commands: [ClaudeCommand] = []
    public private(set) var models: [ClaudeModel] = []
    public private(set) var isRunning = false

    private var process: PipeProcess?
    private var waiting: [String: CheckedContinuation<JSONValue?, any Error>] = [:]

    public init() {}

    public var pid: pid_t? { isRunning ? process?.pid : nil }

    public func start(_ launch: TerminalLaunch) throws {
        process = try PipeProcess(
            launch,
            onLines: { [weak self] lines in
                for line in lines { self?.received(line) }
            },
            onExit: { [weak self] code in self?.exited(code) })
        isRunning = true
        // Written before anything else, so it reaches Claude ahead of the first message.
        initializeRequest = "canopy-init-" + UUID().uuidString.prefix(8).lowercased()
        process?.write(ClaudeInput.request(id: initializeRequest!, kind: "initialize"))
    }

    private var initializeRequest: String?

    public func send(_ content: [ClaudeInput.Content]) {
        process?.write(ClaudeInput.user(content))
    }

    /// Sends an answer to one of Claude's requests, as `ClaudeInput.allow`, `deny`, or `refuse` make it.
    public func answer(_ line: Data) {
        process?.write(line)
    }

    /// Sends a control request and returns Claude's answer.
    @discardableResult
    public func request(_ kind: String, _ fields: [String: JSONValue] = [:], timeout: Duration = .seconds(10))
        async throws -> JSONValue?
    {
        try requireRunning()
        let id = "canopy-" + UUID().uuidString.prefix(8).lowercased()
        process?.write(ClaudeInput.request(id: id, kind: kind, fields))
        let timer = Task { [weak self] in
            try await Task.sleep(for: timeout)
            self?.resolve(id, with: .failure(ClaudeStreamError.timedOut))
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { waiting[id] = $0 }
    }

    func requireRunning() throws {
        guard isRunning else { throw ClaudeStreamError.notRunning }
    }

    /// Ends the process and whatever it started. Its exit is still reported.
    public func stop() {
        guard isRunning else { return }
        isRunning = false
        process?.terminate()
        failWaiting()
    }

    private func received(_ line: Data) {
        guard let event = ClaudeEvent(line: line) else { return }
        switch event {
        case .controlResponse(let id, _, let value) where id == initializeRequest:
            initializeRequest = nil
            if case .object(let fields)? = value, let list = fields["commands"],
                let commands = try? list.decode([ClaudeCommand].self)
            {
                self.commands = commands
            }
            if case .object(let fields)? = value, let list = fields["models"],
                let models = try? list.decode([ClaudeModel].self)
            {
                self.models = models
            }
            return
        case .controlResponse(let id, let error, let value):
            resolve(id, with: error.map { .failure(ClaudeStreamError.refused($0)) } ?? .success(value))
            return
        case .unknownRequest(let id, let kind):
            process?.write(ClaudeInput.refuse(request: id, error: "Canopy does not handle \(kind) requests"))
            return
        default:
            onEvent(event)
        }
    }

    private func resolve(_ id: String, with result: Result<JSONValue?, any Error>) {
        waiting.removeValue(forKey: id)?.resume(with: result)
    }

    private func failWaiting() {
        let pending = waiting
        waiting = [:]
        for continuation in pending.values {
            continuation.resume(throwing: ClaudeStreamError.notRunning)
        }
    }

    private func exited(_ code: Int32) {
        isRunning = false
        failWaiting()
        onExit(code, process?.errorTail() ?? [])
    }
}
