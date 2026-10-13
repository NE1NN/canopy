import CanopyAgents
import CanopyGit
import CanopySystem
import CanopyWire
import Foundation

/// A Canopy home on a host: its rows, its panes in tmux, and their agents. The one source of truth for them, for the
/// Mac and the phone alike. Everything it changes, it saves at once and tells its subscribers about.
public actor BoxDaemon {
    public let paths: BoxPaths
    let tmux: Tmux
    let git: @Sendable (String) -> GitClone

    var config: BoxConfig?
    /// The key the Mac set for phones to start the box with, kept in `wake.json`.
    public private(set) var wakeKey: BoxWakeKey?
    var instanceLearning: Task<Void, Never>?
    var state = BoxState()
    /// Each repo's clone, its main row on the host, by repo name.
    var mainRows: [String: StoredRow] = [:]
    var activity: [String: PaneActivity] = [:]
    /// Rows being made or removed, by clone, so two in one clone never race.
    var cloneQueues: [String: Task<Void, Never>] = [:]
    /// The fetch each clone last made, so rows made together share one.
    var lastFetch: [String: (finishedAt: ContinuousClock.Instant, failure: String?)] = [:]
    /// Panes and rows being made, which a listing taken meanwhile neither takes in nor drops.
    var makingPanes: Set<String> = []
    var phonesConnected = false
    var makingRows: Set<String> = []
    /// What `wait` calls are waiting on, woken on each agent change or pane end.
    var waiters: [UUID: @Sendable () -> Void] = [:]

    private var observers: [UUID: AsyncStream<BoxSnapshot>.Continuation] = [:]
    /// How many follow the snapshots, as phones' inboxes and replies waiting to be taken do.
    var observerCount: Int { observers.count }
    private var publishing: Task<Void, Never>?
    private var lastPublished: ContinuousClock.Instant?

    /// Subscribers hear of changes at most this often, each time with everything.
    static let publishEvery = Duration.milliseconds(100)

    /// `git` gives git in a folder; tests pass one with a known environment.
    public init(paths: BoxPaths, tmux: Tmux, git: @escaping @Sendable (String) -> GitClone) {
        self.paths = paths
        self.tmux = tmux
        self.git = git
    }

    public var isConfigured: Bool { config != nil }
    public var nextPane: Int { state.nextPane }

    /// Loads what was saved, brings it in line with git and tmux, and saves the result.
    public func start() async {
        config = Self.load(BoxConfig.self, from: paths.configFile)
        wakeKey = Self.load(BoxWakeKey.self, from: paths.wakeFile)
        state = Self.load(BoxState.self, from: paths.stateFile) ?? BoxState()
        await reconcile()
        save()
        publish()
    }

    /// Saves what the Mac decides and brings the rows in line with its repos. The wake key goes in a file of its own.
    public func configure(_ next: BoxConfig) async throws {
        var settings = next
        settings.wake = nil
        settings.keepsWake = nil
        try BoxFiles.write(try JSONEncoder.box.encode(settings), to: paths.configFile)
        if next.keepsWake != true {
            if let wake = next.wake {
                try BoxFiles.write(try JSONEncoder.box.encode(wake), to: paths.wakeFile)
            } else {
                unlink(paths.wakeFile)
            }
            wakeKey = next.wake
        }
        config = settings
        if wakeKey != nil { Task { await learnInstance() } }
        state.released = false
        await reconcile()
        changed()
    }

    public func snapshot() -> BoxSnapshot {
        BoxSnapshot(rows: allRows.map(boxRow), panes: state.panes.map(boxPane))
    }

    /// The snapshot at once, then a new one after each change, at most every `publishEvery`.
    public func changes() -> AsyncStream<BoxSnapshot> {
        let (stream, continuation) = AsyncStream.makeStream(of: BoxSnapshot.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.forget(id) }
        }
        continuation.yield(snapshot())
        return stream
    }

    /// Every row: each repo's clone first, by repo name, then the others in the order they came.
    var allRows: [StoredRow] {
        mainRows.sorted { $0.key < $1.key }.map(\.value) + state.rows
    }

    func row(_ path: String) -> StoredRow? {
        allRows.first { $0.path == path }
    }

    func isMain(_ path: String) -> Bool {
        mainRows.values.contains { $0.path == path }
    }

    /// The row whose folder holds `folder`, the deepest when rows nest.
    func row(holding folder: String) -> StoredRow? {
        allRows.filter { Paths.isInside(folder, $0.path) }.max { $0.path.count < $1.path.count }
    }

    func boxRow(_ row: StoredRow) -> BoxRow {
        BoxRow(
            path: row.path, repo: row.repo, branch: row.branch, head: row.head, isMain: isMain(row.path),
            missing: row.missing, pr: state.prs[row.path])
    }

    func boxPane(_ pane: StoredPane) -> BoxPane {
        let activity = activity[pane.id] ?? PaneActivity()
        return BoxPane(
            id: pane.id, rowPath: pane.rowPath, folder: pane.folder, foreground: activity.foreground,
            title: activity.title, busy: activity.busy, agent: pane.agent.state, unseen: pane.agent.unseen,
            backgroundTasks: pane.agent.backgroundTasks, transcriptPath: pane.agent.transcriptPath,
            prompt: pane.agent.prompt, since: pane.agent.since.timeIntervalSince1970, lastLine: activity.lastLine)
    }

    /// Saves the state and tells subscribers, after anything changes.
    func changed() {
        save()
        publish()
    }

    /// Tells subscribers without saving, for what is never saved, such as a pane's title.
    func publish() {
        guard publishing == nil else { return }
        let wait = lastPublished.map { Self.publishEvery - (ContinuousClock.now - $0) } ?? .zero
        publishing = Task {
            if wait > .zero { try? await Task.sleep(for: wait) }
            self.sendSnapshot()
        }
    }

    private func sendSnapshot() {
        publishing = nil
        lastPublished = .now
        let current = snapshot()
        for observer in observers.values { observer.yield(current) }
    }

    private func forget(_ id: UUID) {
        observers[id] = nil
    }

    func save() {
        guard let data = try? JSONEncoder.box.encode(state) else { return }
        try? BoxFiles.write(data, to: paths.stateFile)
    }

    /// A file's JSON, or nil when it is missing or cannot be read, as a damaged file is.
    static func load<T: Decodable>(_ type: T.Type, from path: String) -> T? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

extension JSONEncoder {
    static var box: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
