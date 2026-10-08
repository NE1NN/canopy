import ArgumentParser
import CanopyCore
import Foundation

struct HooksCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hooks",
        abstract: "Add or remove the Claude Code hooks that tell Canopy what Claude is doing.",
        discussion: """
            The hooks go in Claude Code's user settings, ~/.claude/settings.json, or settings.json in \
            $CLAUDE_CONFIG_DIR. Other hooks there stay as they are.
            """,
        subcommands: [Install.self, Uninstall.self, Status.self]
    )

    struct Options: ParsableArguments {
        @Option(help: "The settings file to change instead of Claude Code's own.")
        var settings: String?
        @OptionGroup var output: OutputOptions

        var file: ClaudeSettingsFile {
            ClaudeSettingsFile.resolve(
                explicit: settings.map(Client.absolutePath), environment: ProcessInfo.processInfo.environment,
                homeDirectory: NSHomeDirectory())
        }

        /// Runs `work`, then prints the file's state, or the error. Through a host's relay it only says that
        /// `host add` keeps the host's hooks, and returns nil.
        func report(_ work: (ClaudeSettingsFile) throws -> String) -> ClaudeHooks.Status? {
            let client = Client(json: output.json)
            if let host = RelayRun.host(in: ProcessInfo.processInfo.environment) {
                let message = ClaudeHooks.keptByHostAdd(on: host)
                try? client.print(.object(["host": .string(host), "message": .string(message)])) { message }
                return nil
            }
            let file = self.file
            do {
                let message = try work(file)
                let status = try file.status()
                if try file.disablesAllHooks() {
                    FileHandle.standardError.write(
                        Data("warning: \(file.url.path) sets disableAllHooks, so Claude Code runs no hooks.\n".utf8))
                }
                try client.print(.object(["settings": .string(file.url.path), "state": .string(status.rawValue)])) {
                    message
                }
                return status
            } catch let error as WorkspaceError {
                client.fail(ControlError(error))
            } catch {
                client.fail(ControlError(code: "internal", message: "\(error)"))
            }
        }
    }

    struct Install: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Add Canopy's hooks, or bring older ones up to date.")

        @OptionGroup var options: Options

        func run() {
            _ = options.report { file in
                try file.install()
                    ? "Added Canopy's hooks to \(file.url.path)."
                    : "Canopy's hooks are already in \(file.url.path)."
            }
        }
    }

    struct Uninstall: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove Canopy's hooks, and only those.")

        @OptionGroup var options: Options

        func run() {
            _ = options.report { file in
                try file.uninstall()
                    ? "Removed Canopy's hooks from \(file.url.path)."
                    : "\(file.url.path) has no Canopy hooks."
            }
        }
    }

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Say whether Canopy's hooks are installed. Exits 1 unless they are.")

        @OptionGroup var options: Options

        func run() throws {
            let status = options.report { file in
                switch try file.status() {
                case .installed: "Installed: Canopy's hooks are in \(file.url.path)."
                case .outdated:
                    "Outdated: some of Canopy's hooks in \(file.url.path) are missing or old. Run `canopy hooks install`."
                case .notInstalled: "Not installed: \(file.url.path) has no Canopy hooks. Run `canopy hooks install`."
                }
            }
            if let status, status != .installed { throw ExitCode(1) }
        }
    }
}

/// What Claude Code's hooks run. It never prints, and always exits 0, so it can never disturb Claude.
struct AgentHookCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agent-hook", abstract: "Report Claude Code's state to Canopy, for its hooks.",
        shouldDisplay: false)

    func run() {
        guard isatty(STDIN_FILENO) == 0, let input = try? FileHandle.standardInput.readToEnd(),
            let hook = AgentHook.request(
                input: input, environment: ProcessInfo.processInfo.environment,
                startedAt: ProcessTable.startTime(of: getpid()))
        else { return }
        try? ControlClient(socketPath: hook.socketPath).post(hook.request)
    }
}
