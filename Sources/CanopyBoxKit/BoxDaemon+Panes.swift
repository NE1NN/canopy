import CanopyAgents
import CanopySystem
import CanopyWire
import Foundation

extension BoxDaemon {
    /// How long Return waits after text, so a program such as Claude Code reads it as a keystroke of its own rather
    /// than as part of a paste, as on the Mac.
    static let returnPause = Duration.milliseconds(200)
    /// How far apart keys go, as the author would press them.
    static let keyPause = Duration.milliseconds(150)
    /// tmux titles a pane nothing has titled with the machine's name, which says nothing.
    static let machineNames: Set<String> = {
        let name = ProcessInfo.processInfo.hostName
        return [name, String(name.split(separator: ".").first ?? "")]
    }()

    /// Opens a pane in a row: a session of the home's tmux server named `b<N>`, in the row's folder, with the variables
    /// a remote pane gets, typing `command` once its shell is up.
    public func paneNew(_ params: BoxPaneNewParams) async throws -> String {
        guard let config else { throw BoxErrors.notConfigured() }
        let path = Paths.canonical(params.rowPath)
        guard let row = row(path) else { throw BoxErrors.rowNotFound(params.rowPath) }
        let id = "b\(state.nextPane)"
        state.nextPane += 1
        var environment = HostLayout.paneEnvironment(
            pane: id, rowName: row.branch ?? (row.path as NSString).lastPathComponent, repoName: row.repo,
            host: config.host, rowPath: row.path, clone: mainRows[row.repo]?.path ?? row.path, hostHome: paths.root,
            homeID: paths.homeID)
        environment["PATH"] = paths.bin + ":" + (tmux.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin")
        do {
            try await tmux.newSession(id, folder: row.path, environment: environment)
        } catch {
            changed()
            throw ControlError(code: "pane_failed", message: "\(error)")
        }
        state.panes.append(StoredPane(id: id, rowPath: row.path, folder: row.path, agent: PaneAgent()))
        changed()
        if let command = params.command {
            try await tmux.sendText(command, to: id)
            try await tmux.sendBytes(Data([0x0D]), to: id)
        }
        return id
    }

    /// Ends a pane's session and forgets the pane.
    public func paneClose(_ id: String) async throws {
        guard pane(id) != nil else { throw BoxErrors.paneNotFound(id) }
        await tmux.killSession(id)
        forgetPane(id)
    }

    /// Types text into a pane, then Return as a keystroke of its own, `returnPause` later.
    public func send(pane id: String, text: String, enter: Bool) async throws {
        guard pane(id) != nil else { throw BoxErrors.paneNotFound(id) }
        typed(Data(text.utf8), into: id)
        try await tmux.sendText(text, to: id)
        guard enter else { return }
        try await Task.sleep(for: Self.returnPause)
        try await tmux.sendBytes(Data([0x0D]), to: id)
        typed(Data([0x0D]), into: id)
    }

    /// Presses keys one at a time, each as the bytes a terminal sends for it.
    public func keys(_ params: BoxKeysParams) async throws {
        guard pane(params.pane) != nil else { throw BoxErrors.paneNotFound(params.pane) }
        for (index, key) in params.keys.enumerated() {
            if index > 0 { try await Task.sleep(for: Self.keyPause) }
            try await tmux.sendBytes(Data(key.utf8), to: params.pane)
            typed(Data(key.utf8), into: params.pane)
        }
    }

    /// The pane's screen, or its last `lines` lines with scrollback, as plain text.
    public func read(pane id: String, lines: Int?) async throws -> String {
        guard pane(id) != nil else { throw BoxErrors.paneNotFound(id) }
        do {
            return try await tmux.capture(id, lines: lines)
        } catch {
            throw BoxErrors.paneNotFound(id)
        }
    }

    /// Waits until one of the panes' agents reaches `target`, returning the first that does in the order given. A
    /// pane already there counts at once, unless something went into it since.
    public func wait(panes ids: [String], for target: AgentWaitTarget, timeout: Duration) async throws -> (
        pane: String, state: AgentState
    ) {
        for id in ids where pane(id) == nil { throw BoxErrors.paneNotFound(id) }
        for id in ids {
            guard let pane = pane(id) else { continue }
            let lastInput = Date(timeIntervalSince1970: pane.lastInput)
            if target.matches(pane.agent.state), pane.agent.isFresh(after: lastInput) { return (id, pane.agent.state) }
        }
        let startedAt = Dictionary(uniqueKeysWithValues: ids.compactMap { id in pane(id).map { (id, $0.agent.since) } })
        let (wakes, wake) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let waiter = UUID()
        waiters[waiter] = { wake.yield() }
        let timer = Task {
            try? await Task.sleep(for: timeout)
            wake.finish()
        }
        defer {
            waiters[waiter] = nil
            timer.cancel()
            wake.finish()
        }
        for await _ in wakes {
            for id in ids {
                guard let pane = pane(id) else {
                    throw ControlError(code: "pane_closed", message: "\(id) closed during the wait.")
                }
                guard pane.agent.since != startedAt[id] else { continue }
                if target.matches(pane.agent.state) { return (id, pane.agent.state) }
                if pane.agent.state == .none {
                    throw ControlError(
                        code: "agent_stopped",
                        message:
                            "The agent in \(id) stopped without finishing: it exited, was interrupted, or was set to none."
                    )
                }
            }
        }
        try Task.checkCancellation()
        throw ControlError(
            code: "wait_timeout",
            message: "\(ids.joined(separator: ", ")) did not become \(target.label) before the timeout.")
    }

    /// Reads what each pane runs, its title, whether a program holds its terminal, and its last line. Panes whose
    /// session ended go, and sessions the box does not know, in one of its rows, become panes.
    public func pollPanes() async {
        guard let sessions = try? await tmux.panes() else { return }
        let groups = await Self.foregroundGroups()
        let byName = Dictionary(sessions.map { ($0.session, $0) }, uniquingKeysWith: { first, _ in first })
        var changedPanes = false
        for pane in state.panes where byName[pane.id] == nil {
            forgetPane(pane.id)
            changedPanes = true
        }
        for session in sessions where pane(session.session) == nil {
            let folder = Paths.canonical(session.start)
            guard let row = row(holding: folder) else { continue }
            state.panes.append(StoredPane(id: session.session, rowPath: row.path, folder: folder, agent: PaneAgent()))
            bumpNextPane()
            changedPanes = true
        }
        var next = activity
        for pane in state.panes {
            guard let session = byName[pane.id] else { continue }
            let group = groups[session.pid] ?? 0
            let screen = try? await tmux.capture(pane.id, lines: nil)
            let lastLine = screen?.split(separator: "\n").last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            next[pane.id] = PaneActivity(
                foreground: session.command,
                title: session.title.isEmpty || Self.machineNames.contains(session.title) ? nil : session.title,
                busy: group > 0 && group != session.pid,
                lastLine: lastLine.map { $0.trimmingCharacters(in: .whitespaces) })
        }
        next = next.filter { id, _ in state.panes.contains { $0.id == id } }
        if changedPanes { changed() }
        if next != activity {
            activity = next
            publish()
        }
    }

    func pane(_ id: String) -> StoredPane? {
        state.panes.first { $0.id == id }
    }

    /// Text or keys went into a pane: the agent's key rules see them, and `wait` passes over a state from before.
    func typed(_ data: Data, into id: String) {
        guard let index = state.panes.firstIndex(where: { $0.id == id }) else { return }
        let now = Date()
        state.panes[index].lastInput = now.timeIntervalSince1970
        if state.panes[index].agent.typed(data, at: now) != nil {
            wakeWaiters()
        }
        changed()
    }

    /// A pane that ended: its agent stops, and waits on it end.
    func forgetPane(_ id: String) {
        state.panes.removeAll { $0.id == id }
        activity[id] = nil
        changed()
        wakeWaiters()
    }

    /// Each process's terminal's foreground process group, by pid, from `ps`.
    static func foregroundGroups() async -> [Int32: Int32] {
        guard let ps = Tmux.find("ps", path: "/bin:/usr/bin") else { return [:] }
        let result = await onOwnThread {
            try? Subprocess.run(
                ps, ["-A", "-o", "pid=,tpgid="], environment: ["PATH": "/bin:/usr/bin"], directory: nil,
                timeout: .seconds(5))
        }
        guard let result, result.status == 0 else { return [:] }
        var groups: [Int32: Int32] = [:]
        for line in String(decoding: result.stdout, as: UTF8.self).split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            if fields.count == 2, let pid = Int32(fields[0]), let group = Int32(fields[1]) { groups[pid] = group }
        }
        return groups
    }
}
