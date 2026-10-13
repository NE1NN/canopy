import CanopyAgents
import CanopyWire
import Foundation

extension BoxDaemon {
    /// How often the busy file is touched while the box should stay on. The host's idle check counts a file touched
    /// in the last 2 minutes.
    public static let busyEvery = Duration.seconds(30)

    /// Applies an agent report to a pane, returning its state after, or nil for a pane the box does not have.
    @discardableResult
    public func report(pane id: String, _ report: AgentReport) -> AgentState? {
        guard let index = state.panes.firstIndex(where: { $0.id == id }) else { return nil }
        let before = state.panes[index].agent
        _ = state.panes[index].agent.apply(report, now: Date())
        if state.panes[index].agent != before {
            changed()
            wakeWaiters()
        }
        return state.panes[index].agent.state
    }

    /// Applies what a Claude Code hook read on its standard input, dated by when the hook started. Nil for a pane the
    /// box does not have, or an event that says nothing about the pane.
    @discardableResult
    public func hook(pane id: String, input: Data, startedAt: Date) async -> AgentState? {
        guard let report = ClaudeHookMapping.report(from: input, startedAt: startedAt), await takeSession(id) else {
            return nil
        }
        return self.report(pane: id, report)
    }

    /// The author saw the pane's finish.
    public func seen(pane id: String) throws {
        guard let index = state.panes.firstIndex(where: { $0.id == id }) else { throw BoxErrors.paneNotFound(id) }
        if state.panes[index].agent.seen() { changed() }
    }

    /// The Mac's latest pull request numbers, by row path.
    public func setPRs(_ prs: [String: Int]) {
        let known = prs.filter { path, _ in row(path) != nil }
        guard known != state.prs else { return }
        state.prs = known
        changed()
    }

    /// Runs the hook reports the host's relay kept while nothing could take them, each dated by when its hook ran,
    /// and removes them. A report for a pane the box does not have is dropped.
    public func replayPending() async {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: paths.pending) else { return }
        for name in names.sorted() where name.hasSuffix(".json") {
            let path = paths.pending + "/" + name
            // Moved aside first, so a report kept meanwhile waits for the next replay rather than being removed.
            let taken = path + ".replay-\(getpid())"
            guard rename(path, taken) == 0 else { continue }
            defer { unlink(taken) }
            guard let data = FileManager.default.contents(atPath: taken),
                let kept = try? JSONDecoder().decode(KeptReport.self, from: data),
                RelayInput.reading(kept.args) == .hookReport, let pane = kept.env["CANOPY_PANE"],
                let input = kept.stdin.flatMap({ Data(base64Encoded: $0) })
            else { continue }
            let startedAt = Date(timeIntervalSince1970: (kept.kept ?? Date().timeIntervalSince1970) - (kept.age ?? 0))
            await hook(pane: pane, input: input, startedAt: startedAt)
        }
    }

    /// Whether an agent is at work or a phone is connected, so the box should stay on.
    var isBusy: Bool {
        phonesConnected || state.panes.contains { $0.agent.state == .working || $0.agent.state == .background }
    }

    /// Whether any phone is connected now, which keeps the box on as working agents do.
    public func setPhonesConnected(_ connected: Bool) {
        phonesConnected = connected
    }

    /// Touches the busy file while the box should stay on. A daemon that stops ticking stops holding the box on.
    public func tickBusy() {
        guard isBusy else { return }
        if !FileManager.default.fileExists(atPath: paths.busyFile) {
            try? BoxFiles.write(Data(), to: paths.busyFile)
        } else {
            _ = utimes(paths.busyFile, nil)
        }
    }

    func wakeWaiters() {
        for wake in waiters.values { wake() }
    }
}

/// A hook report as the host's relay keeps it: the relay's request, with when it was kept by the host's clock.
private struct KeptReport: Decodable {
    var args: [String]
    var env: [String: String]
    var stdin: String?
    /// Seconds from when the hook started until it was kept.
    var age: Double?
    /// When it was kept, in seconds since 1970.
    var kept: Double?
}

extension BoxDaemon {
    /// Takes the answer to a pane's open prompt, if `promptID` still names it, so a second answer finds it gone.
    func takeAnswer(pane id: String, promptID: String) -> OpenPrompt? {
        guard let index = state.panes.firstIndex(where: { $0.id == id }),
            let prompt = state.panes[index].agent.prompt, prompt.id == promptID,
            state.panes[index].agent.answer(promptID: promptID)
        else { return nil }
        changed()
        return prompt
    }

    /// Opens a taken prompt again when its keys never reached the pane.
    func giveBack(_ prompt: OpenPrompt, pane id: String) {
        guard let index = state.panes.firstIndex(where: { $0.id == id }), state.panes[index].agent.reopen(prompt)
        else { return }
        changed()
    }

    func agent(of id: String) -> PaneAgent? {
        pane(id)?.agent
    }
}
