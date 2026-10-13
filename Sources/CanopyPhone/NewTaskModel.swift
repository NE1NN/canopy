import CanopyWire
import Foundation
import Observation

/// New task: a row on a paired server, by `row new`'s rules, whose pane runs that server's agent command with a brief.
/// The phone picks the brief, never the program.
@MainActor @Observable
public final class NewTaskModel {
    /// A server Where offers.
    public struct Choice: Identifiable {
        public let server: ServerConnection
        /// Start can reach it: it is connected, or it is a box Start can wake.
        public var isAvailable: Bool
        /// A box out of reach with a wake key, which Start wakes before making the row.
        public var wakesFirst: Bool

        public var id: String { server.id }

        @MainActor public var status: String {
            if wakesFirst { return "Out of reach. Start wakes it first." }
            return server.isConnected ? "Connected" : "Can't reach \(server.name)"
        }
    }

    public enum Phase: Equatable, Sendable {
        case editing
        case waking
        case starting
    }

    public let servers: Servers
    private let rows: RowsModel
    private let waker: Waker
    private let defaults: UserDefaults
    static let lastServerKey = "newTask.lastServer"

    /// The server Where has chosen, by id.
    public var serverID: String?
    public var repo = ""
    public var branch = ""
    /// Where a new branch starts; empty for `row new`'s own choice.
    public var base = ""
    public var brief = ""
    public private(set) var phase = Phase.editing
    public private(set) var problem: PhoneProblem?
    /// The start under way from `begin`, which Cancel stops.
    private var starting: (id: UUID, task: Task<Void, Never>)?

    public init(servers: Servers, rows: RowsModel, waker: Waker, defaults: UserDefaults = .standard) {
        self.servers = servers
        self.rows = rows
        self.waker = waker
        self.defaults = defaults
    }

    /// Every paired server, the one last started on first.
    public var choices: [Choice] {
        let last = defaults.string(forKey: Self.lastServerKey)
        let paired = servers.paired
        return (paired.filter { $0.id == last } + paired.filter { $0.id != last }).map { server in
            let wakes = !server.isConnected && server.isBox && server.server.wake != nil
            return Choice(server: server, isAvailable: server.isConnected || wakes, wakesFirst: wakes)
        }
    }

    public var choice: Choice? { choices.first { $0.id == serverID } }

    /// The chosen server's repos, from Rows. Empty while they are not known, when the repo is typed.
    public var repos: [String] {
        rows.hosts.first { $0.id == serverID }?.sections.filter { !$0.isPlugin }.map(\.name) ?? []
    }

    /// What Start runs there, or nil from a server older than New task.
    public var agentCommand: String? { choice?.server.server.agentCommand }

    public var startTitle: String { choice?.wakesFirst == true ? "Wake and start" : "Start" }

    /// What Start is doing, or nil while the fields can be changed.
    public var progress: String? {
        let name = choice?.server.name ?? ""
        switch phase {
        case .waking: return "Waking \(name)…"
        case .starting: return "Making the row on \(name)…"
        case .editing: return nil
        }
    }

    public var canStart: Bool {
        phase == .editing && choice?.isAvailable == true && !Self.trimmed(repo).isEmpty
            && !Self.trimmed(branch).isEmpty
    }

    /// Readies the sheet: the last server used, or else the first that Start can reach, and its first repo.
    public func open() {
        problem = nil
        if choice?.isAvailable != true {
            serverID = (choices.first(where: \.isAvailable) ?? choices.first)?.id
        }
        chose()
        Task { await rows.refresh() }
    }

    /// Keeps the repo when the new server has one by that name, and otherwise takes its first.
    public func chose() {
        let repos = repos
        if !repos.isEmpty, !repos.contains(repo) { repo = repos[0] }
    }

    /// Starts the task, and hands `opened` the pane its agent runs in, unless `cancel` came first.
    public func begin(then opened: @escaping @MainActor (PaneRef) -> Void) {
        guard canStart, starting == nil else { return }
        let id = UUID()
        let task = Task {
            let pane = await start()
            let cancelled = Task.isCancelled
            if starting?.id == id { starting = nil }
            if let pane, !cancelled { opened(pane) }
        }
        starting = (id, task)
    }

    /// Stops waiting for a wake, and forgets a row being made: the server still makes it, and nothing opens.
    public func cancel() {
        starting?.task.cancel()
        starting = nil
    }

    /// Wakes a box that is off, makes the row there, and returns the pane its agent runs in, or nil with `problem`
    /// saying why. The fields stay as they were when it fails.
    public func start() async -> PaneRef? {
        guard canStart, let choice else { return nil }
        let server = choice.server
        problem = nil
        if choice.wakesFirst {
            phase = .waking
            if waker.isWaking(server) {
                await waitUntil { [waker] in !waker.isWaking(server) }
            } else {
                await waker.wake(server)
            }
            guard server.isConnected, !Task.isCancelled else {
                phase = .editing
                if case .failed(let failure) = waker.step(of: server) {
                    problem = failure
                } else {
                    problem = PhoneProblem(title: "\(server.name) did not wake.", detail: "Start the task again.")
                }
                return nil
            }
        }
        phase = .starting
        defer { phase = .editing }
        let params = PhoneNewRowParams(
            repo: Self.trimmed(repo), branch: Self.trimmed(branch),
            base: Self.trimmed(base).isEmpty ? nil : Self.trimmed(base), brief: brief)
        do {
            let made = try await server.liveClient().call(PhoneMethod.newRow, params, as: PhoneNewRowResult.self)
            defaults.set(server.id, forKey: Self.lastServerKey)
            branch = ""
            base = ""
            brief = ""
            return PaneRef(server: server.id, pane: made.pane)
        } catch let error as ControlError where error.code == "method_not_allowed" {
            problem = PhoneProblem(
                title: "Canopy on \(server.name) can't start tasks from the phone.",
                detail: "Update Canopy there, then start the task again.", code: error.code)
        } catch {
            problem = server.problem(error)
        }
        return nil
    }

    public func dismissProblem() {
        problem = nil
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
