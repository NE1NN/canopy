import CanopyAgents
import CanopySystem
import CanopyWire
import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

extension BoxDaemon {
    /// How long Return waits after text, so a program such as Claude Code reads it as a keystroke of its own rather
    /// than as part of a paste, as on the Mac.
    static let returnPause = Duration.milliseconds(200)
    /// How far apart keys go, as the author would press them.
    static let keyPause = Duration.milliseconds(150)
    /// tmux titles a pane nothing has titled with the machine's name, which says nothing.
    static let machineNames: Set<String> = {
        let name = machineName
        return [name, String(name.split(separator: ".").first ?? "")]
    }()

    /// The machine's name as tmux reads it, from gethostname(2), which never waits on DNS as
    /// `ProcessInfo.hostName` can on Linux.
    static var machineName: String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else { return "localhost" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Opens a pane in a row: a session of the home's tmux server named `b<N>`, in the row's folder, with the variables
    /// a remote pane gets, typing `command` once its shell is up.
    public func paneNew(_ params: BoxPaneNewParams) async throws -> String {
        guard let config else { throw BoxErrors.notConfigured() }
        let path = Paths.canonical(params.rowPath)
        guard let row = row(path) else { throw BoxErrors.rowNotFound(params.rowPath) }
        let id = "b\(state.nextPane)"
        state.nextPane += 1
        makingPanes.insert(id)
        defer { makingPanes.remove(id) }
        var environment = HostLayout.paneEnvironment(
            pane: id, rowName: row.branch ?? (row.path as NSString).lastPathComponent, repoName: row.repo,
            host: config.host, rowPath: row.path, clone: mainRows[row.repo]?.path ?? row.path, hostHome: paths.root,
            homeID: paths.homeID)
        environment["PATH"] = paths.bin + ":" + (tmux.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin")
        // Canopy's own variables win, so a caller cannot pass the pane off as another.
        environment.merge(params.environment ?? [:]) { own, _ in own }
        do {
            try await tmux.newSession(id, folder: row.path, environment: environment)
        } catch {
            changed()
            throw ControlError(code: "pane_failed", message: "\(error)")
        }
        state.panes.append(StoredPane(id: id, rowPath: row.path, folder: row.path, agent: PaneAgent()))
        changed()
        if let command = params.command {
            // Typed once the shell has drawn its prompt, so the line is not echoed twice, or after 2 s anyway.
            let deadline = ContinuousClock.now + .seconds(2)
            while ContinuousClock.now < deadline, ((try? await tmux.capture(id, lines: nil)) ?? "").isEmpty {
                try? await Task.sleep(for: .milliseconds(50))
            }
            // The pane is made either way; a command that could not be typed shows as a shell waiting.
            try? await tmux.sendText(command, to: id)
            try? await tmux.sendBytes(Data([0x0D]), to: id)
        }
        return id
    }

    /// Ends a pane's session and forgets the pane.
    public func paneClose(_ id: String) async throws {
        guard pane(id) != nil else { throw BoxErrors.paneNotFound(id) }
        await tmux.killSession(id)
        // Dated once the session is gone, as a listing taken while tmux killed it can still have it.
        closedPanes[id] = ContinuousClock.now
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

    /// Keys typed into a pane elsewhere, as through the Mac's tmux attach: the agent's key rules see them, and nothing
    /// goes into the pane.
    public func typedElsewhere(_ params: BoxKeysParams) throws {
        guard pane(params.pane) != nil else { throw BoxErrors.paneNotFound(params.pane) }
        for key in params.keys { typed(Data(key.utf8), into: params.pane) }
    }

    /// The pane's screen, or its last `lines` lines with scrollback, as plain text.
    public func read(pane id: String, lines: Int?) async throws -> String {
        guard pane(id) != nil else { throw BoxErrors.paneNotFound(id) }
        do {
            return try await tmux.capture(id, lines: lines)
        } catch {
            guard await tmux.hasSession(id) else { throw BoxErrors.paneNotFound(id) }
            throw ControlError(code: "tmux_failed", message: "\(error)")
        }
    }

    /// Waits until one of the panes' agents reaches `target`, returning the first that does in the order given. A
    /// pane already there counts at once, unless something went into it since.
    public func wait(panes ids: [String], for target: AgentWaitTarget, timeout: Duration) async throws -> (
        pane: String, state: AgentState
    ) {
        var seen = Set<String>()
        let ids = ids.filter { seen.insert($0).inserted }
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

    /// Whether the box has the pane, taking it now when its session runs on the box's tmux server in one of its rows,
    /// as one the Mac just opened does, rather than on the next poll, so its agent's first hooks are not lost.
    func takeSession(_ id: String) async -> Bool {
        if pane(id) != nil { return true }
        let listedAt = ContinuousClock.now
        guard mayTake(id, listedAt: listedAt), let session = try? await tmux.panes().first(where: { $0.session == id })
        else { return false }
        // Another call may have taken it while tmux listed.
        if pane(id) != nil { return true }
        // A hook says an agent runs there, so the session is looked at afresh, as its variables may have changed.
        guard await take(session, listedAt: listedAt, afresh: true) else { return pane(id) != nil }
        bumpNextPane()
        changed()
        return true
    }

    /// Makes a session a pane of the row it belongs in, unless it is one already, is being made or was closed since
    /// tmux listed it at `listedAt`, or no row holds it. Returns whether it did. `afresh` asks tmux about a session
    /// even when it was found in no row before.
    func take(_ session: TmuxPane, listedAt: ContinuousClock.Instant, afresh: Bool = false) async -> Bool {
        let id = session.session
        guard mayTake(id, listedAt: listedAt) else { return false }
        if afresh { unplaced[id] = nil }
        let placed = await placement(of: session)
        // Asking tmux lets other calls run: one may have taken, made, or closed it, or released the box.
        guard let placed, mayTake(id, listedAt: listedAt) else { return false }
        state.panes.append(StoredPane(id: id, rowPath: placed.row.path, folder: placed.folder, agent: PaneAgent()))
        return true
    }

    private func mayTake(_ id: String, listedAt: ContinuousClock.Instant) -> Bool {
        !state.released && pane(id) == nil && !makingPanes.contains(id)
            && (closedPanes[id].map { $0 < listedAt } ?? true)
    }

    /// The row a session is a pane of, and its folder there: the row holding the folder it started in, or else the row
    /// its CANOPY_ROW_PATH names, which every pane Canopy opens has, or else the row holding the folder it is in now.
    /// Nil for a session outside them all.
    func placement(of session: TmuxPane) async -> (row: StoredRow, folder: String)? {
        let start = Paths.canonical(session.start)
        if let row = row(holding: start) { return (row, start) }
        let now = Paths.canonical(session.folder)
        let checked = ([now] + allRows.map(\.path)).joined(separator: "\n")
        guard unplaced[session.session] != checked else { return nil }
        if let named = await tmux.variable("CANOPY_ROW_PATH", of: session.session),
            let row = row(Paths.canonical(named))
        {
            unplaced[session.session] = nil
            return (row, Paths.isInside(now, row.path) ? now : row.path)
        }
        let placed = row(holding: now).map { ($0, now) }
        unplaced[session.session] = placed == nil ? checked : nil
        return placed
    }

    /// Reads what each pane runs, its title, whether a program holds its terminal, and its last line. Panes whose
    /// session ended go, and sessions the box does not know, in one of its rows, become panes.
    public func pollPanes() async {
        // Panes made while tmux lists are not in its listing, so only panes from before it can be gone.
        let known = Set(state.panes.map(\.id))
        let listedAt = ContinuousClock.now
        guard let sessions = try? await tmux.panes() else { return }
        let groups = await Self.foregroundGroups()
        let byName = Dictionary(sessions.map { ($0.session, $0) }, uniquingKeysWith: { first, _ in first })
        var changedPanes = false
        for pane in state.panes
        where byName[pane.id] == nil && known.contains(pane.id) && !makingPanes.contains(pane.id) {
            forgetPane(pane.id)
            changedPanes = true
        }
        unplaced = unplaced.filter { byName[$0.key] != nil }
        closedPanes = closedPanes.filter { byName[$0.key] != nil || $0.value >= listedAt }
        for session in sessions {
            guard await take(session, listedAt: listedAt) else { continue }
            bumpNextPane()
            changedPanes = true
        }
        var next = activity
        var ended: [String] = []
        for pane in state.panes {
            guard let session = byName[pane.id] else { continue }
            let group = groups[session.pid] ?? 0
            let busy = group > 0 && group != session.pid
            let screen = try? await tmux.capture(pane.id, lines: nil)
            let lastLine = screen?.split(separator: "\n").last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            // The shell has its terminal back, so the program an agent ran in has ended, hook or no hook, as when
            // it was killed.
            if activity[pane.id]?.busy == true, !busy { ended.append(pane.id) }
            next[pane.id] = PaneActivity(
                foreground: session.command,
                title: session.title.isEmpty || Self.machineNames.contains(session.title) ? nil : session.title,
                busy: busy, lastLine: lastLine.map { $0.trimmingCharacters(in: .whitespaces) })
        }
        for id in ended {
            guard let index = state.panes.firstIndex(where: { $0.id == id }),
                state.panes[index].agent.ended(at: Date()) != nil
            else { continue }
            changedPanes = true
            wakeWaiters()
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

extension BoxDaemon {
    /// Pastes text into a pane as one bracketed paste, with newlines as Return and no escape characters, so the text
    /// cannot end its own paste.
    public func paste(pane id: String, text: String) async throws {
        guard pane(id) != nil else { throw BoxErrors.paneNotFound(id) }
        let clean = text.replacingOccurrences(of: "\r\n", with: "\n").filter { $0 != "\u{1b}" }
        typed(Data(clean.utf8), into: id)
        try await tmux.paste(clean, to: id)
    }

    /// Presses Return in the pane unless its agent left or shows a dialog, which Return would answer. Returns whether
    /// it pressed.
    func pressReturnUnlessDialog(pane id: String) async throws -> Bool {
        guard let agent = pane(id)?.agent, agent.session != nil, !BoxPhoneSource.showsDialog(agent) else {
            return false
        }
        try await tmux.sendBytes(Data([0x0D]), to: id)
        typed(Data([0x0D]), into: id)
        return true
    }

    /// The pane's screen with colours, and with `scrollback`, that many lines above it.
    public func screen(pane id: String, scrollback: Int?) async throws -> PhoneScreen {
        guard pane(id) != nil else { throw BoxErrors.paneNotFound(id) }
        let size = try await tmux.size(id)
        let all = try await tmux.capture(id, lines: size.rows + (scrollback ?? 0), escapes: true, keepBlank: true)
            .components(separatedBy: "\n")
        // Exactly the screen's rows, blank ones included, so lines and the cursor line up as on the Mac.
        var screen = Array(all.suffix(size.rows))
        while screen.count < size.rows { screen.append("") }
        return PhoneScreen(
            pane: id, columns: size.columns, rows: size.rows,
            scrollback: scrollback.map { _ in Array(all.dropLast(screen.count)) }, lines: screen)
    }
}
