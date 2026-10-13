import ArgumentParser
import CanopyAgents
import CanopySystem
import CanopyWire
import Foundation

/// The box's `canopy`: what a pane on the box runs, sent by the host's relay. The box answers hooks and the row and term
/// commands about its own rows and panes, with the Mac CLI's options and output, and passes everything else to the
/// Mac.
public enum BoxCommands {
    /// The reply for a call: the box's own, or the Mac's.
    public static func answer(_ request: RelayRequest, on daemon: BoxDaemon) async -> RelayReply {
        if let local = await run(request, on: daemon) { return local }
        return await MacRelay.forward(request, appSocket: daemon.paths.appSocket)
    }

    /// The box's reply, or nil for a call the Mac answers: a command the box does not have, a row or pane that is not
    /// the box's, an option only the Mac can carry out, or a request for help.
    public static func run(_ request: RelayRequest, on daemon: BoxDaemon) async -> RelayReply? {
        if RelayInput.reading(request.args) == .hookReport {
            // A hook never prints and never fails, so it can never disturb Claude, and it never leaves the box.
            if let pane = request.env["CANOPY_PANE"], let input = request.input {
                let startedAt = Date() - max(request.age ?? 0, 0)
                await daemon.hook(pane: pane, input: input, startedAt: startedAt)
            }
            return RelayReply(stdout: Data(), stderr: Data(), status: 0)
        }
        guard let parsed = try? Root.parseAsRoot(request.args), let command = parsed as? any BoxCommand else {
            return nil
        }
        let context = Context(
            request: request, daemon: daemon, host: await daemon.config?.host, snapshot: await daemon.snapshot())
        return await command.run(context)
    }

    /// What `row new --json` prints on the box.
    public struct RowNewOutput: Codable, Sendable, Equatable {
        public var row: BoxRow
        public var source: BranchSource
        public var base: String?
        public var notes: [String]
        public var warnings: [String]
        /// The pane `--run` opened.
        public var pane: String?
    }

    /// What `row rm --json` prints on the box.
    struct RowRemoveOutput: Codable, Sendable {
        var row: BoxRow
        var warnings: [String]
    }

    struct Context: Sendable {
        let request: RelayRequest
        let daemon: BoxDaemon
        let host: String?
        let snapshot: BoxSnapshot

        var folder: String { Paths.canonical(request.cwd) }

        /// A path as the relay's folder reads it.
        func absolute(_ path: String) -> String {
            Paths.canonical(path.hasPrefix("/") ? path : request.cwd + "/" + path)
        }

        func repo(named name: String) -> String? {
            snapshot.rows.map(\.repo).first { $0.caseInsensitiveCompare(name) == .orderedSame }
        }

        /// The box row a `--repo`, `--row`, or row argument names: a path, or a branch.
        func row(_ name: String, repo: String?) -> BoxRow? {
            if name.hasPrefix("/") || name.hasPrefix(".")
                || name.contains("/")
                    && FileManager.default.fileExists(
                        atPath: absolute(name))
            {
                let path = absolute(name)
                if let row = snapshot.rows.first(where: { $0.path == path }) { return row }
            }
            let named = snapshot.rows.filter { $0.branch == name && (repo == nil || $0.repo == repo) }
            return named.count == 1 ? named.first : nil
        }

        /// The row this call runs in: CANOPY_ROW_PATH, or the relay's folder.
        var currentRow: BoxRow? {
            if let path = request.env["CANOPY_ROW_PATH"], let row = snapshot.rows.first(where: { $0.path == path }) {
                return row
            }
            return snapshot.rows.filter { Paths.isInside(folder, $0.path) }.max { $0.path.count < $1.path.count }
        }

        func pane(_ id: String) -> BoxPane? {
            snapshot.panes.first { $0.id == id }
        }

        /// Whether `--on` names this box, or nothing.
        func isHere(_ on: String?) -> Bool {
            on == nil || on == host
        }
    }

    /// Output as the Mac CLI prints it: `--json` prints the result, or an error object, and a failure always ends
    /// with `error: <message>` on standard error and status 1.
    struct Printer {
        var json: Bool

        func success(_ result: some Encodable, human: () -> String, warnings: [String] = []) -> RelayReply {
            let errors = warnings.map { "warning: \($0)\n" }.joined()
            let text = json ? (Self.pretty(result) ?? "") : human()
            return RelayReply(stdout: Data((text + "\n").utf8), stderr: Data(errors.utf8), status: 0)
        }

        func failure(_ error: any Error) -> RelayReply {
            let control = error as? ControlError ?? ControlError(code: "internal", message: "\(error)")
            let out = json ? (Self.pretty(["error": control]).map { $0 + "\n" } ?? "") : ""
            return RelayReply(
                stdout: Data(out.utf8), stderr: Data("error: \(control.message)\n".utf8), status: 1)
        }

        static func pretty(_ value: some Encodable) -> String? {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) }
        }
    }

    static func displayName(_ row: BoxRow) -> String {
        row.branch ?? (row.path as NSString).lastPathComponent
    }

    /// Left-aligned columns separated by two spaces, as the Mac CLI's tables.
    static func table(_ header: [String], _ rows: [[String]]) -> String {
        let all = [header] + rows
        let widths = header.indices.map { column in all.map { $0[column].count }.max() ?? 0 }
        return all.map { cells in
            cells.enumerated().map { index, cell in
                index == cells.count - 1 ? cell : cell.padding(toLength: widths[index], withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
        }.joined(separator: "\n")
    }
}

protocol BoxCommand: ParsableCommand {
    /// The reply, or nil for the Mac to answer.
    func run(_ context: BoxCommands.Context) async -> RelayReply?
}

struct OutputFlag: ParsableArguments {
    @Flag var json = false
}

struct Root: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "canopy", subcommands: [Row.self, Term.self])
}

struct Row: ParsableCommand {
    static let configuration = CommandConfiguration(subcommands: [List.self, New.self, Remove.self])

    struct List: BoxCommand {
        @Option var repo: String?
        @Flag var all = false
        @OptionGroup var output: OutputFlag

        func run(_ context: BoxCommands.Context) async -> RelayReply? {
            var rows = context.snapshot.rows
            if let repo {
                guard let name = context.repo(named: repo) else { return nil }
                rows = rows.filter { $0.repo == name }
            }
            return BoxCommands.Printer(json: output.json).success(rows) {
                BoxCommands.table(
                    ["BRANCH", "GROUP", "CLASS", "PATH"],
                    rows.map { [BoxCommands.displayName($0), "-", $0.isMain ? "main" : "canopy", $0.path] })
            }
        }
    }

    struct New: BoxCommand {
        static let configuration = CommandConfiguration(commandName: "new")

        @Argument var branch: String?
        @Option var pr: String?
        @Option(name: .customLong("branch")) var localBranch: String?
        @Option var repo: String?
        @Option(name: .customLong("from")) var base: String?
        @Flag var existing = false
        @Option(name: .customLong("run")) var command: String?
        @Flag(name: .customLong("no-setup")) var noSetup = false
        @Flag var select = false
        @Option var group: String?
        @Flag(name: .customLong("no-link")) var noLink = false
        @Option var ticket: String?
        @Option(name: .customLong("on")) var on: String?
        @OptionGroup var output: OutputFlag

        func run(_ context: BoxCommands.Context) async -> RelayReply? {
            // Pull requests, tickets, groups, and the window are the Mac's.
            guard context.isHere(on), let branch, pr == nil, localBranch == nil, ticket == nil, group == nil,
                !select, let repo = repoName(context)
            else { return nil }
            if existing, base != nil {
                return BoxCommands.Printer(json: output.json).failure(
                    ControlError(
                        code: "bad_params",
                        message: "--from only applies to new branches, and --existing never creates one."))
            }
            let printer = BoxCommands.Printer(json: output.json)
            do {
                let made = try await context.daemon.rowNew(
                    BoxRowNewParams(repo: repo, branch: branch, base: base, existing: existing))
                var notes = made.notes
                if FileManager.default.fileExists(atPath: made.row.path + "/.canopy/config.json") {
                    notes.append(
                        "Rows on a host do not run the branch's setup commands, so run them in the row if it needs them."
                    )
                }
                var pane: String?
                if let command {
                    pane = try await context.daemon.paneNew(BoxPaneNewParams(rowPath: made.row.path, command: command))
                }
                let result = BoxCommands.RowNewOutput(
                    row: made.row, source: made.source, base: made.base, notes: notes, warnings: made.warnings,
                    pane: pane)
                return printer.success(result, human: { summary(result) }, warnings: made.warnings)
            } catch {
                return printer.failure(error)
            }
        }

        private func repoName(_ context: BoxCommands.Context) -> String? {
            if let repo {
                if let name = context.repo(named: repo) { return name }
                return context.snapshot.rows.first { $0.path == context.absolute(repo) }?.repo
            }
            if let name = context.request.env["CANOPY_REPO"].flatMap(context.repo(named:)) { return name }
            return context.currentRow?.repo
        }

        private func summary(_ made: BoxCommands.RowNewOutput) -> String {
            let name = BoxCommands.displayName(made.row)
            var lines: [String]
            switch made.source {
            case .local: lines = ["Checked out \(name) in \(made.row.path)."]
            case .origin: lines = ["Checked out \(name), tracking origin/\(name), in \(made.row.path)."]
            case .new: lines = ["Created new branch \(name) from \(made.base ?? "HEAD") in \(made.row.path)."]
            }
            lines += made.notes
            if let pane = made.pane, let command { lines.append("Running \(command) in \(pane).") }
            return lines.joined(separator: "\n")
        }
    }

    struct Remove: BoxCommand {
        static let configuration = CommandConfiguration(commandName: "rm")

        @Argument var row: String?
        @Option var repo: String?
        @Flag var force = false
        @Flag var deleteBranch = false
        @OptionGroup var output: OutputFlag

        func run(_ context: BoxCommands.Context) async -> RelayReply? {
            let repoName = repo.flatMap(context.repo(named:))
            if repo != nil, repoName == nil { return nil }
            guard let target = row.map({ context.row($0, repo: repoName) }) ?? context.currentRow else { return nil }
            let printer = BoxCommands.Printer(json: output.json)
            do {
                let warnings = try await context.daemon.rowRemove(
                    BoxRowRemoveParams(path: target.path, force: force, deleteBranch: deleteBranch))
                return printer.success(
                    BoxCommands.RowRemoveOutput(row: target, warnings: warnings),
                    human: { "Removed \(BoxCommands.displayName(target))." }, warnings: warnings)
            } catch {
                return printer.failure(error)
            }
        }
    }
}

struct Term: ParsableCommand {
    static let configuration = CommandConfiguration(subcommands: [List.self, Send.self, Read.self, Wait.self])

    struct List: BoxCommand {
        @Option var repo: String?
        @Option var row: String?
        @Flag var all = false
        @OptionGroup var output: OutputFlag

        func run(_ context: BoxCommands.Context) async -> RelayReply? {
            var panes = context.snapshot.panes
            if !all {
                let repoName = repo.flatMap(context.repo(named:))
                if repo != nil, repoName == nil { return nil }
                let target: BoxRow? =
                    if let row { context.row(row, repo: repoName) } else { context.currentRow }
                guard let target else { return nil }
                panes = panes.filter { $0.rowPath == target.path }
            }
            let infos = panes.map { pane in
                let row = context.snapshot.rows.first { $0.path == pane.rowPath }
                return TermInfo(
                    pane: pane.id, repo: row?.repo, plugin: nil, row: row.map(BoxCommands.displayName) ?? pane.rowPath,
                    rowPath: pane.rowPath, tab: "-", title: pane.title ?? "", folder: pane.folder,
                    foreground: pane.foreground, exited: nil, agent: pane.agent == .none ? nil : pane.agent,
                    backgroundTasks: pane.backgroundTasks.isEmpty ? nil : pane.backgroundTasks)
            }
            return BoxCommands.Printer(json: output.json).success(infos) {
                BoxCommands.table(
                    ["ID", "ROW", "TAB", "PROCESS", "AGENT", "TITLE", "FOLDER"],
                    infos.map {
                        [$0.pane, $0.row, $0.tab, $0.foreground ?? "", $0.agent?.rawValue ?? "", $0.title, $0.folder]
                    })
            }
        }
    }

    struct Send: BoxCommand {
        @Argument var id: String
        @Argument var text: String
        @Flag var enter = false
        @OptionGroup var output: OutputFlag

        func run(_ context: BoxCommands.Context) async -> RelayReply? {
            guard context.pane(id) != nil else { return nil }
            let printer = BoxCommands.Printer(json: output.json)
            do {
                try await context.daemon.send(pane: id, text: text, enter: enter)
                return printer.success(["pane": id]) { "Sent to \(id)." }
            } catch {
                return printer.failure(error)
            }
        }
    }

    struct Read: BoxCommand {
        @Argument var id: String
        @Option var lines: Int?
        @OptionGroup var output: OutputFlag

        func run(_ context: BoxCommands.Context) async -> RelayReply? {
            guard context.pane(id) != nil else { return nil }
            let printer = BoxCommands.Printer(json: output.json)
            if let lines, lines < 1 {
                return printer.failure(ControlError(code: "bad_params", message: "--lines must be at least 1."))
            }
            do {
                let text = try await context.daemon.read(pane: id, lines: lines)
                return printer.success(TermReadResult(text: text)) { text }
            } catch {
                return printer.failure(error)
            }
        }
    }

    struct Wait: BoxCommand {
        @Argument var ids: [String] = []
        @Option(name: .customLong("for")) var target = "any"
        @Option var timeout = "30m"
        @OptionGroup var output: OutputFlag

        func run(_ context: BoxCommands.Context) async -> RelayReply? {
            guard !ids.isEmpty, ids.allSatisfy({ context.pane($0) != nil }) else { return nil }
            let printer = BoxCommands.Printer(json: output.json)
            guard let wanted = AgentWaitTarget(rawValue: target) else {
                return printer.failure(
                    ControlError(code: "bad_params", message: "--for takes done, waiting, background, any, or ended."))
            }
            guard let seconds = TimeSpan.seconds(timeout) else {
                return printer.failure(
                    ControlError(code: "bad_params", message: "--timeout takes a span such as 90s or 30m."))
            }
            do {
                let reached = try await context.daemon.wait(panes: ids, for: wanted, timeout: .seconds(seconds))
                return printer.success(TermWaitResult(pane: reached.pane, state: reached.state)) {
                    "\(reached.pane) \(reached.state.rawValue)"
                }
            } catch {
                return printer.failure(error)
            }
        }
    }
}
